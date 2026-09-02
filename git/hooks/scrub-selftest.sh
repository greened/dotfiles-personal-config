#!/usr/bin/env bash
# Assert the scrub's shape rules behave.  Run it by hand after editing them:
#
#     git/hooks/scrub-selftest.sh
#
# Exits 0 when every case holds, 1 on the first mismatch, and prints what it
# expected.  This is a guard, not documentation: it sources the SAME
# scrub-rules.sh the hook does, so a rule change that breaks a case fails here
# rather than surfacing as a leak later.
#
# It tests the RULES, not the hook.  Driving `_chain' would need a throwaway
# repo, staged content and a realm signal file; the rules are where the subtle
# behaviour lives, and they are pure text transformation.
#
# WHY THE INPUTS ARE ASSEMBLED FROM FRAGMENTS: every shape this file must feed
# the rules is, by construction, a shape the scrub refuses to see added to a
# repo.  Written literally, this file could not be committed -- the scrub would
# catch its own test data.  So the matching shapes are built at runtime and no
# literal appears on disk.  Exempt tokens (ISO-, CHANGE-, ACME-) are safe to
# write out, and doing so keeps the allowlist cases readable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/scrub-rules.sh"

# Assembled, never literal (see above).
sfx="c""b"                     # the work-account handle suffix
handle="alice-$sfx"            # a fictional handle carrying that suffix
root="/$sfx/home/alice/x"      # a path under the work NFS root
key="$(printf 'ZZZ')-9999"     # a Jira-SHAPED key naming no real project

pass=0
fail=0

# check DESCRIPTION EXPECTED INPUT
#   EXPECTED is the space-joined list of matches the rules should find, or the
#   empty string for "nothing".
check() {
  local desc="$1" expected="$2" input="$3" got
  got="$(printf '%s\n' "$input" \
           | sed -E "$shape_skip" \
           | grep -aoE "$shape_re" 2>/dev/null | tr '\n' ' ' || true)"
  got="${got% }"
  if [ "$got" = "$expected" ]; then
    printf 'ok    %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      expected: [%s]\n      got:      [%s]\n' \
           "$desc" "$expected" "$got" >&2
    fail=$((fail + 1))
  fi
}

# The regression this file exists for.  An allowlisted token used to make the
# whole LINE be dropped, so a real leak beside it escaped unnoticed.
check "a leak sharing a line with an allowlisted token is still caught" \
      "$handle" "see ISO-8601 and $handle on one line"

# Allowlisted shapes, alone.
check "a bare ISO-8601 date is not a key"       "" "dated 2026-09-01 and ISO-8601"
check "Atlassian's public change id is exempt"  "" "see CHANGE-2046 for the removal"
check "a fictional key used in docs is exempt"  "" "an issue key such as ACME-1234"

# Real shapes.
check "a work-shaped issue key is caught"       "$key"      "fixes $key today"
check "a work-account handle is caught"         "$handle"   "github: $handle"
check "the work NFS root is caught"             " /$sfx/h"  "lives in $root"

# Case sensitivity is load-bearing: it is why a lowercase stand-in is safe to
# write, and why matching case-insensitively would fire on ordinary prose.
check "a lowercase hyphen-digits string is not a key" "" "the acme-1234 example"

# --- literal terms -------------------------------------------------------
# Built by `scrub_term_re' from a FAKE term list, so no real term appears here
# and the cases stay readable.  Terms are matched case-insensitively, and the
# boundary is added only to an edge that is a word character.
terms="$(mktemp)"
trap 'rm -f "$terms"' EXIT
cat > "$terms" <<'TERMS'
# a comment, ignored
acorn
alice
/fake/
host.example.net
a+b
\bbadger\b
TERMS
term_re="$(scrub_term_re "$terms")"

# check_term DESCRIPTION EXPECTED-COUNT INPUT
check_term() {
  local desc="$1" expected="$2" input="$3" got
  got="$(printf '%s\n' "$input" | grep -acoiE "$term_re" 2>/dev/null || true)"
  got="${got:-0}"
  if [ "$got" = "$expected" ]; then
    printf 'ok    %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      expected %s match(es), got %s\n' "$desc" "$expected" "$got" >&2
    fail=$((fail + 1))
  fi
}

check_term "a term standing alone is caught"            1 "ship it to acorn today"
check_term "a term is caught whatever its case"         1 "ship it to ACORN today"
# The reason boundaries were added: without them a short term fires on ordinary
# prose.  "acorns" is a real word containing the term.
check_term "a term INSIDE a longer word is not caught"  0 "the acorns fell"
check_term "a term with a prefix is not caught"         0 "an unacorn thing"
check_term "another term standing alone is caught"      1 "ask alice about it"
check_term "that term inside a word is not caught"      0 "the alices gathered"
# A term whose edges are punctuation keeps matching mid-path.  Wrapping it in
# \b would demand a word character before the leading slash and break this --
# failing OPEN, which is why the boundary is conditional.
check_term "a punctuation-edged term still matches in a path" 1 "lives in /fake/here"

# A term list is a list of NAMES, but it is handed to grep -E as a pattern, so
# a term must be escaped to a literal.  Unescaped, a dot matched any character
# and a `+' term did not match its own text at all -- four real terms were
# inert that way, silently.
check_term "a dotted term matches its literal text"    1 "at host.example.net now"
check_term "a dotted term is NOT a wildcard"           0 "at hostXexampleXnet now"
check_term "a term containing + matches literally"     1 "the a+b case"
check_term "a term containing + is not expanded"       0 "the aab case"

# Escaping to a literal broke the terms written back when the list WAS a
# pattern and spelled its own boundaries: `\b' became a demand for a literal
# backslash, so the term matched only its own spelling in the list file.  Five
# real terms were dead this way, and the audit called them healthy for the same
# reason.  Anchors the term carries itself are therefore stripped first.
check_term "a legacy \\b-anchored term catches the bare word" 1 "a badger here"
check_term "its stripped anchor still bounds the term"        0 "the badgers ran"
check_term "it no longer matches its own written spelling"    0 'x \bbadger\b y'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

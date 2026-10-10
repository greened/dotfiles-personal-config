# Shape rules for the employer-information scrub.  Sourced, not run.
#
# Sets two variables:
#   shape_re    egrep alternation matching a shape that names nobody
#   shape_skip  sed -E expression blanking allowlisted tokens before matching
#
# These live here rather than inline in `_chain' so that the hook and
# `scrub-selftest.sh' cannot drift apart: a guard that tests its own copy of a
# rule tests nothing.  Note this does NOT unify every copy -- each project's
# check.sh carries its own pair, because those must run in a CI image with no
# access to this file, and that pair is still kept in step by hand.
#
# The rules name shapes, never the employer, so this file is safe in a public
# repo.  The employer's own strings live in the term list, which is deployed to
# ~/.config from a PRIVATE overlay (see `scrub.termsFile' /
# ~/.config/git-scrub-terms) and must never move to a public one.

# scrub_term_re FILE -- build the literal-term ERE from a term list.
#
# One term per line, `#' comments and blank lines ignored, joined with `|' and
# matched case-INSENSITIVELY by the caller: a name is a name however it is
# capitalised.
#
# Each term gets a word boundary, but only on an edge that IS a word character.
# Without boundaries a short term matches inside ordinary words -- a five-letter
# term collided with fifteen dictionary words here -- and refusing a commit over
# innocent prose is how a check teaches people to bypass it.
#
# The boundary is not `\b', because `_' and digits are word characters, and a
# term at the start of an env var name would have no `\b' after it. So `_'
# always separates, and so does a digit beside a letter edge. A letter always
# joins the term to a longer word, as does a digit beside a digit or `_' edge.
# The boundaries are explicit classes, like the shape rules below, so they
# consume the neighbour and a `grep -o' hit carries it. The conditional part
# matters because wrapping a term that already begins with punctuation would
# demand a non-letter before that punctuation, so a `/path/' term would stop
# matching "in src/path/here". That fails open, worse than the false positives
# it was meant to fix. A term that begins or ends with punctuation is already
# delimited by it. The classes are plain POSIX ERE, so every grep reads them
# the same way, including `git grep -E' on macOS, where a `\b' pattern matched
# nothing.
#
# Each term is also ESCAPED to a literal.  The list is a list of names, but it
# was being handed to `grep -E' as a pattern, so any term containing a regex
# metacharacter meant something other than itself: a term with a dot matched
# any character in that position, and one with `+' did not match its own text
# at all.  Four of the terms here were inert for that reason, silently -- the
# hook reported nothing and simply never fired on those names.  Escaping is
# what makes a term list a term list.
#
# Boundaries are decided from the RAW term, not the escaped one, because
# escaping prepends a backslash and would change what the edge looks like.
#
# A leading/trailing `\b' the term carries ITSELF is stripped first.  Those were
# written when terms were patterns and the boundary had to be spelled out, and
# escaping turns one into a demand for a literal backslash in the text: a term
# written `\bacorn\b' stopped matching the word "acorn" and matched only its own
# spelling.  Five of the terms here were in that state.  Stripping is not
# cosmetic tidying of a list that could simply be edited: an out-of-date copy of
# the list on another machine would otherwise fail OPEN, and because such a term
# still matches the line it sits on in the list itself, it goes on looking like a
# term that works.
#
# A list with no terms, only comments and blank lines, is refused with a message
# that names the file. Treating it as an empty list would let a truncated
# deploy pass every employer name.
#
# `scrub_term_re' and `scrub_term_hits' both read the list through
# `scrub_terms', so the hit trimmer sees the terms the regex was built from.
scrub_terms() {   # FILE -> one cleaned term per line
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$1" \
    | { grep -v '^[[:space:]]*$' || true; } \
    | sed -e 's/^\\b//' -e 's/\\b$//' \
    | { grep -v '^$' || true; }
}

scrub_term_re() {
  local re
  re="$(scrub_terms "$1" \
    | awk '{ raw = $0
             t = raw
             gsub(/[][(){}.^$*+?|\\]/, "\\\\&", t)
             if (raw ~ /^[A-Za-z]/) t = "(^|[^A-Za-z])" t
             else if (raw ~ /^[0-9_]/) t = "(^|[^A-Za-z0-9])" t
             if (raw ~ /[A-Za-z]$/) t = t "([^A-Za-z]|$)"
             else if (raw ~ /[0-9_]$/) t = t "([^A-Za-z0-9]|$)"
             printf "%s%s", sep, t; sep = "|" }')"
  if [ -z "$re" ]; then
    echo "scrub: refusing, because $1 holds no terms." >&2
    return 1
  fi
  printf '%s' "$re"
}

# Print the term hits in stdin, one matched term per line, as the text spells
# it. FILE is the term list. It applies scrub_term_re's boundary rules at
# each position without consuming the boundary, so two adjacent terms are
# both listed, which `grep -o' cannot do. At one position the longest term
# wins, and the scan resumes after it.
scrub_term_hits() {   # FILE, stdin -> matched terms, one per line
  local terms
  terms="$(scrub_terms "$1")"
  if [ -z "$terms" ]; then
    echo "scrub: refusing, because $1 holds no terms." >&2
    return 1
  fi
  SCRUB_TERMS="$terms" LC_ALL=C awk '
    function alpha(c) { return c ~ /[A-Za-z]/ }
    function alnum(c) { return c ~ /[A-Za-z0-9]/ }
    function edge_ok(t, prev, nxt,   a, z) {
      a = substr(t, 1, 1); z = substr(t, length(t), 1)
      if (alpha(a) && alpha(prev)) return 0
      if (a ~ /[0-9_]/ && alnum(prev)) return 0
      if (alpha(z) && alpha(nxt)) return 0
      if (z ~ /[0-9_]/ && alnum(nxt)) return 0
      return 1
    }
    BEGIN { n = split(ENVIRON["SCRUB_TERMS"], term, "\n")
            for (i = 1; i <= n; i++) term[i] = tolower(term[i]) }
    { h = tolower($0); len = length(h); p = 1
      while (p <= len) {
        best = 0
        for (i = 1; i <= n; i++) {
          l = length(term[i])
          if (l > best && substr(h, p, l) == term[i] &&
              edge_ok(term[i], p > 1 ? substr(h, p - 1, 1) : "", substr(h, p + l, 1)))
            best = l
        }
        if (best) { print substr($0, p, best); p += best } else p++
      } }'
}

# A shape rule is case-SENSITIVE on purpose.  Matched case-insensitively, the
# Jira-key rule fires on any lowercase hyphen-digits string ("abc-1234"), which
# is everywhere.  That case sensitivity is also why a lowercase stand-in such as
# `acme-1234' is safe to write in documentation.
# NO `\b' IN THESE, and the reason is not the one on shape_skip below.
#
# `\b' is a GNU extension.  Whether it is honoured depends on which engine reads
# the pattern, not on the pattern: the system grep here honours it, and so does
# `git grep -E' on Linux, but `git grep -E' on macOS does NOT and silently
# matches nothing.  A consumer that hands these rules to `git grep' therefore
# gets a rule that quietly stops existing, on one platform only.
#
# That is not hypothetical.  gazette's check.sh did exactly that, and a README
# carrying five real Jira keys passed its gate twice (2026-09-09).
#
# THIS hook was never affected: `_chain' pipes through the SYSTEM grep, where
# `\b' works, and all three shapes were verified firing.  So for the pre-commit
# path this is not a fix for a live hole.  It removes the dependency on which
# engine happens to read the rules, so the next consumer cannot inherit the trap.
#
# `scrub-audit.sh' has git list the text, then matches it with the system `sed'
# and `grep'.
#
# Explicit boundaries CONSUME a character, unlike `\b'.  Harmless for detection
# and for `grep -c', and `grep -o' output gains a boundary character.
shape_re='(^|[^A-Za-z0-9])[a-z][a-z0-9]{1,20}-cb([^A-Za-z0-9]|$)'   # work handle
shape_re="$shape_re"'|(^|[^A-Za-z0-9/])/cb/[a-z]'                   # work NFS root
shape_re="$shape_re"'|(^|[^A-Za-z0-9])[A-Z]{2,6}-[0-9]{4,6}([^A-Za-z0-9]|$)'  # Jira key
# A PR number of 4 to 6 digits (4+ in a field), written `#NNNN', `PR#NNNN',
# `owner/repo#NNNN' or as a forge plist, alist or JSON field.
# Its edges keep out a double-quoted hex colour, an HTML entity, TRAMP's
# host#port and any other `Word#NNNN'. An unquoted all-digit colour cannot be
# told from a PR number, so it is caught.
shape_re="$shape_re"'|(^|[^A-Za-z0-9"&])#[0-9]{4,6}([^0-9A-Za-z]|$)'
shape_re="$shape_re"'|"#[0-9]{4,6}([^0-9A-Za-z\"]|$)|"#[0-9]{5}"'
shape_re="$shape_re"'|(PR|pr)#[0-9]{4,6}([^0-9A-Za-z]|$)'
shape_re="$shape_re"'|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]{4,6}([^0-9A-Za-z]|$)'
shape_re="$shape_re"'|:number [0-9]{4,}|:pr-number [0-9]{4,}|\(number \. [0-9]{4,}\)|"number": ?[0-9]{4,}'

# Print the shape-rule hits in stdin, one matched TOKEN per line.
#
# Use this rather than `grep -oE "$shape_re"' directly.  The rules consume a
# boundary character where `\b' used to assert one, so a raw `-o' match carries
# stray punctuation into whatever the caller displays.  Trimming here keeps that
# detail with the rules that cause it, and keeps every consumer's output the
# same as it was before the boundaries became explicit.
#
# The leading trim spares `/', and `#' before a digit, because an NFS-root
# or PR-number match at line start legitimately begins with one.
scrub_shape_hits() {   # stdin -> matched tokens, one per line
  sed -E "$shape_skip" \
    | grep -aoE "$shape_re" 2>/dev/null \
    | sed -E 's|^[^A-Za-z0-9/#]||; s|^#([^0-9])|\1|; s|[^A-Za-z0-9]$||'
}

# Blank the allowlisted tokens INSIDE each line, then look at what is left.
# Dropping whole lines instead (`grep -v') let a real leak sharing a line with
# an ISO- date through, silently -- see the ISO-8601-plus-handle case in
# scrub-selftest.sh.
#
# 4+ digits already spares a bare ISO-8601 date; these prefixes are excluded
# outright.  CHANGE-NNNN is Atlassian's own public change id, not an employer
# key.  ACME/ALPHA/BETA/FOO/BAR are the fictional stand-ins documentation uses,
# so an example key does not trip the rule that exists for real ones.
#
# No \b here: BSD sed does not honour it, and this runs on a Mac.
shape_skip='s/(^|[^A-Za-z0-9])(ISO|UTF|RFC|SHA|AES|CVE|CHANGE|ACME|ALPHA|BETA|FOO|BAR)-[0-9]+/\1/g'

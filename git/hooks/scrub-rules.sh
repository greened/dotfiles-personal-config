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
# The conditional part is not fussiness.  `\b' asserts a word/non-word
# transition, so wrapping a term that already begins with punctuation demands a
# word character BEFORE that punctuation: a `/path/' term would stop matching
# "in /path/here" altogether.  That fails OPEN, which is worse than the false
# positives it was meant to fix.  Five of the terms here begin or end with
# punctuation, and their punctuation already delimits them.
#
# `\b' works in GNU grep and in the BSD grep macOS ships (2.6.0-FreeBSD,
# GNU-compatible), both verified.  `[[:<:]]' is BSD-only, so it is not used.
# The `sed' caveat elsewhere in these rules does not apply: this is grep.
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
scrub_term_re() {
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$1" \
    | grep -v '^[[:space:]]*$' \
    | awk '{ raw = $0
             sub(/^\\b/, "", raw); sub(/\\b$/, "", raw)
             t = raw
             gsub(/[][(){}.^$*+?|\\]/, "\\\\&", t)
             if (raw ~ /^[A-Za-z0-9_]/) t = "\\b" t
             if (raw ~ /[A-Za-z0-9_]$/) t = t "\\b"
             printf "%s%s", sep, t; sep = "|" }'
}

# A shape rule is case-SENSITIVE on purpose.  Matched case-insensitively, the
# Jira-key rule fires on any lowercase hyphen-digits string ("abc-1234"), which
# is everywhere.  That case sensitivity is also why a lowercase stand-in such as
# `acme-1234' is safe to write in documentation.
shape_re='\b[a-z][a-z0-9]{1,20}-cb\b'                 # work-account handle suffix
shape_re="$shape_re"'|(^|[^A-Za-z0-9/])/cb/[a-z]'     # work NFS root
shape_re="$shape_re"'|\b[A-Z]{2,6}-[0-9]{4,6}\b'      # Jira-style key

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

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
# repo.  The employer's own strings live in the term list outside any repo
# (see `scrub.termsFile' / ~/.config/git-scrub-terms).

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

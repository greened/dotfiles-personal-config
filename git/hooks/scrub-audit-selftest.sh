#!/usr/bin/env bash
# Assert scrub-audit.sh finds a term and a shape in committed text, and fails
# on a dead rule. Run it by hand after editing the audit:
#
#     git/hooks/scrub-audit-selftest.sh
#
# Exits 0 when every case holds, and 1 otherwise.
#
# The repos, the term list and the git config are all throwaway. The term is
# invented, and the shape is assembled at runtime for the reason
# scrub-selftest.sh gives.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

key="$(printf 'ZZZ')-9999"
printf 'zqxjv\n' > "$root/terms"
printf '[scrub]\n\ttermsFile = %s\n' "$root/terms" > "$root/gitconfig"
export GIT_CONFIG_GLOBAL="$root/gitconfig"

# new_repo DIR TEXT commits TEXT as the only file in a fresh repo.
new_repo() {
    git init -q "$1"
    printf '%s\n' "$2" > "$1/a.txt"
    git -C "$1" add a.txt
    git -C "$1" -c user.name=T -c user.email=t@example.com \
        -c core.hooksPath=/dev/null commit -q -m a
}

new_repo "$root/public" "ship it to zqxjv, see $key"
new_repo "$root/private" "nothing to see"
# A repo with only binary content yields no text, which must not read as clean.
new_repo "$root/binary" "x"
printf '\0\1\2' > "$root/binary/a.txt"
git -C "$root/binary" -c user.name=T -c user.email=t@example.com \
    -c core.hooksPath=/dev/null commit -q -am b

# audit DIR runs the scrub-audit.sh in DIR over the fixture repos, and sets rc.
audit() {
    rc=0
    (cd "$root" && GIT_CONFIG_SYSTEM=/dev/null \
    SCRUB_AUDIT_PUBLIC="$root/public" \
    SCRUB_AUDIT_PRIVATE="$root/private $root/binary" \
    SCRUB_AUDIT_PROSE="$root/public" "$1/scrub-audit.sh") || rc=$?
}

audit "$here" >"$root/out" 2>"$root/stderr"
out="$(cat "$root/out")"

# check DESCRIPTION PATTERN asserts that the report has a line matching
# PATTERN, a grep -E pattern.
#
# A here-string, not a pipe. `grep -q' exits at the first match, and under
# `pipefail' the SIGPIPE that can kill the writer fails the check at random.
check() {
    if grep -qE -- "$2" <<<"$out"; then
        echo "ok    $1"
        pass=$((pass + 1))
    else
        echo "FAIL  $1: no line matches /$2/"
        fail=$((fail + 1))
    fi
}

check "a committed term is live in public" '^1 +zqxjv .*LIVE-IN-PUBLIC'
check "a committed shape is counted in public" "^public +1 +$key\$"
check "a clean repo has no shape hits" '^private +0 *$'

if grep -qxF "scrub-audit: no text read from $root/binary" "$root/stderr" &&
   ! grep -qF "$root/private" "$root/stderr"; then
    echo "ok    a repo with no text is named, and only that one"
    pass=$((pass + 1))
else
    echo "FAIL  a repo with no text is named, and only that one:"
    sed 's/^/      /' "$root/stderr"
    fail=$((fail + 1))
fi

if [ "$rc" -eq 0 ]; then
    echo "ok    a clean term list passes"
    pass=$((pass + 1))
else
    echo "FAIL  a clean term list passes: exit $rc"
    fail=$((fail + 1))
fi

# expect_dead DESCRIPTION MESSAGE... runs the audit in the mutant copy, and
# asserts that it exits 1 and says every MESSAGE on stderr.
expect_dead() {
    local desc="$1" m said=1
    shift
    audit "$mut" >/dev/null 2>"$root/stderr"
    for m in "$@"; do grep -qF -- "$m" "$root/stderr" || said=0; done
    if [ "$rc" -eq 1 ] && [ "$said" -eq 1 ]; then
        echo "ok    $desc"
        pass=$((pass + 1))
    else
        echo "FAIL  $desc: exit $rc"
        sed 's/^/      /' "$root/stderr"
        fail=$((fail + 1))
    fi
}

# The dead rules are made in a copy of the hooks, never in the real ones.
mut="$root/mut"
mkdir "$mut"
cp "$here/scrub-audit.sh" "$here/scrub-rules.sh" "$here/scrub-selftest.sh" "$mut/"

# A Jira-key rule that wants seven digits catches no real key.
sed -i.orig 's/\[0-9\]{4,6}/[0-9]{7,9}/' "$mut/scrub-rules.sh"
expect_dead "a dead shape rule fails the audit" "the rule self-test failed" \
            "a work-shaped issue key is caught"

# A builder that does not escape makes a `+' term inert. The self-test would
# catch that first, so it is replaced here to reach the inert check.
mv "$mut/scrub-rules.sh.orig" "$mut/scrub-rules.sh"
sed -i.orig '/gsub(/d' "$mut/scrub-rules.sh"
printf '#!/bin/sh\nexit 0\n' > "$mut/scrub-selftest.sh"
printf 'zqxjv\na+b\n' > "$root/terms"
expect_dead "an inert term fails the audit" "1 term(s) cannot match"

# A term that is only a legacy anchor builds to nothing, so it is inert too.
mv "$mut/scrub-rules.sh.orig" "$mut/scrub-rules.sh"
cp "$here/scrub-selftest.sh" "$mut/"
printf 'zqxjv\n\\b\n' > "$root/terms"
expect_dead "a bare-anchor term fails the audit" "1 term(s) cannot match"

if [ "$fail" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/      /'
fi
echo "scrub-audit-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Assert scrub-audit.sh finds a term and a shape in committed text. Run it by
# hand after editing the audit:
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

out="$(SCRUB_AUDIT_PUBLIC="$root/public" \
       SCRUB_AUDIT_PRIVATE="$root/private $root/binary" \
       SCRUB_AUDIT_PROSE="$root/public" "$here/scrub-audit.sh" \
       2>"$root/stderr")"

# check DESCRIPTION PATTERN asserts that the report has a line matching
# PATTERN, a grep -E pattern.
check() {
    if printf '%s\n' "$out" | grep -qE -- "$2"; then
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

if [ "$fail" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/      /'
fi
echo "scrub-audit-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

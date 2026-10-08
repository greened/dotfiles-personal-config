#!/usr/bin/env bash
# Assert the commit-msg trailer strip behaves. Run it by hand after editing
# that arm of `_chain':
#
#     git/hooks/trailer-selftest.sh
#
# Exits 0 when every case holds, and 1 otherwise.
#
# It drives the hook in throwaway repos, as slop-selftest.sh does. A temp HOME
# and an empty global and system git config keep the real configuration out,
# and the hooks are a copy. A fictional work realm stands in for the real one.
# Its file names an invented org and identity, so nothing here names an
# employer. A stub stands in for commit-context.py, so the cases do not depend
# on the real file or on its list of own tooling.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/home"

# The stub takes the real file's call shape: `--ai-trailer REMOTE EMAIL'
# prints yes or no. Only a repo named devtools takes none.
ctx="$root/commit-context.py"
cat > "$ctx" <<'PY'
import sys
assert sys.argv[1] == "--ai-trailer", sys.argv
name = sys.argv[2].rstrip("/").rsplit("/", 1)[-1]
if name.endswith(".git"):
    name = name[:-4]
print("no" if name == "devtools" else "yes")
PY
# The broken stub fails as the real one does on a remote with no owner.
broken="$root/broken-context.py"
cat > "$broken" <<'PY'
import sys
print("commit-context: no owner in remote", file=sys.stderr)
sys.exit(2)
PY

hooks="$root/hooks"
cp -r "$here" "$hooks"

realm="$root/realm"
printf '%s\n' 'origin *[:/]acme-work/*' 'identity dev@example.com' > "$realm"
# The scrub refuses to run with no term list, so give it one invented term.
terms="$root/terms"
printf 'zqxjv\n' > "$terms"

# Assembled so this file carries no trailer line of its own.
trailer="Co-Authored-By: Cla""ude Test"
message="Add a thing

$trailer"

# new_repo DIR ORIGIN EMAIL [POLICY] makes a repo with the copied hooks.
new_repo() {
    local dir="$1" origin="$2" email="$3" policy="${4:-$ctx}"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config core.hooksPath "$hooks"
    git -C "$dir" config realm.workFile "$realm"
    git -C "$dir" config scrub.termsFile "$terms"
    git -C "$dir" config trailer.policyPath "$policy"
    git -C "$dir" config user.name "Test Person"
    git -C "$dir" config user.email "$email"
    [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
    printf 'a\n' > "$dir/a.txt"
    git -C "$dir" add a.txt
}

# check DESCRIPTION WANT DIR, where WANT is "kept" or "stripped".
check() {
    local desc="$1" want="$2" dir="$3" out got
    last_out=""
    if ! out="$(cd "$dir" && HOME="$root/home" \
                git commit -q -m "$message" 2>&1)"; then
        echo "FAIL  $desc: the commit was refused:"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1))
        return
    fi
    if git -C "$dir" log -1 --format=%B | grep -qxF "$trailer"; then
        got=kept
    else
        got=stripped
    fi
    if [ "$got" = "$want" ]; then
        echo "ok    $desc"
        pass=$((pass + 1))
    else
        echo "FAIL  $desc: want the trailer $want, it was $got"
        fail=$((fail + 1))
    fi
    last_out="$out"
}

# The negative control. A work repo that takes a trailer keeps it, so the
# strip cases below do not pass merely because everything is stripped.
new_repo "$root/work" "git@github.com:acme-work/thing.git" dev@example.com
check "a work repo keeps its trailer" kept "$root/work"

# The case the arm exists for: own tooling on the work account.
new_repo "$root/tools" "git@github.com:acme-work/devtools.git" dev@example.com
check "own tooling on the work account loses the trailer" stripped "$root/tools"

# A personal repo must commit as the personal identity, which `_chain' checks.
new_repo "$root/mine" "git@github.com:greened/thing.git" dag@obbligato.org
git -C "$root/mine" config user.name "David Greene"
check "a personal repo loses the trailer" stripped "$root/mine"

# With no policy file the realm decides alone.
new_repo "$root/nopolicy" "git@github.com:acme-work/devtools.git" \
         dev@example.com "$root/missing.py"
check "with no policy file the realm decides" kept "$root/nopolicy"

# A policy that raises falls back to the realm too, but says so.
new_repo "$root/broken" "git@github.com:acme-work/devtools.git" \
         dev@example.com "$broken"
check "with a broken policy the realm decides" kept "$root/broken"
if printf '%s\n' "$last_out" | grep -q 'cannot read the policy'; then
    echo "ok    a broken policy is reported"
    pass=$((pass + 1))
else
    echo "FAIL  a broken policy is reported: no warning in the output"
    fail=$((fail + 1))
fi
if printf '%s\n' "$last_out" | grep -q 'no owner in remote'; then
    echo "ok    a broken policy's reason is passed on"
    pass=$((pass + 1))
else
    echo "FAIL  a broken policy's reason is passed on: not in the output"
    fail=$((fail + 1))
fi

# A personal repo never asks the policy, so a broken one stays quiet there.
new_repo "$root/mine-broken" "git@github.com:greened/thing.git" \
         dag@obbligato.org "$broken"
git -C "$root/mine-broken" config user.name "David Greene"
check "a personal repo with a broken policy loses the trailer" stripped \
      "$root/mine-broken"
if printf '%s\n' "$last_out" | grep -q 'cannot read the policy'; then
    echo "FAIL  a personal repo does not report a broken policy"
    fail=$((fail + 1))
else
    echo "ok    a personal repo does not report a broken policy"
    pass=$((pass + 1))
fi

echo "trailer-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

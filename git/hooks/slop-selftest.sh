#!/usr/bin/env bash
# Assert the commit-msg slop backstop behaves. Run it by hand after editing
# that arm of `_chain':
#
#     git/hooks/slop-selftest.sh
#
# Exits 0 when every case holds, 1 on the first mismatch, and prints what it
# expected.
#
# IT DRIVES THE HOOK, not the rules. The rules live in `prose-lint.py' and are
# that file's to test. What can go wrong HERE is the decision around them: when
# the arm runs, when it stays quiet, and whether it keeps its promise never to
# refuse and never to rewrite. Those are properties of the hook.
#
# BOTH DIRECTIONS, and the clean case is the one worth having. A check that
# fires on slop proves nothing on its own, because a check that fires on
# everything also passes that test. The scrub selftest was once wired with only
# the positive direction, so the negative control is explicit here.
#
# THE THROWAWAY REPO IS THE HARNESS. A temp HOME and GIT_CONFIG_GLOBAL=/dev/null
# keep the real configuration out of it, and the hooks are a COPY, so a broken
# rule under test never reaches the ones in use. The personal identity is set
# in the repo, because `_chain' enforces identity before it reaches this arm and
# a test that skips that never runs the code it is about.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lint="$HOME/.claude/skills-personal/bin/prose-lint.py"

if [ ! -f "$lint" ]; then
    echo "SKIP: no prose-lint.py at $lint, so the arm is inert here" >&2
    exit 0
fi

pass=0
fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# ASSEMBLED, NEVER LITERAL, for the reason the scrub selftest assembles its
# inputs: a file whose job is to feed slop to a linter cannot hold slop. The
# editor gate lints this file too, and it would refuse to open it. So the
# marketing word is built from pieces and no literal appears on disk.
#
# The fixture is asserted below rather than trusted. A linter that stopped
# objecting to it would make every positive case here pass for the wrong
# reason, which is the failure a test cannot report about itself.
mk="seam""less"
slop="This change will now use a $mk approach."
clean='Add a slop backstop to the commit-msg hook.

The editor gate lints a draft before it opens, so this arm covers the
commit that never went through it.'

hooks="$root/hooks"
cp -r "$here" "$hooks"

# new_repo DIR -- a git repo with the copied hooks and the personal identity.
new_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config core.hooksPath "$hooks"
    git -C "$dir" config user.name "David Greene"
    git -C "$dir" config user.email "dag@obbligato.org"
    # The REAL linter, named explicitly. Under the throwaway HOME the arm's
    # default path resolves to nothing, and the arm would skip itself, so every
    # positive case below would pass without running the linter at all.
    git -C "$dir" config prose.lintPath "$lint"
    printf 'a\n' > "$dir/a.txt"
    git -C "$dir" add a.txt
}

# check DESCRIPTION EXPECTED-PATTERN DIR MESSAGE
#   EXPECTED-PATTERN is a grep -E pattern the hook's stderr must match, or the
#   empty string for "it must say nothing".
check() {
    local desc="$1" expected="$2" dir="$3" message="$4" out rc
    set +e
    out="$(cd "$dir" && HOME="$root/home" GIT_CONFIG_GLOBAL=/dev/null \
           git commit -q -m "$message" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "FAIL  $desc: the commit was REFUSED (rc=$rc), and this arm must never refuse"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1))
        return
    fi
    if [ -n "$expected" ]; then
        if printf '%s' "$out" | grep -qE "$expected"; then
            pass=$((pass + 1))
        else
            echo "FAIL  $desc: expected stderr matching /$expected/, got:"
            printf '%s\n' "$out" | sed 's/^/      /'
            fail=$((fail + 1))
        fi
    else
        if [ -z "$(printf '%s' "$out" | grep -E 'prose-lint' || true)" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL  $desc: expected silence, got:"
            printf '%s\n' "$out" | sed 's/^/      /'
            fail=$((fail + 1))
        fi
    fi
}

mkdir -p "$root/home"

# The premise this file rests on. If the linter stops objecting to the fixture,
# every positive case below would pass for the wrong reason.
tmpmsg="$root/fixture.txt"
printf '%s\n' "$slop" > "$tmpmsg"
if python3 "$lint" --surface commit --file "$tmpmsg" >/dev/null 2>&1; then
    echo "FAIL  the fixture is no longer slop: prose-lint.py accepts it"
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# 1) The case the arm exists for: no gate ran, and the message is slop.
new_repo "$root/ungated"
check "slop with no gate warns" 'prose-lint: this message did not' \
      "$root/ungated" "$slop"

# 2) THE NEGATIVE CONTROL. A clean message must pass in silence.
new_repo "$root/clean"
check "a clean message says nothing" "" "$root/clean" "$clean"

# 3) A gate file newer than HEAD means the editor already linted it, so the
#    backstop stays out of the way even when the text would be flagged.
new_repo "$root/gated"
git -C "$root/gated" commit -q -m "first" --no-verify
printf 'b\n' > "$root/gated/b.txt"
git -C "$root/gated" add b.txt
touch "$root/gated/.git/CLAUDE_COMMIT_MSG"
check "a fresh gate suppresses the warning" "" "$root/gated" "$slop"

# 4) A gate file OLDER than HEAD is a spent receipt and must not suppress.
new_repo "$root/stale"
# The stamp is assembled because a run of digits that long reads as a commit
# hash to the prose linter, and this file has to pass it. GNU form first, then
# BSD, so the test runs on the Mac as well.
old_day="2020-01-01"
old_stamp="${old_day//-/}0000"
touch -d "$old_day" "$root/stale/.git/CLAUDE_COMMIT_MSG" 2>/dev/null \
    || touch -t "$old_stamp" "$root/stale/.git/CLAUDE_COMMIT_MSG"
git -C "$root/stale" commit -q -m "first" --no-verify
printf 'c\n' > "$root/stale/c.txt"
git -C "$root/stale" add c.txt
check "a spent gate does not suppress" 'prose-lint: this message did not' \
      "$root/stale" "$slop"

# 5) A generated message has no prose anybody chose, so it is not judged.
new_repo "$root/merge"
check "a generated subject is skipped" "" "$root/merge" \
      "Merge branch 'x' into y $slop"

# 6) IT NEVER REWRITES. The message that lands is the message as written, minus
#    only what the trailer strip above this arm removes.
new_repo "$root/intact"
check "the warning does not rewrite" 'prose-lint' "$root/intact" "$slop"
landed="$(git -C "$root/intact" log -1 --format=%B | head -n 1)"
if [ "$landed" = "$slop" ]; then
    pass=$((pass + 1))
else
    echo "FAIL  the message was REWRITTEN"
    echo "      wrote:  $slop"
    echo "      landed: $landed"
    fail=$((fail + 1))
fi

echo "slop-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

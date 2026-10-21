#!/usr/bin/env bash
# Assert the pre-push half of the scrub checks what the push publishes. Run it
# by hand after editing that arm of `_chain':
#
#     git/hooks/push-scrub-selftest.sh
#
# Exits 0 when every case holds, and 1 otherwise.
#
# It pushes to a bare repo in a throwaway directory, with a temp HOME, an
# empty global and system git config, and a copy of the hooks. The commits
# that carry a hit are made with `git commit-tree', which runs no hooks, so
# the pre-commit scrub cannot stop the fixture before the push is tested. The
# hit-carrying inputs are assembled from fragments, for the reason
# scrub-selftest.sh gives.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/home"

hooks="$root/hooks"
cp -r "$here" "$hooks"

realm="$root/realm"
printf '%s\n' 'origin *[:/]acme-work/*' > "$realm"
terms="$root/terms"
term="zq""xjv"
printf '%s\n' "$term" > "$terms"

key="$(printf 'QZX')-40213"    # Jira-shaped, names no real project

# new_repo DIR makes a repo with the copied hooks, a bare origin and one clean
# commit on main that the origin already has.
new_repo() {
    local dir="$1"
    git init -q --bare "$dir.git"
    git init -q -b main "$dir"
    git -C "$dir" config core.hooksPath "$hooks"
    git -C "$dir" config realm.workFile "$realm"
    git -C "$dir" config scrub.termsFile "$terms"
    git -C "$dir" config user.name "Test Person"
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" remote add origin "$dir.git"
    put "$dir" main a.txt "a"
    seed "$dir" main
    git -C "$dir" branch -q -u origin/main main
}

# put DIR BRANCH FILE TEXT commits FILE=TEXT on BRANCH through plumbing,
# without running a hook. The worktree follows only when BRANCH is checked
# out, so it stays clean as it would after a real commit.
put() {
    local dir="$1" branch="$2" file="$3" text="$4" idx parent blob tree c
    idx="$root/index.$$"
    parent="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" || true)"
    rm -f "$idx"
    if [ -n "$parent" ]; then
        GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$parent"
    fi
    blob="$(printf '%s\n' "$text" | git -C "$dir" hash-object -w --stdin)"
    GIT_INDEX_FILE="$idx" git -C "$dir" update-index --add \
        --cacheinfo "100644,$blob,$file"
    tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)"
    c="$(git -C "$dir" commit-tree "$tree" ${parent:+-p "$parent"} -m "edit $file")"
    git -C "$dir" update-ref "refs/heads/$branch" "$c"
    rm -f "$idx"
    if [ "$(git -C "$dir" symbolic-ref HEAD)" = "refs/heads/$branch" ]; then
        git -C "$dir" reset -q --hard
    fi
}

# commit_tree DIR BRANCH TREE [PARENT...] points BRANCH at a new commit of
# TREE, and resets the worktree when BRANCH is checked out.
commit_tree() {
    local dir="$1" branch="$2" tree="$3" c p args=()
    shift 3
    for p in "$@"; do
        args+=(-p "$p")
    done
    c="$(git -C "$dir" commit-tree "$tree" "${args[@]}" -m "commit on $branch")"
    git -C "$dir" update-ref "refs/heads/$branch" "$c"
    if [ "$(git -C "$dir" symbolic-ref HEAD)" = "refs/heads/$branch" ]; then
        git -C "$dir" reset -q --hard
    fi
}

# move DIR BRANCH OLD NEW renames OLD to NEW on BRANCH, content unchanged.
move() {
    local dir="$1" branch="$2" idx="$root/index.$$" blob tree
    blob="$(git -C "$dir" rev-parse "refs/heads/$branch:$3")"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "refs/heads/$branch"
    GIT_INDEX_FILE="$idx" git -C "$dir" update-index --force-remove "$3"
    GIT_INDEX_FILE="$idx" git -C "$dir" update-index --add \
        --cacheinfo "100644,$blob,$4"
    tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)"
    rm -f "$idx"
    commit_tree "$dir" "$branch" "$tree" "refs/heads/$branch"
}

# merge DIR BRANCH OTHER [FILE TEXT] merges OTHER into BRANCH. With FILE, the
# merge commit adds FILE=TEXT that neither parent has, as a hand resolution
# can.
merge() {
    local dir="$1" branch="$2" other="$3" idx="$root/index.$$" tree blob
    tree="$(git -C "$dir" merge-tree --write-tree "$branch" "$other")"
    if [ $# -gt 3 ]; then
        rm -f "$idx"
        GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$tree"
        blob="$(printf '%s\n' "$5" | git -C "$dir" hash-object -w --stdin)"
        GIT_INDEX_FILE="$idx" git -C "$dir" update-index --add \
            --cacheinfo "100644,$blob,$4"
        tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)"
        rm -f "$idx"
    fi
    commit_tree "$dir" "$branch" "$tree" "refs/heads/$branch" "refs/heads/$other"
}

# reword DIR BRANCH MESSAGE replaces BRANCH's tip with a commit of the same
# tree and parents that carries MESSAGE.
reword() {
    local dir="$1" branch="$2" c p args=()
    for p in $(git -C "$dir" rev-parse "refs/heads/$branch^@"); do
        args+=(-p "$p")
    done
    c="$(printf '%s\n' "$3" | git -C "$dir" commit-tree \
           "refs/heads/$branch^{tree}" "${args[@]}")"
    git -C "$dir" update-ref "refs/heads/$branch" "$c"
}

# seed DIR BRANCH puts BRANCH on the origin without a push, so no hook runs,
# and fetches so the remote-tracking ref knows it.
seed() {
    git -C "$1.git" fetch -q "$1" "+refs/heads/$2:refs/heads/$2"
    git -C "$1" fetch -q origin
}

# check DESCRIPTION WANT DIR [--to REMOTE] PUSH-ARGS... runs the push to
# REMOTE, origin by default. WANT is "pushed" or "refused".
check() {
    local desc="$1" want="$2" dir="$3" remote=origin out got
    shift 3
    if [ "${1:-}" = --to ]; then
        remote="$2"
        shift 2
    fi
    if out="$(cd "$dir" && HOME="$root/home" git push -q "$remote" "$@" 2>&1)"; then
        got=pushed
    else
        got=refused
    fi
    last_out="$out"
    if [ "$got" = "$want" ]; then
        echo "ok    $desc"
        pass=$((pass + 1))
    else
        echo "FAIL  $desc: want $want, it was $got"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# The negative control: a clean push goes through, so the refusals below do
# not pass merely because every push is refused.
new_repo "$root/clean"
put "$root/clean" main b.txt "nothing to see"
check "a clean push goes through" pushed "$root/clean" main

new_repo "$root/clean-new"
put "$root/clean-new" topic b.txt "nothing to see"
check "a clean new branch goes through" pushed "$root/clean-new" topic

# switch DIR BRANCH checks BRANCH out, with no upstream.
switch() {
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
    git -C "$1" reset -q --hard
}

# A new branch: the remote side of the push is all zeros.
new_repo "$root/new"
put "$root/new" topic b.txt "see $key"
switch "$root/new" topic
check "a new branch carrying a shape hit is refused" refused "$root/new" topic

new_repo "$root/old"
put "$root/old" main b.txt "see $key"
check "an existing branch gaining a shape hit is refused" refused \
      "$root/old" main

new_repo "$root/term"
put "$root/term" main b.txt "see $term here"
check "a pushed commit carrying a term is refused" refused "$root/term" main

# git quotes a name like this one by default, and a quoted name matches no
# file when it is handed back as a path.
new_repo "$root/name"
put "$root/name" main "caf$(printf '\303\251').txt" "see $key"
check "a file with a non-ASCII name is scanned" refused "$root/name" main

# The ref pushed need not be the one checked out.
new_repo "$root/other"
put "$root/other" topic b.txt "see $key"
check "a branch that is not checked out is still scanned" refused \
      "$root/other" topic

# History publishes every commit, not only the tip's tree.
new_repo "$root/gone"
put "$root/gone" main b.txt "see $key"
put "$root/gone" main b.txt "clean again"
check "a hit added and removed inside the push is refused" refused \
      "$root/gone" main

# What is not being pushed is not scanned.
new_repo "$root/dirty"
put "$root/dirty" topic b.txt "nothing to see"
switch "$root/dirty" topic
printf 'see %s\n' "$key" > "$root/dirty/c.txt"
git -C "$root/dirty" add c.txt
check "a hit only in the index and worktree does not stop a push" pushed \
      "$root/dirty" topic

# A hit the origin already has is not this push's to refuse.
new_repo "$root/legacy"
put "$root/legacy" main b.txt "see $key"
seed "$root/legacy" main
put "$root/legacy" main c.txt "nothing to see"
check "a hit already on the origin is not scanned again" pushed \
      "$root/legacy" main

new_repo "$root/delete"
put "$root/delete" topic b.txt "nothing to see"
seed "$root/delete" topic
check "deleting a branch goes through" pushed "$root/delete" :topic

# The chain reads the ref lines itself, so it must hand them on to the
# repo-local hook.
new_repo "$root/local"
put "$root/local" main b.txt "nothing to see"
cat > "$root/local/.git/hooks/pre-push" <<EOF
#!/bin/sh
cat > "$root/local-stdin"
EOF
chmod +x "$root/local/.git/hooks/pre-push"
check "a push with a repo-local hook goes through" pushed "$root/local" main
if grep -q ' refs/heads/main ' "$root/local-stdin" 2>/dev/null; then
    echo "ok    the repo-local hook still gets the ref lines"
    pass=$((pass + 1))
else
    echo "FAIL  the repo-local hook still gets the ref lines: it got none"
    fail=$((fail + 1))
fi

# A line that begins with `++' shows as `+++' in the patch, like a header.
new_repo "$root/plus"
put "$root/plus" main b.txt "++ see $key"
check "an added line that starts with ++ is scanned" refused "$root/plus" main

# git quotes a name with a tab even with core.quotePath off.
new_repo "$root/tab"
put "$root/tab" main "a$(printf '\t')b.txt" "see $key"
check "a file with a tab in its name is scanned" refused "$root/tab" main

# A bare URL has no remote-tracking refs to rule commits out.
new_repo "$root/url"
put "$root/url" main b.txt "see $key"
check "a push to a bare URL carrying a hit is refused" refused \
      "$root/url" --to "$root/url.git" main

new_repo "$root/url-clean"
put "$root/url-clean" main b.txt "nothing to see"
check "a clean push to a bare URL goes through" pushed \
      "$root/url-clean" --to "$root/url-clean.git" main

# The origin moves on with a commit this repo never fetched, so the remote
# side of the push names a commit that is not here.
for want in pushed refused; do
    dir="$root/force-$want"
    new_repo "$dir"
    commit_tree "$dir.git" main "$(git -C "$dir.git" rev-parse 'main^{tree}')" main
    if [ "$want" = pushed ]; then
        put "$dir" main b.txt "nothing to see"
        check "a clean force push over a commit not here goes through" pushed \
              "$dir" +main
    else
        put "$dir" main b.txt "see $key"
        check "a force push over a commit not here is scanned" refused \
              "$dir" +main
    fi
done

new_repo "$root/merge"
git -C "$root/merge" branch topic main
put "$root/merge" topic b.txt "nothing to see"
put "$root/merge" main c.txt "nothing to see"
merge "$root/merge" main topic d.txt "see $key"
check "a hit added by a merge resolution is refused" refused \
      "$root/merge" main

new_repo "$root/merge-clean"
git -C "$root/merge-clean" branch topic main
put "$root/merge-clean" topic b.txt "nothing to see"
put "$root/merge-clean" main c.txt "nothing to see"
merge "$root/merge-clean" main topic
check "a clean merge goes through" pushed "$root/merge-clean" main

# Moving a file adds no lines, so a hit it carried onto the origin stays the
# origin's.
new_repo "$root/rename"
put "$root/rename" main b.txt "see $key"
seed "$root/rename" main
move "$root/rename" main b.txt c.txt
check "renaming a file whose hit is already on the origin goes through" pushed \
      "$root/rename" main

new_repo "$root/cap"
put "$root/cap" main b.txt "one"
put "$root/cap" main b.txt "two"
put "$root/cap" main b.txt "three"
git -C "$root/cap" config scrub.pushMaxCommits 2
check "a push over the commit cap is refused" refused "$root/cap" main
git -C "$root/cap" config scrub.pushMaxCommits 3
check "a push the repo's raised cap allows goes through" pushed \
      "$root/cap" main

new_repo "$root/cap-bad"
put "$root/cap-bad" main b.txt "nothing to see"
git -C "$root/cap-bad" config scrub.pushMaxCommits lots
check "a malformed commit cap is refused" refused "$root/cap-bad" main

# not_shown DESCRIPTION asserts the last push printed no hit.
not_shown() {
    if grep -q "$key" <<<"$last_out"; then
        echo "FAIL  $1"
        fail=$((fail + 1))
    else
        echo "ok    $1"
        pass=$((pass + 1))
    fi
}

# git skips the remerge diff of a merge with three or more parents, and says
# so only on stderr. The octopus here adds d.txt, which no parent has.
for want in pushed refused; do
    dir="$root/octopus-$want"
    new_repo "$dir"
    base="$(git -C "$dir" rev-parse main)"
    put "$dir" x x.txt "nothing to see"
    put "$dir" y y.txt "nothing to see"
    put "$dir" main x.txt "nothing to see"
    put "$dir" main y.txt "nothing to see"
    if [ "$want" = refused ]; then
        put "$dir" main d.txt "see $key"
    fi
    commit_tree "$dir" main "$(git -C "$dir" rev-parse 'main^{tree}')" \
                "$base" refs/heads/x refs/heads/y
    if [ "$want" = refused ]; then
        check "a hit added by an octopus merge is refused" refused "$dir" main
    else
        check "a clean octopus merge goes through" pushed "$dir" main
    fi
done

new_repo "$root/msg"
put "$root/msg" main b.txt "nothing to see"
reword "$root/msg" main "fix the thing for $key"
check "a commit whose message has a hit is refused" refused "$root/msg" main
not_shown "a message hit is not printed"

new_repo "$root/msg-clean"
put "$root/msg-clean" main b.txt "nothing to see"
reword "$root/msg-clean" main "fix the thing

A body that names nothing."
check "a commit with a clean message goes through" pushed \
      "$root/msg-clean" main

new_repo "$root/fname"
put "$root/fname" main "see-$key.txt" "nothing to see"
reword "$root/fname" main "add a file"
check "an added file whose name is a hit is refused" refused "$root/fname" main
not_shown "a name hit is not printed"

new_repo "$root/fname-move"
put "$root/fname-move" main b.txt "nothing to see"
seed "$root/fname-move" main
move "$root/fname-move" main b.txt "see-$key.txt"
check "a file renamed to a name that is a hit is refused" refused \
      "$root/fname-move" main

# The pre-commit half, run straight against a staged set, as git would run it.
# precommit DESCRIPTION WANT DIR runs the hook in DIR. WANT is "passed" or
# "refused".
precommit() {
    local desc="$1" want="$2" dir="$3" out got
    if out="$(cd "$dir" && HOME="$root/home" "$hooks/pre-commit" 2>&1)"; then
        got=passed
    else
        got=refused
    fi
    # Other pre-commit checks can refuse too, so a refusal counts only when
    # the scrub made it.
    if [ "$got" = refused ] && ! grep -q '^scrub: refusing' <<<"$out"; then
        got="refused by another check"
    fi
    if [ "$got" = "$want" ]; then
        echo "ok    $desc"
        pass=$((pass + 1))
    else
        echo "FAIL  $desc: want $want, it was $got"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# stage DIR FILE TEXT writes FILE and stages it, as the author the identity
# check wants.
stage() {
    git -C "$1" config user.name "David Greene"
    git -C "$1" config user.email "dag@obbligato.org"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add -- "$2"
}

new_repo "$root/pc-clean"
stage "$root/pc-clean" b.txt "nothing to see"
precommit "pre-commit: a clean staged change passes" passed "$root/pc-clean"

new_repo "$root/pc-plus"
stage "$root/pc-plus" b.txt "++ see $key"
precommit "pre-commit: a staged line that starts with ++ is scanned" refused \
          "$root/pc-plus"

new_repo "$root/pc-tab"
stage "$root/pc-tab" "a$(printf '\t')b.txt" "see $key"
precommit "pre-commit: a staged file with a tab in its name is scanned" refused \
          "$root/pc-tab"

new_repo "$root/pc-name"
stage "$root/pc-name" "see-$key.txt" "nothing to see"
precommit "pre-commit: a staged file whose name is a hit is refused" refused \
          "$root/pc-name"

echo "push-scrub-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

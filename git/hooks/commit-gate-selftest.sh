#!/usr/bin/env bash
# Assert the commit-time gate in commit-gate.sh. check.sh runs it.
#
# Exits 0 when every case holds, and 1 otherwise.
#
# Scratch repos in a throwaway directory, a temp HOME with a global config of
# its own, and a copy of the hooks under that HOME. The approval records and
# the rebase-land operation are written here in the documented format,
# because their writers live elsewhere. A guarded clone gets a network origin
# that nothing here ever contacts.
#
# The first section checks what git itself sends to reference-transaction,
# through a probe hook and not the chain, since every rule below leans on it.
set -euo pipefail
unset CLAUDECODE CLAUDE_CODE_SESSION_ID GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
root="$(mktemp -d)"
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT

export HOME="$root/home"
export GIT_CONFIG_GLOBAL="$root/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME/lib/pc/git"
hooks="$HOME/lib/pc/git/hooks"
cp -R "$here" "$hooks"

# A work realm whose identity is the test identity, so the personal scrub and
# the personal identity rule stay out of these commits.
realm="$root/realm"
printf '%s\n' 'email *@example.com' 'identity dev@example.com' > "$realm"
: > "$GIT_CONFIG_GLOBAL"
git config --global user.name "Test Person"
git config --global user.email dev@example.com
git config --global core.hooksPath "$hooks"
git config --global realm.workFile "$realm"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global commit.gpgSign false

# A stand-in `ssh' first on PATH answers `ssh -G' as a config with two
# aliases for github.com would, so no real ssh config is read. The gate
# takes no ssh config from its environment.
mkdir -p "$root/bin"
cat > "$root/bin/ssh" <<'EOF'
#!/bin/sh
[ "$1" = -G ] || exit 255
case "$2" in
  greened-github|alias-gh) h=github.com ;;
  *) h="$2" ;;
esac
printf 'host %s\nhostname %s\n' "$2" "$h"
EOF
chmod +x "$root/bin/ssh"
# A stand-in `getent' plays the password database, whose home holds the
# exempt list. It is not HOME, so a list under HOME is shown to count for
# nothing.
pwhome="$root/pwhome"
cat > "$root/bin/getent" <<EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
printf '%s:x:1:1::%s:/bin/sh\n' "\$2" "$pwhome"
EOF
chmod +x "$root/bin/getent"
export PATH="$root/bin:$PATH"

log="$HOME/.local/state/commitgate/decisions.log"
zero=0000000000000000000000000000000000000000

ok() { echo "ok    $1"; pass=$((pass + 1)); }
bad() {
    echo "FAIL  $1"
    [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /'
    fail=$((fail + 1))
}
# is DESCRIPTION COMMAND... passes when COMMAND succeeds.
is() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# --- What git sends to reference-transaction -----------------------------

probe="$root/probe"
mkdir -p "$probe"
plog="$root/probe.log"
# Logs every call. PROBE_REJECT=heads refuses a prepared refs/heads update,
# and PROBE_REJECT=all a detached HEAD update as well.
cat > "$probe/reference-transaction" <<EOF
#!/usr/bin/env bash
in="\$(cat)"
{ echo "== \$1"; [ -z "\$in" ] || printf '%s\n' "\$in"; } >> "$plog"
if [ "\$1" = prepared ]; then
  case "\${PROBE_REJECT:-}" in
    heads) printf '%s\n' "\$in" | grep -qE ' refs/heads/[^ ]+\$' && exit 1 ;;
    all) printf '%s\n' "\$in" | grep -qE '^[0-9a-f]+ [0-9a-f]+ (refs/heads/[^ ]+|HEAD)\$' && exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "$probe/reference-transaction"

p="$root/probe-repo"
git init -q "$p"
git -C "$p" config core.hooksPath "$probe"
git -C "$p" init -q --bare "$root/probe-up.git"
git -C "$p" remote add up "$root/probe-up.git"
probe_commit() { echo "$2" > "$p/$2"; git -C "$p" add "$2"; git -C "$p" commit -q -m "$2" "${@:3}"; }
probe_commit . a
probe_commit . b

: > "$plog"; probe_commit . c
if grep -qE '^[0-9a-f]{40} [0-9a-f]{40} refs/heads/main$' "$plog" &&
   ! grep -qE ' HEAD$' "$plog"; then
    ok "fact 12: a branch commit sends refs/heads/main and no HEAD line"
else
    bad "fact 12: a branch commit sends refs/heads/main and no HEAD line" "$(cat "$plog")"
fi
is "fact 14: git calls aborted for an empty transaction" grep -qx '== aborted' "$plog"

git -C "$p" checkout -q --detach
: > "$plog"; probe_commit . d
is "fact 12: a detached commit sends a HEAD line" \
   grep -qE '^[0-9a-f]{40} [0-9a-f]{40} HEAD$' "$plog"
: > "$plog"; git -C "$p" checkout -q main
is "fact 13: moving HEAD onto a branch sends a ref: value" \
   grep -qxE "$zero ref:refs/heads/main HEAD" "$plog"
: > "$plog"; git -C "$p" reset -q --hard HEAD~1
is "fact 13: pseudorefs such as ORIG_HEAD appear" grep -qE ' ORIG_HEAD$' "$plog"
git -C "$p" reset -q --hard main@{1}

for backend in --merge --apply; do
    git -C "$p" checkout -q -b "rb$backend" main~2
    probe_commit . "e$backend"
    probe_commit . "f$backend"
    : > "$plog"
    git -C "$p" rebase -q "$backend" main 2>/dev/null
    n_head="$(awk '/^== /{s=$2;next} s=="prepared" && /^[0-9a-f]{40} [0-9a-f]{40} HEAD$/' "$plog" | wc -l)"
    n_branch="$(awk -v r="refs/heads/rb$backend" '/^== /{s=$2;next} s=="prepared" && $3==r && $2 ~ /^[0-9a-f]{40}$/' "$plog" | wc -l)"
    is "fact 15: rebase $backend moves the detached HEAD for each pick" [ "$n_head" -ge 3 ]
    is "fact 15: rebase $backend moves the branch once, at the end" [ "$n_branch" -eq 1 ]
    git -C "$p" checkout -q main
done

# aborted_at DESCRIPTION REF SHA: the last output says the hook aborted the
# update, and REF still names SHA.
aborted_at() {
    if [ "$(git -C "$p" rev-parse "$2")" = "$3" ] &&
       grep -q 'ref updates aborted by hook' <<< "$out"; then
        ok "$1"
    else
        bad "$1" "$out"
    fi
}
h0="$(git -C "$p" rev-parse HEAD)"
echo g > "$p/g"; git -C "$p" add g
out="$(PROBE_REJECT=heads git -C "$p" commit -q -m g 2>&1 || true)"
aborted_at "fact 16: a refusal in prepared aborts a commit" HEAD "$h0"
out="$(PROBE_REJECT=heads git -C "$p" commit -q --amend -m g2 2>&1 || true)"
aborted_at "fact 16: a refusal in prepared aborts an amend" HEAD "$h0"
git -C "$p" reset -q --hard
git -C "$p" checkout -q --detach
echo h > "$p/h"; git -C "$p" add h
out="$(PROBE_REJECT=all git -C "$p" commit -q -m h 2>&1 || true)"
aborted_at "fact 16: a refusal in prepared aborts a detached commit" HEAD "$h0"
git -C "$p" reset -q --hard
git -C "$p" checkout -q main
git -C "$p" checkout -q -b rbx main~2
probe_commit . x
xtip="$(git -C "$p" rev-parse HEAD)"
out="$(PROBE_REJECT=heads git -C "$p" rebase -q main 2>&1 || true)"
aborted_at "fact 16: a refusal aborts the final rebase update" rbx "$xtip"
is "fact 16: a refused rebase is left with rebase-merge present" [ -d "$p/.git/rebase-merge" ]
git -C "$p" rebase --abort 2>/dev/null || true
git -C "$p" checkout -q main

git -C "$p" push -q up main 2>/dev/null
git -C "$root/probe-up.git" update-ref refs/heads/other "$(git -C "$p" rev-parse main~1)"
: > "$plog"; git -C "$p" fetch -q up
if grep -q ' refs/remotes/up/other$' "$plog" &&
   ! grep -qE ' (refs/heads/[^ ]+|HEAD)$' "$plog"; then
    ok "fact 17: fetch sends remote-tracking refs and no branch or HEAD"
else
    bad "fact 17: fetch sends remote-tracking refs and no branch or HEAD" "$(cat "$plog")"
fi

# --- Helpers for the gate cases -------------------------------------------

claude() { CLAUDECODE=1 "$@"; }

# run DESCRIPTION WANT DIR COMMAND... runs COMMAND in DIR. WANT is pass,
# refuse or refuse-push. A refusal must say what failed and print the fixed
# proceed line.
run() {
    local desc="$1" want="$2" dir="$3" out got cmd=git\ commit q
    shift 3
    if out="$(cd "$dir" && "$@" 2>&1)"; then got=pass; else got=refuse; fi
    last_out="$out"
    case "$want" in refuse-push) want=refuse cmd="git push" ;; esac
    if [ "$got" != "$want" ]; then
        bad "$desc: want $want, it was $got" "$out"
        return 0
    fi
    if [ "$want" = refuse ]; then
        printf -v q '%q' "$(git -C "$dir" rev-parse --show-toplevel)"
        if ! grep -q '^commit-gate: refused: ' <<< "$out"; then
            bad "$desc: no line says what failed" "$out"
            return 0
        fi
        if ! grep -qxF "commit-gate:   cd $q && $cmd" <<< "$out" ||
           ! grep -q 'commit agent' <<< "$out"; then
            bad "$desc: no proceed line" "$out"
            return 0
        fi
    fi
    ok "$desc"
}

said() {
    if grep -qF -- "$2" <<< "$last_out"; then ok "$1"; else bad "$1" "$last_out"; fi
}

# new_repo DIR [ORIGIN] makes a clone with one commit by a non-Claude caller.
# ORIGIN defaults to a network URL, and an empty one means no remote.
new_repo() {
    local d="$1" url
    url="${2-git@github.com:acme/${1##*/}.git}"
    git init -q "$d"
    [ -z "$url" ] || git -C "$d" remote add origin "$url"
    echo base > "$d/base.txt"
    git -C "$d" add base.txt
    git -C "$d" commit -q -m base
}

stage() { echo "$3" > "$1/$2"; git -C "$1" add "$2"; }
tip() { git -C "$1" rev-parse "${2:-HEAD}"; }
gitdir() { git -C "$1" rev-parse --absolute-git-dir; }
nonce() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }

# write_rec DIR LINE... writes one record the way the writers do: a 0600 temp
# file in the same directory, renamed into place under a fresh nonce.
write_rec() {
    local dir="$1" n
    shift
    mkdir -p "$dir"
    n="$(nonce)"
    (umask 077 && printf '%s\n' "$@" > "$dir/.tmp-$n")
    mv "$dir/.tmp-$n" "$dir/$n"
    last_rec="$dir/$n"
}

# rec_commit DIR REF OLD PARENT MESSAGE approves the staged tree with MESSAGE.
rec_commit() {
    local d="$1" tree mh
    tree="$(git -C "$d" write-tree)"
    mh="$(printf '%s\n' "$5" | git -C "$d" stripspace | git -C "$d" hash-object --stdin)"
    write_rec "$(gitdir "$d")/claude-approvals" v=1 kind=commit "ref=$2" \
        "old=$3" "parent=$4" "tree=$tree" "msg=$mh"
}

rec_move() {
    write_rec "$(gitdir "$1")/claude-approvals" v=1 kind=move "ref=$2" \
        "old=$3" "new=$4"
}

clear_recs() { rm -rf "$(gitdir "$1")/claude-approvals"; }

log_lines() { if [ -f "$log" ]; then wc -l < "$log" | tr -d ' '; else echo 0; fi; }

# --- Caller, mode and the decisions log -----------------------------------

r="$root/plain"
new_repo "$r"
stage "$r" a.txt a
run "mode unset: a guarded commit by Claude is refused" refuse "$r" \
    claude git commit -q -m "add a"
is "the refusal is logged" grep -q $'\trefuse\t' "$log"
CLAUDE_CODE_SESSION_ID=s run "CLAUDE_CODE_SESSION_ID alone marks Claude" refuse "$r" \
    git commit -q -m "add a"
before="$(log_lines)"
run "a non-Claude caller passes with no record" pass "$r" git commit -q -m "add a"
is "a non-Claude caller is not judged at all" [ "$(log_lines)" = "$before" ]

git config --global commitgate.mode warn
stage "$r" b.txt b
before="$(log_lines)"
run "warn: the same commit passes" pass "$r" claude git commit -q -m "secret words here"
said "warn: it still says what would fail" "commit-gate: warn: enforce mode would refuse this"
IFS=$'\t' read -r l_time l_repo l_ref l_new l_caller l_dec l_why <<< "$(tail -n 1 "$log")"
if [ -n "$l_time" ] && [ "$l_repo" = "$r" ] && [ "$l_ref" = refs/heads/main ] &&
   [ "$l_new" = "$(tip "$r")" ] && [ "$l_caller" = claude ] &&
   [ "$l_dec" = warn ] && [ -n "$l_why" ]; then
    ok "warn: the log line has time, repo, ref, sha, caller, decision and reason"
else
    bad "warn: the log line has time, repo, ref, sha, caller, decision and reason" \
        "$(tail -n 1 "$log")"
fi
if [ "$(log_lines)" -gt "$before" ] && ! grep -q 'secret words' "$log"; then
    ok "warn: logged, and the log holds no message text"
else
    bad "warn: logged, and the log holds no message text"
fi

git config --global commitgate.mode bogus
stage "$r" c.txt c
run "a malformed mode reads as enforce" refuse "$r" claude git commit -q -m "add c"
git config --global commitgate.mode off
before="$(log_lines)"
run "mode off: a Claude commit passes" pass "$r" claude git commit -q -m "add c"
is "mode off: nothing is logged" [ "$(log_lines)" = "$before" ]
git config --global commitgate.mode enforce
stage "$r" d.txt d
run "mode enforce: refused" refuse "$r" claude git commit -q -m "add d"
git config --global --unset commitgate.mode
# The real global config sets the mode in ~/.gitconfig.local through an
# include.
git config --file "$root/gitconfig.local" commitgate.mode off
git config --global include.path "$root/gitconfig.local"
run "mode off in an included file: a Claude commit passes" pass "$r" \
    claude git commit -q -m "add d"
git config --global --unset include.path
stage "$r" e.txt e
git -C "$r" config commitgate.mode off
run "mode off in the repo's own config: still refused" refuse "$r" \
    claude git commit -q -m "add e"
git -C "$r" config --unset commitgate.mode

# --- Commit records --------------------------------------------------------

r="$root/rec"
new_repo "$r"
# The chain buffers the ref lines, so the repo-local hook must still get them.
cat > "$(gitdir "$r")/hooks/reference-transaction" <<EOF
#!/bin/sh
cat >> "$root/local-reftxn"
EOF
chmod +x "$(gitdir "$r")/hooks/reference-transaction"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add a"
run "a matching commit record passes" pass "$r" claude git commit -q -m "add a"
is "the committed state deletes the matched record" [ ! -e "$last_rec" ]
is "the repo-local reference-transaction hook still gets the ref lines" \
   grep -q " $(tip "$r") refs/heads/main\$" "$root/local-reftxn"
rm -f "$(gitdir "$r")/hooks/reference-transaction"

# git sends a zero old value for an update that names none, and the ref has
# moved by `committed', so only what `prepared' kept can find the record.
stage "$r" p.txt p
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" plumb
c="$(git -C "$r" commit-tree "$(git -C "$r" write-tree)" -p HEAD -m plumb)"
run "update-ref with no old value passes on a record" pass "$r" \
    claude git update-ref refs/heads/main "$c"
is "and the committed state deletes that record" [ ! -e "$last_rec" ]
is "and leaves no transaction file behind" \
   [ -z "$(find "$(gitdir "$r")/claude-approvals" -name '.txn-*' 2>/dev/null)" ]

# One transaction, two updates. git sorts them by name, so main is judged
# and kept first, then zz is refused. The `aborted' state must drop what
# `prepared' kept, and the record must stay for a retry.
stage "$r" t.txt t
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" both
c="$(git -C "$r" commit-tree "$(git -C "$r" write-tree)" -p HEAD -m both)"
lone="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m lone)"
h0="$(tip "$r")"
run "a transaction with one approved and one unapproved update is refused" refuse "$r" \
    claude git update-ref --stdin <<< "update refs/heads/main $c $h0
create refs/heads/zz $lone"
is "and the main update did not land" [ "$(tip "$r")" = "$h0" ]
is "and the aborted state removes the kept match" \
   [ -z "$(find "$(gitdir "$r")/claude-approvals" -name '.txn-*' 2>/dev/null)" ]
is "and the record stays for a retry" [ -e "$last_rec" ]
git -C "$r" reset -q
rm -f "$r/t.txt"
clear_recs "$r"

# git ignores a failure outside `prepared', so a repo-local hook that fails
# in `committed' must not stop the gate's cleanup.
printf '%s\n' '#!/bin/sh' 'cat > /dev/null' '[ "$1" != committed ] || exit 1' \
    > "$(gitdir "$r")/hooks/reference-transaction"
chmod +x "$(gitdir "$r")/hooks/reference-transaction"
stage "$r" q.txt q
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add q"
run "a commit passes though the repo-local hook fails in committed" pass "$r" \
    claude git commit -q -m "add q"
is "and the gate still deletes the record" [ ! -e "$last_rec" ]
printf '%s\n' '#!/bin/sh' 'cat > /dev/null' '[ "$1" != prepared ] || exit 1' \
    > "$(gitdir "$r")/hooks/reference-transaction"
stage "$r" s.txt s
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add s"
h0="$(tip "$r")"
if ! (cd "$r" && claude git commit -q -m "add s" >/dev/null 2>&1) && [ "$(tip "$r")" = "$h0" ]; then
    ok "a repo-local hook that fails in prepared still aborts the commit"
else
    bad "a repo-local hook that fails in prepared still aborts the commit"
fi
rm -f "$(gitdir "$r")/hooks/reference-transaction"
git -C "$r" reset -q
rm -f "$r/s.txt"
clear_recs "$r"

stage "$r" b.txt b
run "an amend with no record is refused" refuse "$r" \
    claude git commit -q --amend -m "add a and b"
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r" HEAD~1)" "add a and b"
run "an amend with a record naming the old tip's parent passes" pass "$r" \
    claude git commit -q --amend -m "add a and b"

r="$root/root"
git init -q "$r"
git -C "$r" remote add origin git@github.com:acme/root.git
stage "$r" a.txt a
run "a root commit with no record is refused" refuse "$r" claude git commit -q -m first
rec_commit "$r" refs/heads/main none none first
run "a root commit with a record passes" pass "$r" claude git commit -q -m first
stage "$r" b.txt b
run "a root amend with no record is refused" refuse "$r" \
    claude git commit -q --amend -m "first again"
rec_commit "$r" refs/heads/main "$(tip "$r")" none "first again"
run "a root amend with a record passes" pass "$r" claude git commit -q --amend -m "first again"
is "a root amend leaves a root" [ -z "$(git -C "$r" rev-list --parents -n 1 HEAD | cut -s -d' ' -f2)" ]

r="$root/wt-main"
new_repo "$r"
git -C "$r" worktree add -q "$root/wt-b" -b wb
stage "$root/wt-b" w.txt w
rec_commit "$root/wt-b" refs/heads/wb "$(tip "$root/wt-b")" "$(tip "$root/wt-b")" "in a worktree"
run "a record in a linked worktree's own git dir passes" pass "$root/wt-b" \
    claude git commit -q -m "in a worktree"

# --- Stale records ---------------------------------------------------------

r="$root/stale"
new_repo "$r"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" approved
run "a record cannot approve a different message" refuse "$r" \
    claude git commit -q --no-verify -m "something else"
said "--no-verify does not skip the reference-transaction check" "ref updates aborted by hook"
stage "$r" b.txt b
run "a record cannot approve a different tree" refuse "$r" claude git commit -q -m approved
git -C "$r" reset -q
clear_recs "$r"
stage "$r" a.txt a
other="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -m elsewhere)"
rec_commit "$r" refs/heads/main "$(tip "$r")" "$other" approved
run "a record cannot approve a different parent" refuse "$r" claude git commit -q -m approved
clear_recs "$r"
rec_commit "$r" refs/heads/other "$(tip "$r")" "$(tip "$r")" approved
run "a record cannot approve a different ref" refuse "$r" claude git commit -q -m approved
clear_recs "$r"
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" approved
sed -i.bak '1s/v=1/v=2/' "$last_rec" && rm -f "$last_rec.bak"
run "a record of an unknown version is ignored" refuse "$r" claude git commit -q -m approved
clear_recs "$r"
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" approved
echo "tree=$(git -C "$r" write-tree)" >> "$last_rec"
run "a record with a repeated key is ignored" refuse "$r" claude git commit -q -m approved
clear_recs "$r"
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" approved
mv "$last_rec" "$(dirname "$last_rec")/not-a-nonce"
run "a record not named by a nonce is ignored" refuse "$r" claude git commit -q -m approved
clear_recs "$r"

c="$(git -C "$r" commit-tree "$(git -C "$r" write-tree)" -p HEAD -m plumbing)"
run "a commit made by commit-tree and update-ref is refused" refuse "$r" \
    claude git update-ref refs/heads/main "$c"

# --- Hooks that change an approved commit ---------------------------------

# The record binds the message and tree as approved, so a rewrite on the way
# in must refuse with its cause rather than surface as a bare mismatch.
nostrip="$root/no-trailer-policy.py"
printf '%s\n' 'print("no")' > "$nostrip"
trailer="Co-Authored-By: Cla""ude Test"
r="$root/trailer"
new_repo "$r"
git -C "$r" config trailer.policyPath "$nostrip"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add a

$trailer"
run "the chain's trailer strip refuses rather than rewrite a Claude commit" refuse "$r" \
    claude git commit -q -m "add a

$trailer"
said "the trailer refusal says how to fix it" \
     "Remove the trailer from the message, then run commit-land again."
run "a non-Claude commit still has its trailer stripped" pass "$r" \
    git commit -q -m "add a

$trailer"
if ! git -C "$r" log -1 --format=%B | grep -qF "$trailer"; then
    ok "and the trailer is gone"
else
    bad "and the trailer is gone"
fi

r="$root/msg-hook"
new_repo "$r"
printf '%s\n' '#!/bin/sh' 'echo "Extra: line" >> "$1"' > "$(gitdir "$r")/hooks/commit-msg"
chmod +x "$(gitdir "$r")/hooks/commit-msg"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add a"
run "a repo-local commit-msg rewrite of a Claude commit is refused" refuse "$r" \
    claude git commit -q -m "add a"
said "it names the repo-local hook" "the repo-local commit-msg hook changed the approved message"

r="$root/stage-hook"
new_repo "$r"
printf '%s\n' '#!/bin/sh' 'echo extra > extra.txt && git add extra.txt' \
    > "$(gitdir "$r")/hooks/pre-commit"
chmod +x "$(gitdir "$r")/hooks/pre-commit"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add a"
run "a pre-commit that stages files after approval is refused" refuse "$r" \
    claude git commit -q -m "add a"
said "it names the tree mismatch" "the staged tree is not the approved tree"
rm -f "$(gitdir "$r")/hooks/pre-commit" "$r/extra.txt"
git -C "$r" reset -q
clear_recs "$r"
stage "$r" a.txt a
rec_commit "$r" refs/heads/main "$(tip "$r")" "$(tip "$r")" "add a"
stage "$r" b.txt b
c="$(printf 'add a\n' | git -C "$r" commit-tree "$(git -C "$r" write-tree)" -p HEAD)"
run "reference-transaction refuses a tree the record did not approve" refuse "$r" \
    claude git update-ref refs/heads/main "$c"
said "and names the tree mismatch" "the commit's tree is not the approved tree"

# The pre-commit formatter changes the tree after approval, and for a Claude
# commit it says so. A stand-in formatter rewrites every file it is given,
# and the empty git-clang-format marks the tree as one the formatter covers.
# No remote, so the gate passes and only the note is under test.
fmtbin="$root/fake-clang-format"
printf '%s\n' '#!/bin/sh' 'cat' 'echo "// formatted"' > "$fmtbin"
chmod +x "$fmtbin"
r="$root/fmt"
new_repo "$r" ""
git -C "$r" config format.clangFormatBin "$fmtbin"
mkdir -p "$r/clang/tools/clang-format"
: > "$r/clang/tools/clang-format/git-clang-format"
stage "$r" f.cpp 'int f();'
run "a Claude commit with reformatted C++ still commits" pass "$r" claude git commit -q -m fmt
said "and the formatter's note names the commit-time gate" "gate will not find it approved"
stage "$r" g.cpp 'int g();'
run "a commit by anyone else with reformatted C++ commits" pass "$r" git commit -q -m fmt2
if grep -q 'reformatted staged lines' <<< "$last_out" &&
   ! grep -q 'gate will not find it approved' <<< "$last_out"; then
    ok "and gets the format line without the gate note"
else
    bad "and gets the format line without the gate note" "$last_out"
fi

# --- Replace objects -------------------------------------------------------

r="$root/replace"
new_repo "$r"
p0="$(tip "$r")"
t0="$(tip "$r" 'HEAD^{tree}')"
x="$(git -C "$r" commit-tree "$t0" -p "$p0" -m unapproved)"
y="$(git -C "$r" commit-tree "$t0" -p "$p0" -m approved)"
rec_commit "$r" refs/heads/main "$p0" "$p0" approved
git -C "$r" replace "$x" "$y"
if git -C "$r" cat-file commit "$x" | grep -qx approved; then
    ok "the replacement is live for an ordinary read"
else
    bad "the replacement is live for an ordinary read"
fi
run "a replacement cannot stand in for the real commit" refuse "$r" \
    claude git update-ref refs/heads/main "$x" "$p0"
run "the real approved commit passes" pass "$r" claude git update-ref refs/heads/main "$y" "$p0"

# --- Operations that make commits -----------------------------------------

r="$root/ops"
new_repo "$r"
git -C "$r" checkout -q -b side
stage "$r" s.txt s
git -C "$r" commit -q -m side
git -C "$r" checkout -q main
stage "$r" m.txt m
git -C "$r" commit -q -m main
run "a cherry-pick is refused" refuse "$r" claude git cherry-pick side
said "a refused cherry-pick says how to back out" "git cherry-pick --abort"
git -C "$r" cherry-pick --abort 2>/dev/null || git -C "$r" reset -q --hard
git -C "$r" format-patch -q -1 side -o "$root/patches"
run "git am is refused" refuse "$r" claude git am -q "$root"/patches/*.patch
said "a refused am says how to back out" "git am --abort"
git -C "$r" am --abort 2>/dev/null || true
run "a merge is refused" refuse "$r" claude git merge -q --no-edit side
said "a refused merge says how to back out" "git merge --abort"
git -C "$r" merge --abort 2>/dev/null || git -C "$r" reset -q --hard
git -C "$r" checkout -q side
side_tip="$(tip "$r")"
run "a raw rebase is refused" refuse "$r" claude git rebase -q main
said "it is refused at the first pick, on the detached HEAD" "on a detached HEAD"
said "a refused rebase says to abort and use rebase-land" \
     "Run git rebase --abort first, then use rebase-land."
is "the branch did not move" [ "$(tip "$r" side)" = "$side_tip" ]
git -C "$r" rebase --abort
git -C "$r" checkout -q main

# --- Detached HEAD and rebase-land ----------------------------------------

r="$root/det"
new_repo "$r"
run "detaching at existing content passes" pass "$r" claude git checkout -q --detach
stage "$r" d.txt d
run "a detached commit outside an operation is refused" refuse "$r" \
    claude git commit -q -m detached
rec_commit "$r" HEAD "$(tip "$r")" "$(tip "$r")" detached
run "a detached commit with a record for HEAD passes" pass "$r" \
    claude git commit -q -m detached
is "and the committed state deletes the HEAD record" [ ! -e "$last_rec" ]
# Back to an ancestor of a detached HEAD passes, even off every branch.
det1="$(tip "$r")"
stage "$r" e.txt e
rec_commit "$r" HEAD "$det1" "$det1" "detached again"
run "a second detached commit with a record passes" pass "$r" \
    claude git commit -q -m "detached again"
run "reset --hard HEAD~1 back to an approved off-branch detached commit passes" pass "$r" \
    claude git reset -q --hard HEAD~1
is "and HEAD is that commit" [ "$(tip "$r")" = "$det1" ]
git -C "$r" checkout -q main
pub="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m published)"
git -C "$r" update-ref refs/remotes/origin/pub "$pub"
run "checking out a sha only a remote-tracking ref has passes" pass "$r" \
    claude git checkout -q --detach "$pub"
stage "$r" n.txt n
run "a new commit on that detached HEAD is still refused" refuse "$r" \
    claude git commit -q -m "new on detached"
said "it names the detached HEAD" "on a detached HEAD"
git -C "$r" reset -q
rm -f "$r/n.txt"
stray="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m stray)"
run "moving a detached HEAD to a commit no ref has is refused" refuse "$r" \
    claude git update-ref --no-deref HEAD "$stray"
is "and HEAD did not move" [ "$(tip "$r")" = "$pub" ]
git -C "$r" checkout -q main

# op_setup DIR builds main and a topic branch that forked from it, and
# prints nothing. It sets up, old, onto and picks for the operation.
op_setup() {
    local d="$1"
    new_repo "$d"
    up="$(tip "$d")"
    git -C "$d" checkout -q -b topic
    stage "$d" t1.txt t1; git -C "$d" commit -q -m t1
    stage "$d" t2.txt t2; git -C "$d" commit -q -m t2
    git -C "$d" checkout -q main
    stage "$d" m1.txt m1; git -C "$d" commit -q -m m1
    old="$(tip "$d" topic)"
    onto="$(tip "$d" main)"
    picks="$(git -C "$d" rev-list --reverse "$up..$old" | tr '\n' ' ')"
    picks="${picks% }"
}
write_op() {
    local opdir
    opdir="$(gitdir "$1")/claude-rebase-op"
    mkdir -p "$opdir"
    op_nonce="$(nonce)"
    printf '%s\n' v=1 "nonce=$op_nonce" ref=refs/heads/topic "old=$2" \
        "onto=$onto" "upstream=$up" "picks=$picks" > "$opdir/op"
}
# The sequence editor rebase-land uses: it leaves the todo alone and drops
# the marker, holding OP_MARK, in git's rebase directory.
cat > "$root/seq-mark" <<'EOF'
#!/bin/sh
printf '%s\n' "$OP_MARK" > "$(dirname "$1")/claude-rebase-land"
EOF
chmod +x "$root/seq-mark"
# op_rebase MARK runs the rebase the way rebase-land does, marked with MARK.
op_rebase() {
    claude env GIT_SEQUENCE_EDITOR="$root/seq-mark" OP_MARK="$1" \
        git rebase -q -i --onto "$onto" "$up"
}

r="$root/op"
op_setup "$r"
write_op "$r" "$old"
run "detaching at the branch passes" pass "$r" claude git checkout -q --detach topic
run "the picks of a live rebase-land operation pass" pass "$r" op_rebase "$op_nonce"
new="$(tip "$r")"
rec_move "$r" refs/heads/topic "$old" "$new"
other="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p "$new" -m other)"
run "a move record does not approve a different new tip" refuse "$r" \
    claude git update-ref refs/heads/topic "$other" "$old"
run "a move record passes the exact update-ref" pass "$r" \
    claude git update-ref refs/heads/topic "$new" "$old"
is "the committed state deletes the move record" [ ! -e "$last_rec" ]
run "back on the branch" pass "$r" claude git checkout -q topic
rm -rf "$(gitdir "$r")/claude-rebase-op"

r="$root/op-wrong"
op_setup "$r"
write_op "$r" "$onto"
git -C "$r" checkout -q --detach topic
run "an operation whose old tip disagrees with git's rebase covers nothing" refuse "$r" \
    op_rebase "$op_nonce"
git -C "$r" rebase --abort
write_op "$r" "$old"
run "a rebase from the op's tips onto its base but with no marker covers nothing" \
    refuse "$r" claude git rebase -q --onto "$onto" "$up"
git -C "$r" rebase --abort
run "a rebase whose marker holds another nonce covers nothing" refuse "$r" \
    op_rebase "$(nonce)"
git -C "$r" rebase --abort
git -C "$r" checkout -q topic
run "a marked rebase run on the branch, not a detached HEAD, covers nothing" refuse "$r" \
    op_rebase "$op_nonce"
# Without the head-name check the picks pass and only the final branch
# update is refused, with a different reason.
said "it is refused at the first pick, on the detached HEAD" "on a detached HEAD"
git -C "$r" rebase --abort
git -C "$r" checkout -q --detach topic
run "a marker with a line after the nonce covers nothing" refuse "$r" \
    op_rebase "$op_nonce"$'\n'extra
said "it is refused at the first pick" "on a detached HEAD"
git -C "$r" rebase --abort
git -C "$r" checkout -q --detach topic
stage "$r" d.txt d
run "a live operation does not cover a commit outside its rebase" refuse "$r" \
    claude git commit -q -m detached

# --- Updates that publish nothing new -------------------------------------

r="$root/nonew"
new_repo "$r"
stage "$r" a.txt a; git -C "$r" commit -q -m a
stage "$r" b.txt b; git -C "$r" commit -q -m b
gone="$(tip "$r")"
run "a reset backwards passes" pass "$r" claude git reset -q --hard HEAD~1
git -C "$r" update-ref refs/remotes/origin/main "$gone"
run "a fast-forward to remote-tracking content passes" pass "$r" \
    claude git merge -q --ff-only origin/main
run "a branch made at existing content passes" pass "$r" claude git branch made HEAD~1
run "checkout -b at existing content passes" pass "$r" claude git checkout -q -b made2
dangling="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m dangling)"
run "a branch made at unpublished content is refused" refuse "$r" \
    claude git branch made3 "$dangling"
run "branch -f to unpublished content is refused" refuse "$r" \
    claude git branch -f made "$dangling"
run "a fast-forward to a local branch's new commit is refused" refuse "$r" \
    claude git update-ref refs/heads/made2 "$dangling"
git -C "$r" branch side
git -C "$r" checkout -q side
stage "$r" c.txt c; git -C "$r" commit -q -m c
git -C "$r" checkout -q made2
run "a fast-forward to another local branch's commit passes" pass "$r" \
    claude git merge -q --ff-only side
run "branch -f to another local branch's commit passes" pass "$r" \
    claude git branch -f made side
run "one transaction cannot vouch for its own new content" refuse "$r" \
    claude git update-ref --stdin <<< "create refs/heads/made4 $dangling
update refs/heads/made $dangling"
run "deleting a branch passes" pass "$r" claude git branch -q -D made
run "a tag on unpublished content is not judged" pass "$r" claude git tag t1 "$dangling"
run "a note is not judged" pass "$r" claude git notes add -m note HEAD

# A remote-tracking ref counts only when its remote is guarded. A scratch
# remote at an unguarded local repo can hold anything, so what is fetched
# from it is not published. origin above is a network URL, and counted.
git init -q --bare "$root/scratch.git"
lau="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m laundered)"
git -C "$r" push -q "$root/scratch.git" "$lau:refs/heads/x"
git -C "$r" remote add scratch "$root/scratch.git"
run "a fetch from an unguarded scratch remote passes" pass "$r" claude git fetch -q scratch
run "a fast-forward to what it fetched is refused" refuse "$r" \
    claude git merge -q --ff-only scratch/x
run "a branch made at what it fetched is refused" refuse "$r" \
    claude git branch fromscratch scratch/x
run "a detached checkout of what it fetched is refused" refuse "$r" \
    claude git checkout -q --detach scratch/x
is "and HEAD is still on made2" [ "$(git -C "$r" symbolic-ref -q HEAD)" = refs/heads/made2 ]
git init -q --bare "$root/gup.git"
git -C "$root/gup.git" remote add origin git@github.com:acme/gup.git
viag="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m via-guarded)"
git -C "$r" push -q "$root/gup.git" "$viag:refs/heads/y"
git -C "$r" remote add gup "$root/gup.git"
run "a fetch from a local remote that leads to a guarded clone passes" pass "$r" \
    claude git fetch -q gup
run "and a fast-forward to what it fetched passes" pass "$r" \
    claude git merge -q --ff-only gup/y
# The namespace is judged by what writes into it, not by its name. Here the
# unguarded scratch remote's refspec fills origin's namespace.
lau2="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m laundered2)"
git -C "$r" push -q "$root/scratch.git" "$lau2:refs/heads/z"
git -C "$r" config --add remote.scratch.fetch '+refs/heads/*:refs/remotes/origin/*'
run "a fetch by a scratch remote into origin's namespace passes" pass "$r" \
    claude git fetch -q scratch
is "and it wrote origin/z" [ "$(tip "$r" refs/remotes/origin/z)" = "$lau2" ]
run "a fast-forward to that origin/z is refused" refuse "$r" \
    claude git merge -q --ff-only origin/z
git -C "$r" config --unset remote.scratch.fetch 'origin'
git -C "$r" update-ref -d refs/remotes/origin/z

# A remote is judged by the URLs git really uses. Each case below makes
# origin/w, held by origin alone, stop counting. update-ref moves the branch,
# since it reads no remote config of its own.
w1="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m via-origin)"
git -C "$r" update-ref refs/remotes/origin/w "$w1"
ourl="$(git -C "$r" config remote.origin.url)"
git -C "$r" config "url.$root/scratch.git.insteadOf" "$ourl"
run "an insteadOf from origin's URL to a local unguarded repo makes origin not count" refuse "$r" \
    claude git update-ref refs/heads/made2 "$w1"
git -C "$r" config --unset "url.$root/scratch.git.insteadOf"
git config --global --add remote.origin.url "$root/scratch.git"
run "a global-scope local URL added to origin makes it not count" refuse "$r" \
    claude git update-ref refs/heads/made2 "$w1"
git config --global --unset remote.origin.url
# A transport helper may run a local command, so it guards but its refs
# prove nothing.
hx="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p HEAD -m via-helper)"
git -C "$r" remote add helper "ext::git-upload-pack $root/scratch.git"
git -C "$r" update-ref refs/remotes/helper/h "$hx"
run "an ext:: remote's refs do not count as published" refuse "$r" \
    claude git update-ref refs/heads/made2 "$hx"
git -C "$r" remote remove helper
# git reads `++a:b' as a forced refspec whose source is `+a'. This one
# writes only gup's own namespace, so origin still counts.
git -C "$r" config --add remote.gup.fetch '++refs/heads/*:refs/remotes/gup/*'
run "a doubled + refspec in gup's namespace leaves origin counting" pass "$r" \
    claude git update-ref refs/heads/made2 "$w1"
git -C "$r" config --unset --fixed-value remote.gup.fetch '++refs/heads/*:refs/remotes/gup/*'
# A refspec with no destination, or an empty one, writes only FETCH_HEAD.
w2="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p "$w1" -m via-origin-2)"
git -C "$r" update-ref refs/remotes/origin/w "$w2"
git -C "$r" config --add remote.origin.fetch refs/heads/main
git -C "$r" config --add remote.origin.fetch refs/heads/main:
run "refspecs with no destination leave origin counting" pass "$r" \
    claude git update-ref refs/heads/made2 "$w2"
git -C "$r" config --unset --fixed-value remote.origin.fetch refs/heads/main
git -C "$r" config --unset --fixed-value remote.origin.fetch refs/heads/main:
# These are git-failure tests. git refuses to load such a refspec, so `git
# remote' fails and no namespace counts whatever the gate's parser says.
# The parser cases after commit-gate.sh is sourced, below, are the
# regression tests for the parser itself.
w3="$(git -C "$r" commit-tree "$(tip "$r" 'HEAD^{tree}')" -p "$w2" -m via-origin-3)"
git -C "$r" update-ref refs/remotes/origin/w "$w3"
for spec in 'refs/heads/*:refs/remotes/origin/.bad' 'refs/heads/*:refs/remotes/origin/x'; do
    git -C "$r" config --add remote.origin.fetch "$spec"
    run "git refuses $spec, and then origin/w does not count" refuse "$r" \
        claude git update-ref refs/heads/made2 "$w3"
    git -C "$r" config --unset --fixed-value remote.origin.fetch "$spec"
done
run "with all of those gone, origin/w counts again" pass "$r" \
    claude git update-ref refs/heads/made2 "$w3"

# --- Which clones are guarded ---------------------------------------------

r="$root/fixture"
new_repo "$r" ""
stage "$r" a.txt a
run "a clone with no remote passes" pass "$r" claude git commit -q -m a

git init -q --bare "$root/fixture-up.git"
r="$root/fixture2"
new_repo "$r" "$root/fixture-up.git"
stage "$r" a.txt a
run "a clone whose only remote is an unguarded local repo passes" pass "$r" \
    claude git commit -q -m a

new_repo "$root/gsrc"
for form in abs rel file; do
    case "$form" in
        abs) url="$root/gsrc" ;;
        rel) url="../gsrc" ;;
        file) url="file://$root/gsrc" ;;
    esac
    r="$root/via-$form"
    new_repo "$r" "$url"
    stage "$r" a.txt a
    run "a $form local origin to a guarded clone is guarded" refuse "$r" \
        claude git commit -q -m a
done

r="$root/pushurl"
new_repo "$r" "$root/fixture-up.git"
git -C "$r" config remote.origin.pushurl git@github.com:acme/pushurl.git
stage "$r" a.txt a
run "a network push URL guards" refuse "$r" claude git commit -q -m a

r="$root/second"
new_repo "$r" ""
git -C "$r" remote add upstream https://github.com/acme/second
stage "$r" a.txt a
run "a network remote not named origin guards" refuse "$r" claude git commit -q -m a

new_repo "$root/cyc-a" ""
new_repo "$root/cyc-b" "$root/cyc-a"
git -C "$root/cyc-a" remote add origin "$root/cyc-b"
stage "$root/cyc-a" a.txt a
run "a cycle of local remotes fails guarded" refuse "$root/cyc-a" claude git commit -q -m a
is "the cycle is the logged reason" grep -q 'cycle' "$log"

new_repo "$root/chain5" ""
for i in 4 3 2 1 0; do
    new_repo "$root/chain$i" "$root/chain$((i + 1))"
done
stage "$root/chain4" a.txt a
run "one local hop to an unguarded repo passes" pass "$root/chain4" claude git commit -q -m a
stage "$root/chain0" a.txt a
run "more than four local hops fails guarded" refuse "$root/chain0" claude git commit -q -m a

r="$root/missing"
new_repo "$r" "$root/nowhere"
stage "$r" a.txt a
run "a local origin that does not exist fails guarded" refuse "$r" claude git commit -q -m a

mkdir -p "$root/plain-dir"
r="$root/notrepo"
new_repo "$r" "$root/plain-dir"
stage "$r" a.txt a
run "a local origin that is no repository fails guarded" refuse "$r" claude git commit -q -m a

# The canonical identity must agree with commit-land's canon_remote, which
# decides whether a record is written at all. These are its own examples,
# plus an ssh alias that the stand-in ssh resolves.
# shellcheck source=commit-gate.sh
. "$hooks/commit-gate.sh"
canon_is() {
    local got
    got="$(cg_canon_remote "$1")" || got=""
    if [ "$got" = "$2" ]; then
        ok "canon_remote $1 is ${2:-none}"
    else
        bad "canon_remote $1 is ${2:-none}, it was ${got:-none}"
    fi
}
canon_is git@github.com:someone/skills-personal.git github.com/someone/skills-personal
canon_is ssh://git@GitHub.com:22/someone/skills-personal/ github.com/someone/skills-personal
canon_is https://someone@github.com/someone/skills-personal.git github.com/someone/skills-personal
canon_is git://github.com/o/r github.com/o/r
canon_is file:///srv/o/r ""
canon_is /srv/o/r.git ""
canon_is ../r ""
canon_is https://github.com/o/../r ""
canon_is greened-github:greened/x.git github.com/greened/x
canon_is https://github.com/Acme/Ex github.com/Acme/Ex

# The refspec parser. A refspec it refuses turns every namespace off, so a
# form git refuses must be refused here too. rebase-land's selftest gives
# each of these the same verdict.
refspec_is() {
    local got
    if cg_refspec_dst "$1"; then got="ok:$cg_dst"; else got=refused; fi
    if [ "$got" = "$2" ]; then ok "refspec $1 is $2"; else bad "refspec $1 is $2, it was $got"; fi
}
# Each verdict was checked against what git 2.52 loads and fetches.
oid=7094fecfc02157c160129dc1f93c67296cce2e08
refspec_is '+refs/heads/*:refs/remotes/origin/*' 'ok:refs/remotes/origin/*'
refspec_is 'refs/heads/x:refs/remotes/origin/x' 'ok:refs/remotes/origin/x'
refspec_is '++refs/heads/*:refs/remotes/origin/*' 'ok:refs/remotes/origin/*'
refspec_is '@:refs/remotes/origin/HEAD' 'ok:refs/remotes/origin/HEAD'
refspec_is "$oid:refs/remotes/origin/x" 'ok:refs/remotes/origin/x'
refspec_is 'main:refs/remotes/origin/main' 'ok:refs/remotes/origin/main'
refspec_is ':refs/remotes/origin/head' 'ok:refs/remotes/origin/head'
refspec_is 'refs/heads/main' 'ok:'
refspec_is 'refs/heads/main:' 'ok:'
refspec_is '+' 'ok:'
refspec_is '^refs/heads/tmp' 'ok:'
refspec_is '^+refs/heads/x' 'ok:'
refspec_is 'refs/heads/*:refs/remotes/origin/.bad' refused
refspec_is 'refs/heads/*:refs/remotes/origin/x' refused
refspec_is 'refs/heads/x:refs/remotes/origin/*' refused
refspec_is 'refs/heads/*' refused
refspec_is 'refs/heads/*:' refused
refspec_is '^refs/heads/a:refs/b' refused
refspec_is "^$oid" refused
refspec_is '+^refs/heads/x' refused
refspec_is 'a:b:c' refused
refspec_is 'refs/heads/*/*:refs/remotes/origin/*/*' refused
# git expands this to refs/remotes/origin/x. The gate does not model that,
# so it is refused, which turns provenance off.
refspec_is 'refs/heads/main:remotes/origin/x' refused

exempt="$pwhome/.config/commitgate/exempt"
mkdir -p "${exempt%/*}" "$HOME/.config/commitgate"
printf '%s\n' github.com/acme/ex > "$HOME/.config/commitgate/exempt"
r="$root/ex-home"
new_repo "$r" git@github.com:acme/ex.git
stage "$r" a.txt a
run "an exempt list under HOME, not the passwd home, exempts nothing" refuse "$r" \
    claude git commit -q -m a
rm -f "$HOME/.config/commitgate/exempt"
printf '%s\n' '# repos whose own policy allows it' 'github.com/acme/ex   # trailing note' \
    'github.com/acme/aliased' '' > "$exempt"
for url in git@github.com:acme/ex.git https://GitHub.com/acme/ex.git \
           ssh://git@github.com:22/acme/ex/ alias-gh:acme/aliased.git; do
    r="$root/ex-$(nonce)"
    new_repo "$r" "$url"
    stage "$r" a.txt a
    run "an exempt identity passes: $url" pass "$r" claude git commit -q -m a
done
r="$root/ex-case"
new_repo "$r" https://github.com/Acme/ex.git
stage "$r" a.txt a
run "an exemption keeps the path's case" refuse "$r" claude git commit -q -m a
# Exemption covers the whole raw and effective URL union or nothing. Here
# the listed raw URL leads to an unguarded local repo, so no exemption
# applies and the raw URL alone guards, as commit-land refuses `0' here.
r="$root/ex-rewrite"
new_repo "$r" https://github.com/acme/ex.git
git -C "$r" config "url.$root/fixture-up.git.insteadOf" https://github.com/acme/ex.git
stage "$r" a.txt a
run "a listed raw URL that insteadOf sends to an unguarded local repo stays guarded" refuse "$r" \
    claude git commit -q -m a
r="$root/ex-base"
new_repo "$r" git@github.com:other/ex.git
stage "$r" a.txt a
run "an exemption matches the identity, not the basename" refuse "$r" claude git commit -q -m a
touch "$(gitdir "$r")/commit-agent-exempt"
run "a per-clone commit-agent-exempt file exempts, as in commit-land" pass "$r" \
    claude git commit -q -m a
rm -f "$(gitdir "$r")/commit-agent-exempt"
r="$root/ex-two"
new_repo "$r" git@github.com:acme/ex.git
git -C "$r" remote add fork git@github.com:fork/ex.git
stage "$r" a.txt a
run "one exempt remote does not cover another" refuse "$r" claude git commit -q -m a
r="$root/ex-bad"
new_repo "$r" git@github.com:acme/ex.git
stage "$r" a.txt a
echo "not an identity" >> "$exempt"
run "a malformed exempt file fails guarded" refuse "$r" claude git commit -q -m a
rm -f "$exempt"
run "with no exempt file nothing is exempt" refuse "$r" claude git commit -q -m a

# The grammar is commit-land's load_exempt. Its selftest gives each of these
# files the same verdict.
exempt_is() {
    local got=ok
    printf '%s\n' "${@:3}" > "$exempt"
    cg_load_exempt
    [ -z "$cg_exempt_bad" ] || got=bad
    if [ "$got" = "$2" ]; then ok "exempt grammar: $1 is $2"; else bad "exempt grammar: $1 is $2"; fi
}
exempt_is "a comment, a blank and a trailing note" ok '# note' '' 'github.com/acme/ex   # trailing'
exempt_is "a valid line beside one with a space" bad github.com/acme/ex 'not an identity'
exempt_is "an uppercase host" bad GitHub.com/acme/ex
exempt_is "a dot-dot path" bad github.com/acme/../ex
exempt_is "a doubled slash" bad github.com/acme//ex
exempt_is "a trailing slash" bad github.com/acme/ex/
exempt_is "a bare host" bad github.com
rm -f "$exempt"

r="$root/optout"
new_repo "$r"
git -C "$r" config --local commitgate.guard false
stage "$r" a.txt a
run "commitgate.guard false passes" pass "$r" claude git commit -q -m a
git -C "$r" config --local commitgate.guard maybe
stage "$r" b.txt b
run "a malformed commitgate.guard stays guarded" refuse "$r" claude git commit -q -m b

# --- Fetch, push and post-checkout ----------------------------------------

r="$root/pp"
new_repo "$r"
git init -q --bare "$root/pp-up.git"
git -C "$r" remote add up "$root/pp-up.git"
git -C "$r" push -q up main
git -C "$root/pp-up.git" update-ref refs/heads/theirs "$(tip "$r")"
before="$(log_lines)"
run "fetch passes" pass "$r" claude git fetch -q up
is "fetch is not judged at all" [ "$(log_lines)" = "$before" ]
git -C "$r" checkout -q --detach
stage "$r" d.txt d
git -C "$r" commit -q -m detached
dsha="$(tip "$r")"
git -C "$r" checkout -q main
run "a push of a commit on no local branch is refused" refuse-push "$r" \
    claude git push -q up "$dsha:refs/heads/x"
stage "$r" e.txt e
git -C "$r" commit -q -m e
run "a push of a local branch passes" pass "$r" claude git push -q up main

src="$root/pc-src.git"
git init -q --bare "$src"
git -C "$src" remote add origin git@github.com:acme/pc.git
git -C "$r" push -q "$src" main
git clone -q "$src" "$root/pc-clone"
is "post-checkout pins core.hooksPath in a guarded clone" \
   [ "$(git -C "$root/pc-clone" config --local --get core.hooksPath)" = "~/lib/pc/git/hooks" ]
git -C "$root/fixture-up.git" fetch -q "$r" main:main
git clone -q "$root/fixture-up.git" "$root/pc-plain"
if ! git -C "$root/pc-plain" config --local --get core.hooksPath >/dev/null; then
    ok "post-checkout leaves an unguarded clone alone"
else
    bad "post-checkout leaves an unguarded clone alone"
fi
git -C "$root/pc-clone" config --local --unset core.hooksPath
run "git worktree add still works" pass "$root/pc-clone" \
    git worktree add -q "$root/pc-wt" -b w
is "worktree add pins core.hooksPath too" \
   [ "$(git -C "$root/pc-clone" config --local --get core.hooksPath)" = "~/lib/pc/git/hooks" ]
git -C "$root/pc-clone" config --local --unset core.hooksPath
: > "$root/pc-clone/.git/config.lock"
run "post-checkout never fails the checkout" pass "$root/pc-clone" git checkout -q -b y
rm -f "$root/pc-clone/.git/config.lock"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

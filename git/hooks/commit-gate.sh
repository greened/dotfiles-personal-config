# shellcheck shell=bash
# The commit-time gate. `_chain' sources this file and calls
# `commitgate_dispatch' from reference-transaction, prepare-commit-msg,
# commit-msg, pre-push and post-checkout.
#
# In a guarded clone, a branch update by Claude that brings in new content
# needs a record that approves it: a commit record from commit-land or a move
# record from rebase-land. Updates that bring in nothing new pass on their
# own. Everything else from Claude is refused with a line that says how to
# proceed. Other callers are never judged.
#
# This is an accident guard, not a security boundary. The agent can write the
# git dir, so a forged record is out of scope.
#
# Every object read and reachability test runs with GIT_NO_REPLACE_OBJECTS=1,
# because a `refs/replace' entry would otherwise let the gate judge one commit
# while the branch gets another.
#
# Plain bash 3.2, since the Mac's system bash may be the one that runs it.

cg_nonce_re='^[0-9a-f]{32}$'
cg_sha_re='^([0-9a-f]{40}|[0-9a-f]{64})$'
cg_zero_re='^(0{40}|0{64})$'
cg_picks_re='^([0-9a-f]{40}( [0-9a-f]{40})*|[0-9a-f]{64}( [0-9a-f]{64})*)?$'
cg_id_re='^[a-z0-9][a-z0-9.-]*/[^[:space:]]*[^[:space:]/]$'
cg_host_re='^[a-z0-9][a-z0-9.-]*$'
cg_scp_parts_re='^([^/:]+):(.+)$'
cg_scheme_re='^[A-Za-z][A-Za-z0-9+.-]*://'
cg_helper_re='^[A-Za-z][A-Za-z0-9+.-]*::'
cg_scp_re='^[^/]*:'
cg_scp_net_re='^([^@/:]+@)?[A-Za-z0-9][A-Za-z0-9.-]*:.'

cg_git() { GIT_NO_REPLACE_OBJECTS=1 git "$@"; }

# Set, even to nothing, counts. A `!' command carries CLAUDECODE too.
cg_is_claude() {
  [ -n "${CLAUDECODE+x}" ] || [ -n "${CLAUDE_CODE_SESSION_ID+x}" ]
}

cg_is_sha() { [[ "$1" =~ $cg_sha_re ]] && ! [[ "$1" =~ $cg_zero_re ]]; }
cg_is_zero() { [[ "$1" =~ $cg_zero_re ]]; }

cg_say() {
  local l
  for l in "$@"; do printf 'commit-gate: %s\n' "$l" >&2; done
}

# Unset and malformed both read as enforce, so a typo cannot switch it off.
# Global only, so a repo's own config cannot switch it off either. Git skips
# includes when the scope is named, and the mode is set in an included file.
cg_mode() {
  local m
  m="$(git config --global --includes --get commitgate.mode 2>/dev/null || true)"
  case "$m" in
    off|warn|enforce) printf '%s' "$m" ;;
    *) printf enforce ;;
  esac
}

cg_repo() {
  git rev-parse --show-toplevel 2>/dev/null \
    || git rev-parse --absolute-git-dir 2>/dev/null \
    || pwd
}

# One line per guarded decision. The message is never written, only the ref
# and the sha, so the log holds nothing a commit said.
# The last column names the git operation, so a restack reads apart from a
# reset. It comes last so the older columns keep their places. Only the verb
# of GIT_REFLOG_ACTION is kept, with a one-word step such as `(pick)', because
# git pull puts its arguments there and a URL can carry a token. Git may not
# export it to hooks during a rebase, so a rebase directory in the git dir
# also marks one.
cg_log() {
  local dir="$HOME/.local/state/commitgate" repo why="$4" op="" path
  local op_re='^([a-z][a-z-]*)( \(([a-z-]+)\))?'
  repo="$(cg_repo)"
  repo="${repo//[$'\t\n\r']/ }"
  [ -z "${cg_guard_why:-}" ] || why="$why, guarded since $cg_guard_why"
  why="${why//[$'\t\n\r']/ }"
  if [[ "${GIT_REFLOG_ACTION:-}" =~ $op_re ]]; then
    op="${BASH_REMATCH[1]:0:40}"
    if [ -n "${BASH_REMATCH[3]:-}" ]; then
      op="$op (${BASH_REMATCH[3]:0:40})"
    fi
  fi
  if [ -z "$op" ]; then
    while IFS= read -r path; do
      if [ -n "$path" ] && [ -d "$path" ]; then
        op="rebase (in progress)"
        break
      fi
    done <<< "$(git rev-parse --git-path rebase-merge --git-path rebase-apply 2>/dev/null || true)"
  fi
  [ -n "$op" ] || op=-
  { mkdir -p "$dir" &&
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "$1" "$2" claude "$3" "$why" \
      "$op" >> "$dir/decisions.log"; } 2>/dev/null || true
}

# cg_refusal MODE WHAT [COMMAND] says what failed, what state git is left in,
# and the fixed way to proceed. COMMAND is what David runs, `git commit' unless
# given.
cg_refusal() {
  local mode="$1" what="$2" cmd="${3:-git commit}" gd q
  if [ "$mode" = warn ]; then
    cg_say "warn: enforce mode would refuse this: $what"
  else
    cg_say "refused: $what"
  fi
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$gd" ]; then
    if [ -d "$gd/claude-rebase-op" ]; then
      cg_say "a rebase-land operation is live here. Finish or abort it with rebase-land."
    elif [ -e "$gd/rebase-apply/applying" ]; then
      cg_say "a git am is in progress. Run git am --abort first."
    elif [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
      cg_say "a rebase is in progress. Run git rebase --abort first, then use rebase-land."
    elif [ -e "$gd/CHERRY_PICK_HEAD" ] || [ -d "$gd/sequencer" ]; then
      cg_say "a cherry-pick is in progress. Run git cherry-pick --abort first."
    elif [ -e "$gd/MERGE_HEAD" ]; then
      cg_say "a merge is in progress. Run git merge --abort first."
    fi
  fi
  printf -v q '%q' "$(cg_repo)"
  cg_say "to proceed, commit through the commit agent, or have David run it in his own terminal:" \
         "  cd $q && $cmd"
}

# --- Which clones are guarded --------------------------------------------

# cg_passwd_home prints the caller's home from the password database, as
# commit-land's passwd_home does, so the two read one exempt file whatever
# HOME says. The Mac has no getent, and there `~user' asks the same database.
cg_passwd_home() {
  local u h=""
  u="$(id -un 2>/dev/null)" || return 1
  [[ "$u" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || return 1
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  else
    eval "h=~$u"
  fi
  [[ "$h" == /?* ]] || return 1
  printf '%s' "$h"
}

# A malformed file turns every exemption off rather than guessing which
# lines were meant. commit-land's load_exempt is this grammar line for line,
# so the two never disagree on which repos are exempt. Keep them in step.
cg_load_exempt() {
  local f home line
  cg_exempt="" cg_exempt_bad=""
  if ! home="$(cg_passwd_home)"; then
    cg_exempt_bad=1
    return 0
  fi
  f="$home/.config/commitgate/exempt"
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    cg_exempt_bad=1
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    if ! [[ "$line" =~ $cg_id_re ]] || [[ "/$line/" == */../* || "/$line/" == *//* ]]; then
      cg_exempt="" cg_exempt_bad=1
      return 0
    fi
    cg_exempt="$cg_exempt$line"$'\n'
  done < "$f"
}

cg_exempt_has() {
  [ -z "$cg_exempt_bad" ] || return 1
  case $'\n'"$cg_exempt" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# cg_canon_remote URL prints the host/owner/repo a network remote names, or
# fails for a local path or a form it does not parse. It must agree with
# commit-land's canon_remote, which decides whether a record gets written at
# all, so it mirrors that function rule for rule. The host is lowercased and
# an ssh host goes through `ssh -G', so an alias names the host it reaches.
# User, port and `.git' are dropped and the path keeps its case.
cg_canon_remote() {
  local u="$1" rest host path ssh=1 real
  [[ ! "$u" =~ $cg_helper_re ]] || return 1
  case "$u" in
    ssh://*|git+ssh://*|ssh+git://*) rest="${u#*://}" ;;
    https://*|http://*|git://*) rest="${u#*://}" ssh=0 ;;
    *://*) return 1 ;;
    *)
      [[ "$u" =~ $cg_scp_parts_re ]] || return 1
      rest="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      ;;
  esac
  [[ "$rest" == */* ]] || return 1
  host="${rest%%/*}" path="${rest#*/}"
  host="${host##*@}"
  host="${host%%:*}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  [[ "$host" =~ $cg_host_re ]] || return 1
  if [ "$ssh" = 1 ] && command -v ssh >/dev/null 2>&1; then
    real="$(ssh -G "$host" 2>/dev/null |
            awk '$1 == "hostname" {print $2; exit}' | tr '[:upper:]' '[:lower:]')"
    [[ "$real" =~ $cg_host_re ]] && host="$real"
  fi
  path="${path#\~/}"
  while [[ "$path" == /* ]]; do path="${path#/}"; done
  while [[ "$path" == */ ]]; do path="${path%/}"; done
  path="${path%.git}"
  [[ -n "$path" && "/$path/" != */../* && "/$path/" != *//* ]] || return 1
  printf '%s/%s\n' "$host" "$path"
}

# Sets cg_u_kind to net, other, local or bad, and cg_u_val to the path of a
# local remote. net is a transport that reaches another host: ssh, https,
# http, git:// or the scp form. other is a transport helper such as `ext::'
# or a scheme this does not know. Either may run a local command, so other
# guards but never counts as published. A `file://' URL with a host part, or
# with escapes this cannot decode, is bad, which counts as guarded. Keep
# net in step with rebase-land's is_network_url.
cg_classify_url() {
  local u="$1" p
  cg_u_kind=bad cg_u_val=""
  [ -n "$u" ] || return 0
  case "$u" in
    file://*)
      p="${u#file://}"
      case "$p" in /*) ;; *) return 0 ;; esac
      case "$p" in *%*) return 0 ;; esac
      cg_u_kind=local cg_u_val="$p"
      return 0
      ;;
  esac
  case "$u" in
    ssh://*|git+ssh://*|ssh+git://*|https://*|http://*|git://*)
      case "${u#*://}" in ''|/*) cg_u_kind=other ;; *) cg_u_kind=net ;; esac
      return 0
      ;;
  esac
  if [[ "$u" =~ $cg_helper_re ]] || [[ "$u" =~ $cg_scheme_re ]]; then
    cg_u_kind=other
  elif [[ "$u" =~ $cg_scp_re ]]; then
    if [[ "$u" =~ $cg_scp_net_re ]]; then cg_u_kind=net; else cg_u_kind=other; fi
  else
    cg_u_kind=local cg_u_val="$u"
  fi
}

# cg_at DIR ARGS runs git in DIR, or in the hook's own repo when DIR is
# empty. The ceiling stops discovery from climbing out of DIR into some repo
# above it, and the hook's GIT_* settings belong to the hook's repo only.
cg_at() {
  local d="$1"
  shift
  if [ -z "$d" ]; then
    cg_git "$@"
    return
  fi
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
          GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
          GIT_NAMESPACE GIT_PREFIX
    export GIT_CEILING_DIRECTORIES="${d%/*}"
    cg_git -C "$d" "$@"
  )
}

# cg_union_exempt LINES: every `key url' line names a listed identity, and
# there is at least one. commit-land's is_exempt is this predicate.
cg_union_exempt() {
  local line id n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(cg_canon_remote "${line#* }")" || return 1
    cg_exempt_has "$id" || return 1
    n=$((n + 1))
  done <<< "$1"
  [ "$n" -gt 0 ]
}

# cg_guard DIR DEPTH SEEN returns 0 when the clone at DIR is guarded, and sets
# cg_guard_why. SEEN lists the git dirs on the path here, so a cycle is
# caught. Anything that cannot be resolved counts as guarded.
cg_guard() {
  local dir="$1" depth="$2" seen="$3" v rc gd top lines line key url p canon names name
  rc=0
  v="$(cg_at "$dir" config --local --type=bool --get commitgate.guard 2>/dev/null)" || rc=$?
  if [ "$rc" = 0 ] && [ "$v" = false ]; then
    return 1
  fi
  if ! gd="$(cg_at "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
     ! gd="$(cd "$gd" 2>/dev/null && pwd -P)"; then
    cg_guard_why="the git dir of ${dir:-this clone} cannot be read"
    return 0
  fi
  case "$seen" in
    *$'\n'"$gd"$'\n'*)
      cg_guard_why="its local remotes form a cycle"
      return 0
      ;;
  esac
  seen="$seen$gd"$'\n'
  # The raw local values and the URLs git really uses are both judged. An
  # insteadOf or a URL from another scope changes what git talks to, and
  # judging the raw values as well means a rewrite can only add guarding.
  rc=0
  lines="$(cg_at "$dir" config --local --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
    cg_guard_why="its remotes cannot be read"
    return 0
  fi
  if ! names="$(cg_at "$dir" remote 2>/dev/null)"; then
    cg_guard_why="its remotes cannot be read"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! cg_effective_urls "$dir" "$name"; then
      cg_guard_why="git gives no usable URL for remote $name"
      return 0
    fi
    while IFS= read -r url; do
      lines="$lines"$'\n'"remote.$name.effective $url"
    done <<< "$cg_urls"
  done <<< "$names"
  # Exemption is all or nothing over the whole union, as in commit-land's
  # is_exempt. One listed URL is never skipped on its own, since another URL
  # of the same clone may lead somewhere unlisted.
  if [ -n "$cg_exempt" ] && cg_union_exempt "$lines"; then
    return 1
  fi
  top="$(cg_at "$dir" rev-parse --show-toplevel 2>/dev/null)" || top="$gd"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%% *}"
    url="${line#* }"
    cg_classify_url "$url"
    case "$cg_u_kind" in
      net)
        cg_guard_why="$key is a network remote" cg_guard_net=1
        return 0
        ;;
      other)
        cg_guard_why="$key uses a transport helper or a scheme the gate does not know"
        return 0
        ;;
      local)
        p="$cg_u_val"
        case "$p" in /*) ;; *) p="$top/$p" ;; esac
        if [ "$depth" -ge 4 ]; then
          cg_guard_why="$key leads through more than four local remotes"
          return 0
        fi
        if ! canon="$(cd "$p" 2>/dev/null && pwd -P)" ||
           ! cg_at "$canon" rev-parse --absolute-git-dir >/dev/null 2>&1; then
          cg_guard_why="$key does not resolve to a repository"
          return 0
        fi
        if cg_guard "$canon" $((depth + 1)) "$seen"; then
          cg_guard_why="$key leads to a guarded clone: $cg_guard_why"
          return 0
        fi
        ;;
      *)
        cg_guard_why="$key cannot be classified"
        return 0
        ;;
    esac
  done <<< "$lines"
  return 1
}

# The per-clone `commit-agent-exempt' file exempts this clone the way it
# exempts it from commit-land's gate, so the two never disagree about it.
cg_guarded() {
  local gd
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  if [ -n "$gd" ] && [ -f "$gd/commit-agent-exempt" ]; then
    return 1
  fi
  cg_load_exempt
  cg_guard_why=""
  cg_guard "" 0 $'\n'
}

# --- Records ---------------------------------------------------------------

# cg_parse FILE KEYS reads a `v=1' file into cg_f_<key>. It fails on an
# unknown version, a key outside KEYS, a repeated or missing key, or a line
# that is not key=value. The file is read, never sourced.
cg_parse() {
  local f="$1" keys=" $2 " line n=0 key seen=" "
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -le 16 ] || return 1
    if [ "$n" = 1 ]; then
      [ "$line" = v=1 ] || return 1
      continue
    fi
    case "$line" in ?*=*) ;; *) return 1 ;; esac
    key="${line%%=*}"
    case "$keys" in *" $key "*) ;; *) return 1 ;; esac
    case "$seen" in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    printf -v "cg_f_$key" '%s' "${line#*=}"
  done < "$f"
  [ "${#seen}" = "${#keys}" ]
}

cg_head_ref_ok() {
  case "$1" in
    refs/heads/?*) git check-ref-format "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

cg_commit_record() {
  cg_parse "$1" "kind ref old parent tree msg" || return 1
  [ "$cg_f_kind" = commit ] || return 1
  [ "$cg_f_ref" = HEAD ] || cg_head_ref_ok "$cg_f_ref" || return 1
  { [ "$cg_f_old" = none ] || cg_is_sha "$cg_f_old"; } || return 1
  { [ "$cg_f_parent" = none ] || cg_is_sha "$cg_f_parent"; } || return 1
  cg_is_sha "$cg_f_tree" && cg_is_sha "$cg_f_msg"
}

cg_move_record() {
  cg_parse "$1" "kind ref old new" || return 1
  [ "$cg_f_kind" = move ] && cg_head_ref_ok "$cg_f_ref" &&
    cg_is_sha "$cg_f_old" && cg_is_sha "$cg_f_new"
}

# cg_load_commit SHA sets cg_c_tree, cg_c_parents and cg_c_msg, the hash of
# the stripspaced message, the same way commit-land hashes what it approves.
cg_load_commit() {
  local obj hdr msg line
  [ "${cg_c_sha:-}" != "$1" ] || return 0
  cg_c_sha="" cg_c_tree="" cg_c_parents="" cg_c_msg=""
  obj="$(cg_git cat-file commit "$1" 2>/dev/null)" || return 1
  case "$obj" in
    *$'\n\n'*) hdr="${obj%%$'\n\n'*}" msg="${obj#*$'\n\n'}" ;;
    *) hdr="$obj" msg="" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "tree "*) cg_c_tree="${line#tree }" ;;
      "parent "*) cg_c_parents="$cg_c_parents ${line#parent }" ;;
    esac
  done <<< "$hdr"
  cg_c_parents="${cg_c_parents# }"
  cg_c_msg="$(printf '%s\n' "$msg" | git stripspace | git hash-object --stdin)" || return 1
  cg_c_sha="$1"
}

# Parents of OLD, so a record can only name OLD itself or its first parent,
# which is all a commit or an amend produces.
cg_parents_of() {
  local out
  out="$(cg_git rev-list --parents -n 1 "$1" 2>/dev/null)" || return 1
  out="${out#"$1"}"
  printf '%s' "${out# }"
}

cg_records_dir() {
  local gd
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/claude-approvals' "$gd"
}

# cg_find_records REF OLD NEW sets cg_matched to the record files that approve
# this update. OLD is a sha or `none'.
cg_find_records() {
  local ref="$1" old="$2" new="$3" dir f name oldp
  cg_matched="" cg_matched_kind="" cg_near=""
  dir="$(cg_records_dir)" || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    name="${f##*/}"
    [[ "$name" =~ $cg_nonce_re ]] || continue
    if cg_commit_record "$f"; then
      [ "$cg_f_ref" = "$ref" ] && [ "$cg_f_old" = "$old" ] || continue
      cg_load_commit "$new" || continue
      if [ "$cg_c_tree" != "$cg_f_tree" ]; then
        cg_near="the commit's tree is not the approved tree. A hook such as a pre-commit formatter may have staged changes after approval. Format the staged lines first, as the commit agent's step 3b does, then land again with commit-land.sh."
        continue
      fi
      if [ "$cg_c_msg" != "$cg_f_msg" ]; then
        cg_near="the commit's message is not the approved message. A commit-msg hook may have rewritten it, or the commit did not come from commit-land."
        continue
      fi
      if [ "$cg_f_parent" = none ]; then
        [ -z "$cg_c_parents" ] || continue
        if [ "$old" != none ]; then
          oldp="$(cg_parents_of "$old")" || continue
          [ -z "$oldp" ] || continue
        fi
      else
        [ "$cg_c_parents" = "$cg_f_parent" ] || continue
        if [ "$cg_f_parent" != "$old" ]; then
          [ "$old" != none ] || continue
          oldp="$(cg_parents_of "$old")" || continue
          [ "${oldp%% *}" = "$cg_f_parent" ] || continue
        fi
      fi
      cg_matched="$cg_matched$f"$'\n' cg_matched_kind=commit
    elif cg_move_record "$f"; then
      [ "$cg_f_ref" = "$ref" ] && [ "$cg_f_old" = "$old" ] &&
        [ "$cg_f_new" = "$new" ] || continue
      cg_matched="$cg_matched$f"$'\n' cg_matched_kind=move
    fi
  done
}

# cg_txn_file DIR REF OLD NEW names the file that carries one update's
# matched records from `prepared' to `committed'. OLD is the value git sent,
# so both states name the same file. A dot name keeps it out of the record
# scan.
cg_txn_file() {
  local k
  k="$(printf '%s %s %s\n' "$2" "$3" "$4" | git hash-object --stdin 2>/dev/null)" || return 1
  cg_is_sha "$k" || return 1
  printf '%s/.txn-%s' "$1" "$k"
}

# cg_keep_matches REF OLD NEW saves cg_matched for the `committed' state.
# Best effort: a lost file leaves a record that can only approve the same
# commit again.
cg_keep_matches() {
  local dir t
  dir="$(cg_records_dir)" || return 0
  t="$(cg_txn_file "$dir" "$1" "$2" "$3")" || return 0
  { printf '%s' "$cg_matched" > "$t.tmp" && mv -f "$t.tmp" "$t"; } 2>/dev/null ||
    rm -f "$t.tmp" 2>/dev/null
  return 0
}

# --- Reachability and the rebase-land operation ---------------------------

# cg_reachable SHA REVS: SHA is reachable from REVS. A failed listing is
# never read as reachable.
cg_reachable() {
  local sha="$1" out
  shift
  out="$(cg_git rev-list -n 1 "$sha" --not "$@" -- 2>/dev/null)" || return 1
  [ -z "$out" ]
}

# cg_effective_urls DIR NAME sets cg_urls to the fetch and push URLs git
# uses for remote NAME of the repo at DIR: every config scope, with insteadOf
# and pushInsteadOf applied. It fails when either list cannot be read or is
# empty.
cg_effective_urls() {
  local f u
  cg_urls=""
  f="$(cg_at "$1" remote get-url --all "$2" 2>/dev/null)" && [ -n "$f" ] || return 1
  u="$(cg_at "$1" remote get-url --push --all "$2" 2>/dev/null)" && [ -n "$u" ] || return 1
  cg_urls="$f"$'\n'"$u"
}

# cg_url_published URL TOP: refs fetched from URL hold content that is
# already published. A network URL is, and so is a local path that the
# guard resolver calls guarded because a network remote lies behind it. An
# unguarded local repo can hold anything Claude put there, so fetching from
# it would launder that content. The resolver's other guarded verdicts, a
# cycle or an unreadable repo, fail closed for guarding and so prove nothing
# here.
cg_url_published() {
  local p canon rc saved="${cg_guard_why:-}"
  cg_classify_url "$1"
  case "$cg_u_kind" in
    net) return 0 ;;
    local) ;;
    *) return 1 ;;
  esac
  p="$cg_u_val"
  case "$p" in /*) ;; *) p="$2/$p" ;; esac
  canon="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  cg_at "$canon" rev-parse --absolute-git-dir >/dev/null 2>&1 || return 1
  rc=0 cg_guard_net=""
  cg_guard "$canon" 1 $'\n' || rc=$?
  cg_guard_why="$saved"
  [ "$rc" = 0 ] && [ -n "$cg_guard_net" ]
}

# cg_refspec_dst SPEC sets cg_dst to the remote ref a fetch refspec can
# write, or to nothing when it writes none, and fails when SPEC is not a
# fetch refspec git takes. The grammar is git's:
#   ^SRC              a negative refspec. SRC is a ref name or pattern, not
#                     an object ID, and nothing is written.
#   [+]SRC[:[DST]]    one leading `+' forces, and the rest is SRC, so in
#                     `++a:b' SRC is `+a'. SRC is empty, meaning HEAD, a full
#                     object ID, or a ref name or pattern. With no DST, or
#                     an empty one, nothing is written. A pattern SRC needs
#                     a pattern DST, and a plain SRC a plain one.
# Ref names may be one level, as git allows. git also expands a DST outside
# refs/, `remotes/o/x' to refs/remotes/o/x for one. That is not modelled,
# so such a DST fails here and no namespace counts. Keep this in step with
# rebase-land's refspec_dst.
cg_refspec_dst() {
  local s="$1" src dst
  cg_dst=""
  case "$s" in
    ^*)
      s="${s#^}"
      case "$s" in ''|*:*) return 1 ;; esac
      ! cg_is_oid "$s" || return 1
      cg_refname_ok "$s"
      return
      ;;
  esac
  s="${s#+}"
  case "$s" in
    *:*:*) return 1 ;;
    *:*) src="${s%%:*}" dst="${s#*:}" ;;
    *) src="$s" dst="" ;;
  esac
  case "$src" in
    *'*'*) case "$dst" in *'*'*) ;; *) return 1 ;; esac ;;
    *) case "$dst" in *'*'*) return 1 ;; esac ;;
  esac
  # Git reads a source of `@' as HEAD.
  [ "$src" != @ ] || src=HEAD
  if [ -n "$src" ] && ! cg_is_oid "$src"; then
    cg_refname_ok "$src" || return 1
  fi
  [ -n "$dst" ] || return 0
  case "$dst" in refs/?*) ;; *) return 1 ;; esac
  cg_refname_ok "$dst" || return 1
  cg_dst="$dst"
}

cg_is_oid() { [[ "$1" =~ $cg_sha_re ]]; }

# A ref name or a pattern with one `*', one level allowed.
cg_refname_ok() {
  case "$1" in
    *'*'*) git check-ref-format --allow-onelevel --refspec-pattern "$1" 2>/dev/null ;;
    *) git check-ref-format --allow-onelevel "$1" 2>/dev/null ;;
  esac
}

# cg_dst_overlaps DST PREFIX: a ref DST writes can fall under PREFIX. A `*'
# matches any string, slashes too, so only the part before it bounds DST.
cg_dst_overlaps() {
  local a
  case "$1" in
    *'*'*)
      a="${1%%\**}"
      [[ "$2" == "$a"* || "$a" == "$2"* ]]
      ;;
    *) [[ "$1" == "$2"* ]] ;;
  esac
}

# cg_published_revs sets cg_pub_revs to a --glob for each remote whose
# remote-tracking refs count as published. Computed once per hook run. A
# remote r counts only when all of these hold:
#   every effective URL and push URL of r passes cg_url_published
#   every fetch refspec of r writes under refs/remotes/<r>/ alone
#   no other remote's fetch refspec can write there
# Otherwise a fetch from an unguarded remote could fill a guarded remote's
# namespace. A refspec this cannot parse, or a remote whose URLs git cannot
# give, means no remote counts. Refspecs
# are read from every config scope, since any of them steers a fetch.
cg_published_revs() {
  local line key name url top bad="" seen="" specs dsts="" rc p q d ok
  [ -z "${cg_pub_done:-}" ] || return 0
  cg_pub_done=1 cg_pub_revs=()
  seen="$(cg_git remote 2>/dev/null)" || return 0
  top="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    top="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  rc=0
  specs="$(cg_git config --get-regexp '^remote\..*\.fetch$' 2>/dev/null)" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *" "*) ;; *) return 0 ;; esac
    key="${line%% *}" name="${key#remote.}" name="${name%.fetch}"
    cg_refspec_dst "${line#* }" || return 0
    [ -z "$cg_dst" ] || dsts="$dsts$name"$'\t'"$cg_dst"$'\n'
  done <<< "$specs"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cg_effective_urls "" "$name" || return 0
    while IFS= read -r url; do
      cg_url_published "$url" "$top" || bad="$bad$name"$'\n'
    done <<< "$cg_urls"
  done <<< "$seen"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *'*'*|*'?'*|*'['*|*\\*) continue ;; esac
    case $'\n'"$bad" in *$'\n'"$name"$'\n'*) continue ;; esac
    case " ${cg_pub_revs[*]-} " in *" --glob=refs/remotes/$name/* "*) continue ;; esac
    p="refs/remotes/$name/" ok=1
    while IFS=$'\t' read -r q d; do
      [ -n "$d" ] || continue
      if [ "$q" = "$name" ]; then
        [[ "$d" == "$p"* ]] || ok=""
      elif cg_dst_overlaps "$d" "$p"; then
        ok=""
      fi
      [ -n "$ok" ] || break
    done <<< "$dsts"
    [ -z "$ok" ] || cg_pub_revs+=("--glob=refs/remotes/$name/*")
  done <<< "$seen"
}

# cg_published SHA [REVS]: SHA is reachable from REVS or from a published
# remote-tracking ref.
cg_published() {
  local sha="$1"
  shift
  cg_published_revs
  [ "$#" -gt 0 ] || [ "${#cg_pub_revs[@]}" -gt 0 ] || return 1
  cg_reachable "$sha" "$@" ${cg_pub_revs[@]+"${cg_pub_revs[@]}"}
}

# A live operation needs a well-formed `op' and the rebase that operation
# started. This checks what rebase-land's rebase_is_ours checks: the marker
# its sequence editor drops in `rebase-merge' holds the op's nonce, and git's
# orig-head, onto and head-name agree with the op. rebase-land runs only the
# merge backend, so `rebase-apply' never qualifies. Another rebase from the
# same tips onto the same base carries no marker and covers nothing.
cg_live_op() {
  local gd d mark head onto name
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cg_parse "$gd/claude-rebase-op/op" "nonce ref old onto upstream picks" || return 1
  [[ "$cg_f_nonce" =~ $cg_nonce_re ]] && cg_head_ref_ok "$cg_f_ref" &&
    cg_is_sha "$cg_f_old" && cg_is_sha "$cg_f_onto" &&
    cg_is_sha "$cg_f_upstream" && [[ "$cg_f_picks" =~ $cg_picks_re ]] || return 1
  d="$gd/rebase-merge"
  [ -d "$d" ] || return 1
  # Whole files, read as rebase_is_ours reads them, so a marker with more
  # after its first line does not match.
  mark="$(cat "$d/claude-rebase-land" 2>/dev/null)" || return 1
  head="$(cat "$d/orig-head" 2>/dev/null)" || return 1
  onto="$(cat "$d/onto" 2>/dev/null)" || return 1
  name="$(cat "$d/head-name" 2>/dev/null)" || return 1
  [ "$mark" = "$cg_f_nonce" ] && [ "$head" = "$cg_f_old" ] &&
    [ "$onto" = "$cg_f_onto" ] && [ "$name" = "detached HEAD" ] || return 1
  cg_op_nonce="$cg_f_nonce"
}

# cg_judge REF OLD NEW returns 0 when the update may go ahead. cg_why says
# why, either way.
#
# git sends an all-zero old value both for a new ref and for an update that
# did not name the value it expected, so a zero is looked up. The ref is
# still at its old value in `prepared'.
cg_judge() {
  local ref="$1" old="$2" new="$3" real
  if cg_is_sha "$old"; then
    real="$old"
  else
    real="$(cg_git rev-parse -q --verify "$ref" 2>/dev/null)" || real=none
  fi
  cg_find_records "$ref" "$real" "$new"
  if [ -n "$cg_matched" ]; then
    cg_why="a $cg_matched_kind record approves it"
    return 0
  fi
  # A detached HEAD is decided here, before the branch rules below. Without
  # a record or a live operation it may only move to content a branch or a
  # published remote-tracking ref already has, so `git checkout <sha>'
  # works, or back to an ancestor of where it is. A new commit made on it is
  # on no ref yet and is no ancestor, so neither rule passes one.
  if [ "$ref" = HEAD ]; then
    if cg_published "$new" --branches; then
      cg_why="a local branch or a published remote-tracking ref already has it"
      return 0
    fi
    if [ "$real" != none ] && cg_is_ancestor "$new" "$real"; then
      cg_why="it moves back to an ancestor"
      return 0
    fi
    if cg_live_op; then
      cg_why="rebase-land operation $cg_op_nonce is live"
      return 0
    fi
    cg_why="a new commit on a detached HEAD, outside a rebase-land operation and with no commit record"
    [ -z "$cg_near" ] || cg_why="$cg_why. A record names HEAD and this tip, but $cg_near"
    return 1
  fi
  if [ "$real" != none ] && cg_is_ancestor "$new" "$real"; then
    cg_why="it moves back to an ancestor"
    return 0
  fi
  if cg_published "$new"; then
    cg_why="a published remote-tracking ref already has it"
    return 0
  fi
  # Content already on a local branch passed this gate or came from David, so
  # moving or making a branch there brings in nothing new. `--branches' reads
  # every ref at its old value, so no update in this transaction can vouch for
  # another.
  if cg_reachable "$new" --branches; then
    cg_why="a local branch already has it"
    return 0
  fi
  cg_why="$ref would move to ${new:0:12}, and no commit or move record approves it"
  [ -z "$cg_near" ] || cg_why="$cg_why. A record names this branch and tip, but $cg_near"
  return 1
}

cg_is_ancestor() { cg_git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# --- Hooks -----------------------------------------------------------------

# reference-transaction. The first tests use no subprocess, so an update by
# anyone else, or of anything but a branch or a detached HEAD, costs nothing.
cg_reftxn() {
  local state="$1" buf="$2" old new ref real mode f l t dir
  local -a lines=()
  cg_is_claude || return 0
  case "$state" in prepared|committed|aborted) ;; *) return 0 ;; esac
  case "$buf" in *" refs/heads/"*|*" HEAD"$'\n'*|*" HEAD") ;; *) return 0 ;; esac
  while IFS=' ' read -r old new ref; do
    case "$ref" in refs/heads/*|HEAD) ;; *) continue ;; esac
    case "$new" in ref:*) continue ;; esac
    ! cg_is_zero "$new" || continue
    [ "$new" != "$old" ] || continue
    lines+=("$ref $old $new")
  done <<< "$buf"
  [ "${#lines[@]}" -gt 0 ] || return 0

  # The matches `prepared' kept are the ones to delete. An update that named
  # no old value cannot be matched again here, because the ref has moved.
  if [ "$state" != prepared ]; then
    dir="$(cg_records_dir)" || return 0
    for l in "${lines[@]}"; do
      read -r ref old new <<< "$l"
      t="$(cg_txn_file "$dir" "$ref" "$old" "$new")" || continue
      if [ -f "$t" ]; then
        if [ "$state" = committed ]; then
          while IFS= read -r f; do
            [ "${f%/*}" = "$dir" ] && [[ "${f##*/}" =~ $cg_nonce_re ]] || continue
            rm -f "$f"
          done < "$t"
        fi
        rm -f "$t"
      elif [ "$state" = committed ] && cg_is_sha "$old"; then
        cg_find_records "$ref" "$old" "$new"
        while IFS= read -r f; do
          [ -z "$f" ] || rm -f "$f"
        done <<< "$cg_matched"
      fi
    done
    return 0
  fi

  mode="$(cg_mode)"
  [ "$mode" != off ] || return 0
  cg_guarded || return 0
  for l in "${lines[@]}"; do
    read -r ref old new <<< "$l"
    if cg_judge "$ref" "$old" "$new"; then
      cg_log "$ref" "$new" pass "$cg_why"
      [ -z "$cg_matched" ] || cg_keep_matches "$ref" "$old" "$new"
      continue
    fi
    if [ "$mode" = warn ]; then
      cg_log "$ref" "$new" warn "$cg_why"
      cg_refusal warn "$cg_why"
      continue
    fi
    cg_log "$ref" "$new" refuse "$cg_why"
    cg_refusal enforce "$cg_why"
    return 1
  done
  return 0
}

# prepare-commit-msg: an early word before the editor opens. It is advice,
# because reference-transaction decides. It only looks at a commit on a
# branch outside a merge, a cherry-pick or a rebase, where the record must
# already name the branch, its tip and the staged tree.
cg_prepare_msg() {
  local mode gd x ref old tree dir f name
  cg_is_claude || return 0
  mode="$(cg_mode)"
  [ "$mode" != off ] || return 0
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  for x in MERGE_HEAD CHERRY_PICK_HEAD rebase-merge rebase-apply; do
    [ ! -e "$gd/$x" ] || return 0
  done
  ref="$(git symbolic-ref -q HEAD 2>/dev/null)" || return 0
  case "$ref" in refs/heads/?*) ;; *) return 0 ;; esac
  cg_guarded || return 0
  old="$(cg_git rev-parse -q --verify "$ref" 2>/dev/null)" || old=none
  tree="$(git write-tree 2>/dev/null)" || return 0
  dir="$gd/claude-approvals"
  cg_near=""
  for f in "$dir"/*; do
    name="${f##*/}"
    [[ "$name" =~ $cg_nonce_re ]] || continue
    cg_commit_record "$f" || continue
    [ "$cg_f_ref" = "$ref" ] && [ "$cg_f_old" = "$old" ] || continue
    if [ "$cg_f_tree" = "$tree" ]; then
      cg_log "$ref" - pass "prepare-commit-msg: a commit record names the staged tree"
      return 0
    fi
    cg_near="the staged tree is not the approved tree. A hook such as a pre-commit formatter may have staged changes after approval. Format the staged lines first, as the commit agent's step 3b does, then land again with commit-land.sh."
  done
  cg_why="no commit record approves this commit on $ref"
  [ -z "$cg_near" ] || cg_why="$cg_why. A record names this branch and tip, but $cg_near"
  if [ "$mode" = warn ]; then
    cg_log "$ref" - warn "prepare-commit-msg: $cg_why"
    cg_refusal warn "$cg_why"
    return 0
  fi
  cg_log "$ref" - refuse "prepare-commit-msg: $cg_why"
  cg_refusal enforce "$cg_why"
  return 1
}

# commit-msg. A commit record binds the message commit-land approved, so for
# a Claude caller in a guarded clone nothing may rewrite it on the way in. A
# silent rewrite would only surface later as a refusal that names no cause.
#
# commitgate_keep_msg BEFORE AFTER WHAT FIX returns 1 to refuse when the file
# AFTER and the text BEFORE differ once both are stripspaced, as the record's
# hash is. WHAT says what changed the message and FIX how to fix that.
commitgate_keep_msg() {
  local mode a b ref
  cg_is_claude || return 0
  a="$(printf '%s\n' "$1" | git stripspace | git hash-object --stdin 2>/dev/null)" || return 0
  b="$(git stripspace < "$2" | git hash-object --stdin 2>/dev/null)" || return 0
  [ "$a" != "$b" ] || return 0
  mode="$(cg_mode)"
  [ "$mode" != off ] || return 0
  cg_guarded || return 0
  ref="$(git symbolic-ref -q HEAD 2>/dev/null)" || ref=HEAD
  if [ "$mode" = warn ]; then
    cg_log "$ref" - warn "commit-msg: $3"
    cg_refusal warn "$3"
    cg_say "$4"
    return 0
  fi
  cg_log "$ref" - refuse "commit-msg: $3"
  cg_refusal enforce "$3"
  cg_say "$4"
  return 1
}

# pre-push: every commit a Claude push publishes must sit on a local branch,
# and every branch tip has passed reference-transaction. A detached commit
# that slipped by some other path stops here.
cg_pre_push() {
  local buf="$1" mode lref lsha rref
  cg_is_claude || return 0
  mode="$(cg_mode)"
  [ "$mode" != off ] || return 0
  cg_guarded || return 0
  while read -r lref lsha rref _; do
    [ -n "$lsha" ] || continue
    ! cg_is_zero "$lsha" || continue
    if cg_reachable "$lsha" --branches; then
      cg_log "$rref" "$lsha" pass "pre-push: on a local branch"
      continue
    fi
    cg_why="the push of $lref carries ${lsha:0:12}, and no local branch has it"
    if [ "$mode" = warn ]; then
      cg_log "$rref" "$lsha" warn "pre-push: $cg_why"
      cg_refusal warn "$cg_why" "git push"
      continue
    fi
    cg_log "$rref" "$lsha" refuse "pre-push: $cg_why"
    cg_refusal enforce "$cg_why" "git push"
    return 1
  done <<< "$buf"
  return 0
}

# post-checkout: pin this clone's hooks to the chain, so a later global
# config change cannot quietly drop the gate. Clone and `git worktree add'
# both run it. A path that is already set is left alone. Best effort, and it
# never fails the checkout.
cg_post_checkout() {
  local dir want cur
  dir="$(cd "${0%/*}" 2>/dev/null && pwd)" || return 0
  case "$dir" in "$HOME"/?*) ;; *) return 0 ;; esac
  want="~/${dir#"$HOME"/}"
  cur="$(git config --local --get core.hooksPath 2>/dev/null || true)"
  [ -z "$cur" ] || return 0
  [ "$(cg_mode)" != off ] || return 0
  cg_guarded || return 0
  git config --local core.hooksPath "$want" 2>/dev/null ||
    cg_say "could not set core.hooksPath in this clone, so the gate relies on the global one."
  return 0
}

# commitgate_dispatch HOOK STDIN ARGS. STDIN is what `_chain' buffered for
# the hooks that read it.
commitgate_dispatch() {
  local hook="$1" buf="$2"
  shift 2
  case "$hook" in
    reference-transaction) cg_reftxn "${1:-}" "$buf" ;;
    prepare-commit-msg) cg_prepare_msg "$@" ;;
    pre-push) cg_pre_push "$buf" ;;
    post-checkout) cg_post_checkout || true ;;
    commit-msg)
      commitgate_keep_msg "$buf" "$1" \
        "the repo-local commit-msg hook changed the approved message" \
        "The approved message must be the one that commits. Make that hook leave it alone, then run commit-land again."
      ;;
  esac
}

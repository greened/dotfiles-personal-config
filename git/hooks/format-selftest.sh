#!/usr/bin/env bash
# Self-test for the pre-commit staged-line formatter in _chain (policy 3b).
#
# Hermetic: every case runs in a throwaway repo under $TMPDIR with
# GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM pointed at /dev/null, so the machine's
# own gitconfig, identity and hooksPath cannot reach it.  core.hooksPath is then
# set to the hook directory under test.  Nothing here touches a real repo.
#
# The case that matters is PARTIAL STAGING.  A formatter that ran
# `clang-format -i' and then `git add' would sweep a file's unstaged hunks into
# the commit, and that is silent data loss in the commit the human is about to
# gate.  Case 2 asserts it cannot happen.
#
# Needs a real clang-format.  Pass one, or set CLANG_FORMAT:
#   ./format-selftest.sh /path/to/clang-format
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
CF="${1:-${CLANG_FORMAT:-}}"
if [ -z "$CF" ] || [ ! -x "$CF" ]; then
  echo "usage: $0 /path/to/clang-format   (or set CLANG_FORMAT)" >&2
  echo "a real binary is required: the point is what a formatter does to a diff." >&2
  exit 2
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# A repo shaped like the clone this policy applies to: it must contain
# git-clang-format, since the hook uses that file's presence as the test for
# "is this the kind of tree we format".
newrepo() {
  local d
  d="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  git -C "$d" init -q
  git -C "$d" config core.hooksPath "$HOOKS"
  # The identity policy (3a) rewrites and refuses on a mismatch, so satisfy it
  # up front.  This is the personal realm: no work origin, /tmp path.
  git -C "$d" config user.name  "David Greene"
  git -C "$d" config user.email "dag@obbligato.org"
  # An EMPTY marker is enough, and that is deliberate.  The hook reads this
  # path only to answer "is this the kind of tree the policy covers"; the
  # formatting is done by clang-format itself.  So the test needs no copy of
  # the real tool, and therefore names no path inside a real clone -- which
  # this published repo could not carry anyway.
  mkdir -p "$d/clang/tools/clang-format"
  : > "$d/clang/tools/clang-format/git-clang-format"
  printf '%s' "$d"
}

# Badly formatted but valid C++.  Two statements on one line and stray spacing,
# which any clang-format style will rewrite.
ugly() { printf 'int  f( int a ,int b ){ return a+b ; }\n'; }
tidy_probe() { printf 'int g(int a) { return a; }\n'; }

# ---------------------------------------------------------------- case 1
# A fully staged file is formatted, in the commit AND on disk.
d="$(newrepo)"
( cd "$d" && git commit -q --allow-empty -m base ) >/dev/null 2>&1
ugly > "$d/a.cpp"
git -C "$d" add a.cpp
git -C "$d" -c format.clangFormatBin="$CF" commit -q -m one >/dev/null 2>&1
committed="$(git -C "$d" show HEAD:a.cpp 2>/dev/null)"
if [ "$committed" != "$(ugly)" ] && [ -n "$committed" ]; then
  ok "1 staged file is reformatted in the commit"
else
  bad "1 staged file is reformatted in the commit" "committed: $committed"
fi
if [ "$(cat "$d/a.cpp")" = "$committed" ]; then
  ok "1 worktree matches the commit"
else
  bad "1 worktree matches the commit" "disk differs from HEAD"
fi
rm -rf "$d"

# ---------------------------------------------------------------- case 2
# PARTIAL STAGING.  Stage an ugly line, then add a SECOND line unstaged.  The
# commit must contain the formatted first line and must NOT contain the second.
d="$(newrepo)"
( cd "$d" && git commit -q --allow-empty -m base ) >/dev/null 2>&1
ugly > "$d/b.cpp"
git -C "$d" add b.cpp
{ ugly; printf 'int UNSTAGED_MARKER(void){return 0;}\n'; } > "$d/b.cpp"
git -C "$d" -c format.clangFormatBin="$CF" commit -q -m two >/dev/null 2>&1
committed="$(git -C "$d" show HEAD:b.cpp 2>/dev/null)"
if printf '%s' "$committed" | grep -q UNSTAGED_MARKER; then
  bad "2 unstaged hunk stays OUT of the commit" "the unstaged line was swept in"
else
  ok "2 unstaged hunk stays OUT of the commit"
fi
if [ -n "$committed" ] && [ "$committed" != "$(ugly)" ]; then
  ok "2 the staged line was still formatted"
else
  bad "2 the staged line was still formatted" "committed: $committed"
fi
if grep -q UNSTAGED_MARKER "$d/b.cpp"; then
  ok "2 the unstaged work survives on disk"
else
  bad "2 the unstaged work survives on disk" "the formatter destroyed unstaged work"
fi
rm -rf "$d"

# ---------------------------------------------------------------- case 3
# A config that names a MISSING binary is loud, and does not block the commit.
d="$(newrepo)"
( cd "$d" && git commit -q --allow-empty -m base ) >/dev/null 2>&1
ugly > "$d/c.cpp"
git -C "$d" add c.cpp
err="$(git -C "$d" -c format.clangFormatBin=/nonexistent/clang-format commit -m three 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "3 a missing binary does not block the commit"
else bad "3 a missing binary does not block the commit" "rc=$rc"; fi
if printf '%s' "$err" | grep -q "not executable"; then
  ok "3 a missing binary is announced"
else
  bad "3 a missing binary is announced" "no warning in: $err"
fi
if [ "$(git -C "$d" show HEAD:c.cpp)" = "$(ugly)" ]; then
  ok "3 the unformatted text lands unchanged"
else
  bad "3 the unformatted text lands unchanged"
fi
rm -rf "$d"

# ---------------------------------------------------------------- case 4
# No config and no TOOLCHAIN: silent.  This is a personal machine, or any repo
# that is not one of these clones, and a message on every commit would train
# you to ignore the one place this hook speaks.
d="$(newrepo)"
( cd "$d" && git commit -q --allow-empty -m base ) >/dev/null 2>&1
ugly > "$d/d.cpp"
git -C "$d" add d.cpp
err="$(env -u TOOLCHAIN git -C "$d" commit -m four 2>&1)"
if printf '%s' "$err" | grep -q '^format:'; then
  bad "4 no toolchain is silent" "it spoke: $err"
else
  ok "4 no toolchain is silent"
fi
rm -rf "$d"

# ---------------------------------------------------------------- case 5
# A tree with no git-clang-format is left alone even WITH a good binary: the
# policy is scoped to clones that carry it.
d="$(mktemp -d)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git -C "$d" init -q
git -C "$d" config core.hooksPath "$HOOKS"
git -C "$d" config user.name "David Greene"
git -C "$d" config user.email "dag@obbligato.org"
( cd "$d" && git commit -q --allow-empty -m base ) >/dev/null 2>&1
ugly > "$d/e.cpp"
git -C "$d" add e.cpp
git -C "$d" -c format.clangFormatBin="$CF" commit -q -m five >/dev/null 2>&1
if [ "$(git -C "$d" show HEAD:e.cpp)" = "$(ugly)" ]; then
  ok "5 a tree without git-clang-format is untouched"
else
  bad "5 a tree without git-clang-format is untouched"
fi
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

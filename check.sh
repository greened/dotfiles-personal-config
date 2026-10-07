#!/usr/bin/env bash
# Build and test this overlay, with the same interface as the dotfiles check.sh:
#
#     ./check.sh          # build, then test
#     ./check.sh build    # nothing to build, and it says so
#     ./check.sh test     # run the selftests and the elisp tests
#
# Tests are found by name, so a new one runs without an edit here: every
# git/hooks/*-selftest.sh, and every emacs/tests/*-tests.el. Finding no tests at
# all is a failure, so an empty run cannot read as green.
#
# The format selftest needs a real clang-format: $CLANG_FORMAT, else the one on
# PATH. With neither it is skipped, and the summary counts the skip.
#
# $EMACS overrides the binary. On the dev VM the packaged Emacs needs a hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"
what="${1:-all}"

do_build() {
  echo "== build: nothing to build in the personal-config overlay"
}

do_test() {
  local t ran=0 skipped=0
  local cf="${CLANG_FORMAT:-$(command -v clang-format || true)}"
  # A backstop for any selftest that forgets to keep the real git config out.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  for t in "$here"/git/hooks/*-selftest.sh; do
    [ -e "$t" ] || continue
    echo "== test: $(basename "$t")"
    if [ "$(basename "$t")" = format-selftest.sh ]; then
      if [ -z "$cf" ]; then
        echo "SKIP: no clang-format, so set CLANG_FORMAT to run it"
        skipped=$((skipped + 1))
        echo
        continue
      fi
      "$t" "$cf"
    else
      "$t"
    fi
    ran=$((ran + 1))
    echo
  done
  for t in "$here"/emacs/tests/*-tests.el; do
    [ -e "$t" ] || continue
    echo "== test: $(basename "$t")"
    "$emacs" -Q --batch -l "$t" -f ert-run-tests-batch-and-exit
    ran=$((ran + 1))
    echo
  done
  if [ "$ran" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
      echo "check: all tests skipped ($skipped), so nothing ran" >&2
    else
      echo "check: no tests found under $here" >&2
    fi
    exit 1
  fi
  echo "== $ran test files passed, $skipped skipped"
}

case "$what" in
  build) do_build ;;
  test)  do_test ;;
  all)   do_build; echo; do_test ;;
  *) echo "usage: $(basename "$0") [build|test]" >&2; exit 2 ;;
esac

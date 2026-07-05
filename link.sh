#!/usr/bin/env bash
# personal-config overlay: install the personal git entry point.  Run by the base
# link.sh, which exports $DOTFILES_LINK_LIB and $GCLOCAL.
set -eu
. "${DOTFILES_LINK_LIB:?run via the base link.sh}"
OV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link "$OV/git/gitconfig" "$HOME/.gitconfig"

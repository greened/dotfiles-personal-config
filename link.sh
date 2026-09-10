#!/usr/bin/env bash
# personal-config overlay: install the personal git entry point.  Run by the base
# link.sh, which exports $DOTFILES_LINK_LIB and $GCOVERLAYS.
set -eu
. "${DOTFILES_LINK_LIB:?run via the base link.sh}"
OV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link "$OV/git/gitconfig" "$HOME/.gitconfig"

# Keep the hook chain's three config files private, on EVERY machine.
#
# The chain deployed above (via `core.hooksPath') reads the term list, the realm
# signals and the exempt list from ~/.config.  They are 600 on purpose: the
# exempt list in particular says which repos are the employer-shaped ones.
#
# Git records only the executable bit, so 600 does not travel in a commit.  The
# work overlay chmods its own copies, but that overlay is deliberately NOT in
# the Mac's `.order', so nothing there ever restored the mode: a pull that
# CHANGED one of these files had git recreate it under the umask, at 644, while
# its untouched siblings stayed 600.  Seen exactly that way on 2026-09-09.
#
# Here rather than in the work overlay because this overlay runs on both
# machines, and because it is the consumer: these files are read by the hooks
# this script installs.  `chmod' follows a symlink, so chmodding the deployed
# path fixes the file wherever it actually lives, without this public repo
# knowing which overlay provides it.
#
# Absent is the normal state on a machine with no work overlay, so say nothing
# then.  A missing file is the hook chain's business to report, not this
# script's.
# Guarded with `if', not `[ -e ] && chmod'.  Under `set -e' a loop whose LAST
# iteration ends in a false test exits non-zero and aborts this script -- on the
# machine with no work overlay, which is the case this is meant to pass over in
# silence.  The work overlay's own chmod loop is written the same way for the
# same reason.
for f in git-scrub-terms git-realm-work git-scrub-exempt; do
  if [ -e "$HOME/.config/$f" ]; then chmod 600 "$HOME/.config/$f"; fi
done

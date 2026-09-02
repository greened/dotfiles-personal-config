#!/usr/bin/env bash
# Audit the scrub's term list.  Run it after editing the list:
#
#     git/hooks/scrub-audit.sh            # report to stdout
#     git/hooks/scrub-audit.sh -o FILE    # ...to a file, mode 600
#
# Why a script and not a saved report: a report goes stale the moment a term
# changes, and it contains the terms, so it wants the same care as the list
# itself.  Regenerating is cheap.
#
# This file holds no terms -- it reads them at runtime -- so it is safe in a
# repo-visible location beside the rules it audits.  Its OUTPUT is not: it
# quotes the terms, so send it somewhere private.
#
# What it checks, in the order the faults were found the hard way:
#
#   inert       A term is handed to grep as a pattern.  Escaped, it means
#               itself; unescaped, a term containing a metacharacter meant
#               something else, and four of twenty-three matched nothing they
#               were written to catch -- silently.  A term that cannot match
#               its own text is inert.
#   regex-      Terms are literal text.  A term still carrying `\', `(', `|'
#   syntax      or a quantifier was written under the older rules, where the
#               list was a pattern, and now means something other than itself.
#   over-broad  Terms are matched case-insensitively.  Without a word boundary
#               a short term fires inside ordinary words; one five-letter term
#               collides with fifteen dictionary words.  A check that refuses
#               innocent prose is a check people bypass.
#   live        A term appearing in a repo you can publish is the leak the
#               whole apparatus exists to prevent.  Nothing else here matters
#               if this is non-zero.
#   unused      A term matching nothing anywhere is either prophylaxis, which
#               is legitimate, or a leftover from work that is over.  Only you
#               can tell, but a list is easier to trust when it is current.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/scrub-rules.sh"

out=""
[ "${1:-}" = "-o" ] && { out="${2:?-o needs a file}"; }

terms_file="$(git config --get scrub.termsFile 2>/dev/null || true)"
[ -n "$terms_file" ] || terms_file="$HOME/.config/git-scrub-terms"
[ -r "$terms_file" ] || { echo "no term list at $terms_file" >&2; exit 1; }

# Repos to weigh a term against.  Publishable ones first: a hit there is the
# finding that matters.  Missing paths are skipped, and either list can be
# replaced from the environment.
#
# Only the publishable repos are NAMED.  The private ones are whatever is left
# in the overlays directory, because writing their names here would put the
# employer's own overlay name in a public file -- which is what this script
# reports on, and it did exactly that until this audit was pointed at itself.
PUBLIC="${SCRUB_AUDIT_PUBLIC:-$HOME/lib/dotfiles $HOME/lib/dotfiles-overlays/personal-config}"
if [ -n "${SCRUB_AUDIT_PRIVATE:-}" ]; then
  PRIVATE="$SCRUB_AUDIT_PRIVATE"
else
  PRIVATE=''
  for d in "$HOME"/lib/dotfiles-overlays/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    for p in $PUBLIC; do [ "$d" = "$p" ] && continue 2; done
    PRIVATE="$PRIVATE $d"
  done
fi
dict=/usr/share/dict/words

report() {
  printf '%-4s %-30s %-5s %-9s %-8s %-11s %s\n' \
         '#' 'term' 'len' 'inPublic' 'private' 'dictWords' 'flags'
  i=0
  while IFS= read -r raw; do
    t="${raw%%#*}"; t="$(printf '%s' "$t" | sed 's/[[:space:]]*$//')"
    [ -z "$t" ] && continue
    i=$((i + 1))

    # One-term regex, built by the SAME function the hook uses.
    one="$(printf '%s\n' "$t" | scrub_term_re /dev/stdin)"

    # A term that matches nothing is the interesting case, and grep exits 1 to
    # say so, which under `pipefail' would abort the audit at the first such
    # term -- reporting a clean-looking header and no rows at all.
    pub=0
    for r in $PUBLIC; do
      [ -d "$r" ] || continue
      pub=$((pub + $({ grep -rhoiE -- "$one" "$r" --exclude-dir=.git 2>/dev/null || true; } | wc -l)))
    done
    priv=0
    for r in $PRIVATE; do
      [ -d "$r" ] || continue
      priv=$((priv + $({ grep -rhoiE -- "$one" "$r" --exclude-dir=.git 2>/dev/null || true; } | wc -l)))
    done

    dw=0
    if [ -r "$dict" ]; then
      dw=$(grep -icE -- "$one" "$dict" 2>/dev/null || true); dw=${dw:-0}
    fi

    flags=''
    # Inert: does the term match its own text, padded so boundaries apply?
    #
    # The probe is the term as it would appear in a FILE, so it drops the same
    # legacy `\b' anchors the builder drops.  Probing the raw spelling instead
    # is how five dead terms audited clean: the pattern they had decayed into
    # still matched the line they sat on in the list.
    probe="$(printf '%s' "$t" | sed -e 's/^\\b//' -e 's/\\b$//')"
    printf 'x %s y\n' "$probe" | grep -qiE -- "$one" || flags="$flags INERT"
    # Terms are literal text.  Anything left that grep would read as syntax is
    # a term written under the old pattern rules, and means something else.
    case "$probe" in
      *\\*|*'['*|*']'*|*'('*|*')'*|*'|'*|*'*'*|*'+'*|*'?'*|*'^'*|*'$'*|*'{'*|*'}'*)
        flags="$flags REGEX-SYNTAX" ;;
    esac
    [ "$pub" -gt 0 ]  && flags="$flags LIVE-IN-PUBLIC"
    [ "$dw" -gt 0 ]   && flags="$flags OVER-BROAD"
    [ "$priv" -eq 0 ] && [ "$pub" -eq 0 ] && flags="$flags UNUSED"

    printf '%-4s %-30s %-5s %-9s %-8s %-11s %s\n' \
           "$i" "$t" "${#t}" "$pub" "$priv" "$dw" "${flags:- -}"
  done < "$terms_file"
}

if [ -n "$out" ]; then
  umask 077
  report > "$out"
  echo "written to $out (mode 600 -- it quotes the terms)"
else
  report
fi

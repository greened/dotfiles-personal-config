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
#   prose-      A term that matches text in a repo the scrub GUARDS will refuse
#   collision   an innocent commit there, and a check that cries wolf is one you
#               learn to bypass.  Measured against your own repos, because that
#               is where the cost lands.
#
#               This replaces a dictionary test, which flagged six terms and was
#               wrong about all six.  `/usr/share/dict/words' here is
#               linux.words: 479826 entries, 80011 of them capitalised, carrying
#               proper nouns, hyphenated compounds, and foreign place names with
#               their accented letters stripped to ASCII.  One term's only two
#               "collisions" were a German city and a German football club,
#               mangled that way -- neither a word anyone would type.  Matching
#               that list says nothing about prose you would write.  The
#               dictionary hit is still shown as a HINT, with the matched words
#               named so it can be judged rather than counted, but it no longer
#               raises a flag.
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

# Repos the scrub GUARDS -- every personal repo a false positive would block a
# commit in, which is the publishable ones plus the personal checkouts.  This is
# what `prose-collision' is measured against.
if [ -n "${SCRUB_AUDIT_PROSE:-}" ]; then
  PROSE="$SCRUB_AUDIT_PROSE"
else
  PROSE="$PUBLIC"
  for d in "$HOME"/projects/*/; do
    d="${d%/}"
    [ -d "$d/.git" ] || continue
    # Your OWN repos only, decided by the remote's owner.  ~/projects also
    # holds upstream forks -- LLVM trees and the like -- which are someone
    # else's text, enormous enough to turn this audit into a coffee break, and
    # not somewhere your commits get refused anyway.
    case "$(git -C "$d" config --get remote.origin.url 2>/dev/null || true)" in
      *greened/*) PROSE="$PROSE $d" ;;
    esac
  done
fi

# scan REGEX REPO... -- every matched substring across those repos, one a line.
#
# One recursive pass per repo SET, not one per term: two dozen terms across a
# dozen checkouts is minutes of grep for data a single pass yields, and the
# per-term counts below come out of these lists instead.  Terms are literal, so
# a matched substring IS the term that matched it.
#
# COMMITTED content, via `git grep HEAD' -- not the working tree.  Two reasons,
# and the first cost an afternoon:
#
#   * The working tree is not stable.  These checkouts are worked in by other
#     sessions, and they sit on NFS, which on deleting a file another process
#     still holds open leaves a `.nfsXXXX' handle file containing the deleted
#     CONTENT.  A recursive grep reads those as ordinary files, so a scan picks
#     up whatever someone else had open, and picks it up in one run and not the
#     next.  This audit reported 422 hits in a personal repo that had none, then
#     zero for the same repo minutes later.  An unstable number is worse than a
#     wrong one: it invents leaks, and then hides them.
#   * Committed content is also the right question.  A leak is what the repo
#     CARRIES; scratch lying in a working tree is not published, and the
#     pre-commit hook is what stands between it and a commit.
#
# A path that is not a git repo falls back to a plain recursive grep, with the
# transient names excluded.
scan() {
  local re="$1"; shift
  local r
  for r in "$@"; do
    [ -d "$r" ] || continue
    if git -C "$r" rev-parse --verify HEAD >/dev/null 2>&1; then
      git -C "$r" grep -h -o -i -E -e "$re" HEAD -- . 2>/dev/null || true
    else
      grep -rhoiE -- "$re" "$r" --exclude-dir=.git \
           --exclude='.nfs*' --exclude='.#*' --exclude='#*#' --exclude='*~' \
           2>/dev/null || true
    fi
  done
}

report() {
  local full pub_hits priv_hits prose_hits r
  full="$(scrub_term_re "$terms_file")"
  # Name the inputs.  A count with no stated scope cannot be checked, and two
  # rounds of chasing a wrong number here came down to not knowing which trees
  # had been searched.
  printf 'terms:   %s (%s terms)\n' "$terms_file" \
         "$(grep -c '^[^#]' "$terms_file" 2>/dev/null || echo '?')"
  for r in $PUBLIC;  do printf 'public:  %s\n' "$r"; done
  for r in $PRIVATE; do printf 'private: %s\n' "$r"; done
  for r in $PROSE;   do printf 'prose:   %s\n' "$r"; done
  printf '\n'
  pub_hits="$(scan "$full" $PUBLIC)"
  priv_hits="$(scan "$full" $PRIVATE)"
  prose_hits="$(scan "$full" $PROSE)"
  printf '%-4s %-30s %-5s %-9s %-8s %-7s %-11s %s\n' \
         '#' 'term' 'len' 'inPublic' 'private' 'myProse' 'dictHint' 'flags'
  i=0
  while IFS= read -r raw; do
    t="${raw%%#*}"; t="$(printf '%s' "$t" | sed 's/[[:space:]]*$//')"
    [ -z "$t" ] && continue
    i=$((i + 1))

    # One-term regex, built by the SAME function the hook uses.
    one="$(printf '%s\n' "$t" | scrub_term_re /dev/stdin)"

    # Counted out of the pre-scanned match lists, by WHOLE-LINE literal
    # equality.  Each line of those lists is one matched substring, which for a
    # bounded literal term is the term itself, so equality is exact.
    #
    # Matching the term's REGEX against those lines instead is wrong, and wrong
    # in the direction that invents findings: terms overlap, so a substring
    # matched on account of one term can contain another as a word -- a domain
    # or a path prefix containing the bare company name, say -- and every such
    # line got credited to both. That read as 177 hits for a term with none,
    # and sent one triage after six terms that cost nothing.
    #
    # A term that matches nothing is the interesting case, and grep exits 1 to
    # say so, which under `pipefail' would abort the audit at the first such
    # term -- reporting a clean-looking header and no rows at all.
    pub=$({ printf '%s\n' "$pub_hits" | grep -icxF -- "$t" || true; })
    priv=$({ printf '%s\n' "$priv_hits" | grep -icxF -- "$t" || true; })
    # Where a false positive would actually cost something.
    prose=$({ printf '%s\n' "$prose_hits" | grep -icxF -- "$t" || true; })

    # A HINT only, and the matched words are named rather than counted, because
    # a bare count sent one triage after six terms that turned out to cost
    # nothing.  See the note at the top of this file.
    dw='-'
    if [ -r "$dict" ]; then
      dw="$({ grep -iE -- "$one" "$dict" 2>/dev/null || true; } | head -3 | tr '\n' ',')"
      dw="${dw%,}"; dw="${dw:--}"
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
    [ "$pub" -gt 0 ]   && flags="$flags LIVE-IN-PUBLIC"
    # Flagged on real cost, not on the dictionary.  A term matching your own
    # prose refuses an innocent commit; a term matching linux.words may well
    # refuse nothing at all.
    [ "$prose" -gt 0 ] && flags="$flags PROSE-COLLISION"
    [ "$priv" -eq 0 ] && [ "$pub" -eq 0 ] && flags="$flags UNUSED"

    printf '%-4s %-30s %-5s %-9s %-8s %-7s %-11s %s\n' \
           "$i" "$t" "${#t}" "$pub" "$priv" "$prose" "$dw" "${flags:- -}"
  done < "$terms_file"
}

if [ -n "$out" ]; then
  umask 077
  report > "$out"
  echo "written to $out (mode 600 -- it quotes the terms)"
else
  report
fi

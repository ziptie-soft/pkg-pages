#!/bin/sh
# Download the .deb/.rpm assets of the latest published GitHub releases, so that the rebuilt site
# keeps earlier versions installable (Pages replaces the whole site on every deploy). Replaces
# the "Fetch earlier releases' packages" step of the source projects.
#
# Usage:
#   fetch-history.sh --dir DIR [--keep N] [--patterns "GLOB..."] [--exclude-tag TAG]
#                    [--include-prereleases true|false] [--repository OWNER/REPO]
#
#   --dir                  directory to download into (created). Existing files are kept: an asset
#                          identical to a file of the same name is skipped, and one that differs
#                          is stored as TAG_NAME (characters of TAG other than A-Za-z0-9._-
#                          become _)
#   --keep                 how many releases to fetch, newest first, not counting --exclude-tag
#                          (default 9; 0 fetches nothing)
#   --patterns             newline- or space-separated asset globs (default "*.deb *.rpm")
#   --exclude-tag          the current release's tag: its packages come from the current run
#   --include-prereleases  also fetch pre-releases (default false). Drafts are never fetched.
#   --repository           whose releases (default $GITHUB_REPOSITORY)
#
# Needs gh, authenticated through GH_TOKEN (contents: read). A release without matching assets
# is skipped with a notice; any other failure (network, permissions) is an error, because a
# silently shorter history would drop versions from the published repositories.
#
# Output (GITHUB_OUTPUT): tags=<space-separated tags whose assets were fetched>.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"

usage() { die "usage: $0 --dir DIR [--keep N] [--patterns \"GLOB...\"] [--exclude-tag TAG] [--include-prereleases true|false] [--repository OWNER/REPO]"; }

dir='' keep=9 patterns='*.deb *.rpm' exclude='' pre=false repo="${GITHUB_REPOSITORY:-}"
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --dir) dir="$2" ;;
        --keep) keep="$2" ;;
        --patterns) patterns="$2" ;;
        --exclude-tag) exclude="$2" ;;
        --include-prereleases) pre="$2" ;;
        --repository) repo="$2" ;;
        *) usage ;;
    esac
    shift 2
done

[ -n "$dir" ] || usage
# The patterns are globs for asset names, never for files here: no pathname expansion at all.
set -f
case "$keep" in '' | *[!0-9]*) die "keep must be a whole number, not '$keep'" ;; esac
[ "$keep" -le 100 ] || die "keep must be at most 100, not $keep"
check_bool include-prereleases "$pre"
printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
    die "repository must be owner/repo, not '$repo'"
# No '/' in a pattern: gh matches asset names, and the glob is also used with `case` below.
for p in $patterns; do
    case "$p" in */*) die "patterns must match asset names, without '/': '$p'" ;; esac
done

mkdir -p "$dir"
fetched=
if [ "$keep" -gt 0 ]; then
    require_tools gh cmp
    work='' && make_tmpdir work
    # store STAGE TAG: move the assets downloaded into STAGE to DIR. A name already taken in DIR by
    # the same bytes is skipped; by other bytes (another release's asset of that name, or a file
    # already there), the asset is stored as <tag>_<name>, so no version is silently dropped.
    store() {
        _safe="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
        (cd "$1" && find . -type f) > "$work/names"
        while IFS= read -r _n; do
            _n="${_n#./}"
            _src="$1/$_n" _dst="$dir/$_n"
            if [ -e "$_dst" ] || [ -L "$_dst" ]; then
                if cmp -s "$_src" "$_dst"; then rm -f "$_src"; continue; fi
                _alt="$dir/${_safe}_$_n"
                if [ -e "$_alt" ] || [ -L "$_alt" ]; then
                    if cmp -s "$_src" "$_alt"; then rm -f "$_src"; continue; fi
                    die "$_n of $2 differs from both $_dst and $_alt"
                fi
                log "$_n of $2 differs from $_dst, which is kept; stored as $_alt"
                _dst="$_alt"
            fi
            mv "$_src" "$_dst"
        done < "$work/names"
    }
    flags=--exclude-drafts
    [ "$pre" = true ] || flags="$flags --exclude-pre-releases"
    # One more than needed, in case the current release is among them.
    # shellcheck disable=SC2086 # flags is a list of options
    tags="$(gh release list --repo "$repo" --limit "$((keep + 1))" $flags \
        --json tagName --jq '.[].tagName')" || die "gh release list failed for $repo"
    n=0
    for tag in $tags; do
        [ "$n" -lt "$keep" ] || break
        [ "$tag" != "$exclude" ] || continue
        n=$((n + 1))
        assets="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')" ||
            die "gh release view $tag failed"
        # Only the patterns that match something: gh release download fails on a pattern that
        # matches nothing, and that must not be confused with a real error.
        set --
        for p in $patterns; do
            for a in $assets; do
                # shellcheck disable=SC2254 # $p is a glob on purpose
                case "$a" in $p) set -- "$@" --pattern "$p"; break ;; esac
            done
        done
        if [ "$#" -eq 0 ]; then
            notice "release $tag has no assets matching: $patterns"
            continue
        fi
        stage="$work/$n"
        mkdir "$stage"
        gh release download "$tag" --repo "$repo" --dir "$stage" "$@" ||
            die "downloading the assets of $tag failed"
        store "$stage" "$tag"
        fetched="$fetched $tag"
        log "fetched $tag"
    done
fi
fetched="${fetched# }"
set_output tags "$fetched"
log "earlier releases fetched into $dir: ${fetched:-none}"

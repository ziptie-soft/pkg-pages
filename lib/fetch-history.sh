#!/bin/sh
# Download the .deb/.rpm assets of the latest published GitHub releases, so that the rebuilt site
# keeps earlier versions installable (Pages replaces the whole site on every deploy). Replaces
# the "Fetch earlier releases' packages" step of the source projects.
#
# Usage:
#   fetch-history.sh --dir DIR [--keep N] [--patterns "GLOB..."] [--exclude-tag TAG]
#                    [--include-prereleases true|false] [--repository OWNER/REPO]
#
#   --dir                  directory to download into (created; existing files are kept)
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
    require_tools gh
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
        gh release download "$tag" --repo "$repo" --dir "$dir" --skip-existing "$@" ||
            die "downloading the assets of $tag failed"
        fetched="$fetched $tag"
        log "fetched $tag"
    done
fi
fetched="${fetched# }"
set_output tags "$fetched"
log "earlier releases fetched into $dir: ${fetched:-none}"

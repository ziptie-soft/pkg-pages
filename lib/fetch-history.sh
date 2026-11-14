#!/bin/sh
# Fetch the .deb/.rpm packages of earlier releases, so that the rebuilt site keeps earlier
# versions installable (Pages replaces the whole site on every deploy). Replaces the "Fetch
# earlier releases' packages" step of the source projects.
#
# Usage:
#   fetch-history.sh --dir DIR [--keep N] [--patterns "GLOB..."] [--exclude-tag TAG]
#                    [--include-prereleases true|false] [--repository OWNER/REPO]
#                    [--tags "TAG..."] [--map FILE]
#                    [--from releases|site] [--url URL --name NAME [--public-key FILE]]
#
#   --dir                  directory to download into (created). In releases mode, existing files
#                          are kept: an asset identical to a file of the same name is skipped, and
#                          one that differs is stored as TAG_NAME (characters of TAG other than
#                          A-Za-z0-9._- become _)
#   --keep                 how many releases to fetch, newest first, not counting --exclude-tag
#                          (default 9; 0 fetches nothing, whatever --tags says)
#   --patterns             newline- or space-separated asset globs (default "*.deb *.rpm");
#                          releases mode only
#   --exclude-tag          the current release's tag: its packages come from the current run
#   --include-prereleases  also fetch pre-releases (default false). Drafts are never fetched.
#   --repository           whose releases (default $GITHUB_REPOSITORY)
#   --tags                 the releases to fetch, newest first, instead of the GitHub release list:
#                          --keep, --exclude-tag and --include-prereleases then don't apply, and
#                          gh isn't asked for the list. Site mode needs no gh and no repository then.
#   --map                  write the history map: one line per file kept in DIR,
#                          <tag><TAB><sha256><TAB><path relative to DIR><TAB>release|site
#                          (tag - for the site's keyring package). Without it, nothing changes.
#   --from                 where the files come from (default releases):
#                            releases  the assets of the GitHub releases, through gh
#                            site      the live site, checked against its manifest
#   --url                  site mode: the site's base URL (https://, or file:/// for tests)
#   --name                 site mode: the site's name, as in the manifest's header
#   --public-key           site mode: the pin. With it, the manifest must carry a valid signature
#                          of the pin's key (an expired subkey is accepted, a revoked one is not)
#                          and its header must name that key. Without a file there, the site must
#                          not be signed: its .asc would be an error.
#
# Releases mode needs gh, authenticated through GH_TOKEN (contents: read). A release without
# matching assets is skipped with a notice; any other failure (network, permissions) is an error,
# because a silently shorter history would drop versions from the published repositories.
#
# Site mode runs on the runner and needs curl, gpgv, gpg and sha256sum (and gh, unless --tags is
# given: the GitHub releases decide which releases are kept). It downloads <url>/pkg-pages.tsv and
# its .asc, verifies the manifest, checks every line of it (docs/design.md: names, SHA-256s and
# paths of the form the build writes), then copies the packages of the selected tags, and the
# newest <name>-keyring_*_all.deb, to DIR/<path>. Each SHA-256 is downloaded once and checked
# before it is copied; a file already at DIR/<path> must hold the same bytes. A selected tag that
# the manifest lacks is skipped with a notice. Nothing is selected, nothing is fetched. curl
# retries transient errors three times: the one exception to "nothing is retried".
#
# Output (GITHUB_OUTPUT): tags=<space-separated tags whose files were fetched>, and map=<FILE>
# when --map is given.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

usage() { die "usage: $0 --dir DIR [--keep N] [--patterns \"GLOB...\"] [--exclude-tag TAG] [--include-prereleases true|false] [--repository OWNER/REPO] [--tags \"TAG...\"] [--map FILE] [--from releases|site] [--url URL] [--name NAME] [--public-key FILE]"; }

dir='' keep=9 patterns='*.deb *.rpm' exclude='' pre=false repo="${GITHUB_REPOSITORY:-}"
from=releases url='' pin='' name='' want_tags='' map=''
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --dir) dir="$2" ;;
        --keep) keep="$2" ;;
        --patterns) patterns="$2" ;;
        --exclude-tag) exclude="$2" ;;
        --include-prereleases) pre="$2" ;;
        --repository) repo="$2" ;;
        --tags) want_tags="$2" ;;
        --map) map="$2" ;;
        --from) from="$2" ;;
        --url) url="$2" ;;
        --name) name="$2" ;;
        --public-key) pin="$2" ;;
        *) usage ;;
    esac
    shift 2
done

[ -n "$dir" ] || usage
# The patterns are globs for asset names, never for files here: no pathname expansion at all.
set -f
case "$from" in
    releases | site) ;;
    *) die "from must be 'releases' or 'site', not '$from'" ;;
esac
case "$keep" in '' | *[!0-9]*) die "keep must be a whole number, not '$keep'" ;; esac
[ "$keep" -le 100 ] || die "keep must be at most 100, not $keep"
check_bool include-prereleases "$pre"
# Only a run that asks gh for something needs the repository.
if [ "$from" = releases ] || [ -z "$want_tags" ]; then
    printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
        die "repository must be owner/repo, not '$repo'"
fi
# No '/' in a pattern: gh matches asset names, and the glob is also used with `case` below.
for p in $patterns; do
    case "$p" in */*) die "patterns must match asset names, without '/': '$p'" ;; esac
done
# --tags go to gh and to file names: no option-like, no odd tag, and none twice.
sel=
for t in $want_tags; do
    case "$t" in
        -* | *[!A-Za-z0-9._/+~-]*) die "tags must match [A-Za-z0-9._/+~][A-Za-z0-9._/+~-]*, not '$t'" ;;
    esac
    case " $sel " in *" $t "*) continue ;; esac
    sel="$sel $t"
done
want_tags="${sel# }"
if [ "$from" = site ]; then
    [ -n "$url" ] || die "--url is required with --from site"
    [ -n "$name" ] || die "--name is required with --from site"
    check_url url "$url"
    url="${url%/}"
    check_name name "$name"
fi

TAB="$(printf '\t')"
mkdir -p "$dir"
if [ -n "$map" ]; then
    mkdir -p "$(dirname "$map")"
    : > "$map"
fi
fetched=
if [ "$keep" -gt 0 ]; then
    if [ "$from" = site ]; then
        require_tools curl gpg gpgv sha256sum cmp awk
    else
        require_tools gh cmp
    fi
    [ -z "$map" ] || require_tools sha256sum
    work='' && make_tmpdir work

    # Which releases: the caller's list, or the newest --keep of GitHub's, without the current one.
    selected="$want_tags"
    if [ -z "$want_tags" ]; then
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
            selected="$selected $tag"
        done
        selected="${selected# }"
    fi

    if [ "$from" = releases ]; then
        : > "$work/maplines"
        # store STAGE TAG: move the assets downloaded into STAGE to DIR. A name already taken in DIR
        # by the same bytes is skipped; by other bytes (another release's asset of that name, or a
        # file already there), the asset is stored as <tag>_<name>, so no version is silently dropped.
        # With --map, each file kept, skipped ones included, is recorded under its path in DIR.
        store() {
            _safe="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
            (cd "$1" && find . -type f) > "$work/names"
            while IFS= read -r _n; do
                _n="${_n#./}"
                _src="$1/$_n" _dst="$dir/$_n" _rel="$_n" _sha=''
                [ -z "$map" ] || _sha="$(sha256sum "$_src" | cut -d' ' -f1)"
                if [ -e "$_dst" ] || [ -L "$_dst" ]; then
                    if cmp -s "$_src" "$_dst"; then
                        [ -z "$map" ] || printf '%s\t%s\t%s\trelease\n' "$2" "$_sha" "$_rel" >> "$work/maplines"
                        rm -f "$_src"
                        continue
                    fi
                    _alt="$dir/${_safe}_$_n"
                    _rel="${_safe}_$_n"
                    if [ -e "$_alt" ] || [ -L "$_alt" ]; then
                        if cmp -s "$_src" "$_alt"; then
                            [ -z "$map" ] || printf '%s\t%s\t%s\trelease\n' "$2" "$_sha" "$_rel" >> "$work/maplines"
                            rm -f "$_src"
                            continue
                        fi
                        die "$_n of $2 differs from both $_dst and $_alt"
                    fi
                    log "$_n of $2 differs from $_dst, which is kept; stored as $_alt"
                    _dst="$_alt"
                fi
                mv "$_src" "$_dst"
                [ -z "$map" ] || printf '%s\t%s\t%s\trelease\n' "$2" "$_sha" "$_rel" >> "$work/maplines"
            done < "$work/names"
            # One tag's lines together, by path.
            [ -z "$map" ] || LC_ALL=C sort -t "$TAB" -k3,3 "$work/maplines" >> "$map"
            : > "$work/maplines"
        }
        n=0
        for tag in $selected; do
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
    elif [ -n "$selected" ]; then
        # fetch_url URL OUT: download URL to OUT. 0: fetched. 1: not found (an HTTP 404, or a
        # missing file for file://). Anything else is an error.
        fetch_url() {
            _frc=0 _fcode=''
            _fcode="$(curl --fail --silent --show-error --location --proto '=https,file' --proto-redir '=https' \
                --max-redirs 5 --max-filesize 100M --retry 3 --write-out '%{http_code}' \
                --output "$2" "$1" 2> "$work/curl.err" < /dev/null)" || _frc=$?
            [ "$_frc" -ne 0 ] || return 0
            if [ "$_frc" -eq 37 ] || { [ "$_frc" -eq 22 ] && [ "$_fcode" = 404 ]; }; then
                rm -f "$2"
                return 1
            fi
            die "downloading $1 failed (curl exit $_frc, HTTP $_fcode): $(cat "$work/curl.err")"
        }
        pinned=false pinned_fpr=-
        if [ -n "$pin" ] && [ -f "$pin" ]; then
            pinned=true
            pinned_fpr="$(pin_fpr "$pin")"
        fi
        manifest="$work/pkg-pages.tsv"
        fetch_url "$url/pkg-pages.tsv" "$manifest" ||
            die "the site has no pkg-pages.tsv: run once with history-from: releases (docs/upgrading.md). Looked at $url/pkg-pages.tsv"
        have_asc=false
        fetch_url "$url/pkg-pages.tsv.asc" "$work/pkg-pages.tsv.asc" && have_asc=true
        if [ "$pinned" = true ] && [ "$have_asc" = false ]; then
            die "public-key $pin is committed, but the site has no pkg-pages.tsv.asc: its manifest is unsigned, so its packages can't be trusted. Bootstrap with history-from: releases (docs/upgrading.md)"
        fi
        if [ "$pinned" = false ] && [ "$have_asc" = true ]; then
            die "the manifest of $url is signed, but public-key '$pin' does not exist: commit the public key, or bootstrap with history-from: releases (docs/upgrading.md)"
        fi
        if [ "$pinned" = true ]; then
            # An expired subkey is accepted (expiry is not a compromise), a revoked one never.
            (gpg_verify --allow-expired "$pin" "$work/pkg-pages.tsv.asc" "$manifest") ||
                die "the manifest of $url does not verify against $pin. If the signing subkey was revoked, bootstrap with history-from: releases and resign-history: true, or keep-releases: 0 (docs/upgrading.md)"
        else
            notice "public-key '$pin' does not exist: the site's manifest ($url) is not verified"
        fi
        [ "$(tr -d '\000' < "$manifest" | wc -c)" -eq "$(wc -c < "$manifest")" ] ||
            die "the manifest of $url contains a NUL byte"

        # Every line, whether selected or not: the signature covers the whole file. Writes the
        # lines of kind, tag, sha and path (header removed) to manifest.ok.
        LC_ALL=C awk -F'\t' -v name="$name" -v fpr="$pinned_fpr" '
            function bad(m) { printf "manifest line %d: %s\n", NR, m > "/dev/stderr"; failed = 1; exit 1 }
            NR == 1 {
                if (NF != 4 || $1 != "#pkg-pages-manifest" || $2 != "1") bad("not a pkg-pages manifest of version 1")
                if ($3 != name) bad("the manifest is for \"" $3 "\", not \"" name "\"")
                if ($4 != fpr) bad("the manifest names the key \"" $4 "\", but the public key pins \"" fpr "\"")
                next
            }
            {
                if (NF != 4) bad("expected 4 tab-separated fields")
                if ($1 != "release" && $1 != "keyring") bad("unknown kind \"" $1 "\"")
                if (length($3) != 64 || $3 !~ /^[0-9a-f]+$/) bad("not a SHA-256: \"" $3 "\"")
                if ($1 == "release" && ($2 == "-" || $2 !~ /^[!-~]+$/)) bad("not a tag: \"" $2 "\"")
                if ($1 == "keyring" && $2 != "-") bad("a keyring line has the tag -")
                p = $4
                if (p !~ /^deb\/pool\/[A-Za-z0-9._+~\/-]+\.deb$/ && p !~ /^rpm\/[A-Za-z0-9_-]+\/[A-Za-z0-9._+~-]+\.rpm$/) bad("not a package path: \"" p "\"")
                if (("/" p "/") ~ /\/\.\.?\// || p ~ /\/\// || p ~ /\/\.(deb|rpm)$/) bad("not a package path: \"" p "\"")
                if ($1 == "keyring") {
                    b = p; sub(/.*\//, "", b)
                    pre = name "-keyring_"; rest = substr(b, length(pre) + 1)
                    if (index(b, pre) != 1 || length(rest) != 23 || substr(rest, 9, 1) != "." || rest !~ /^[0-9]+\.[0-9]+_all\.deb$/ || p !~ /^deb\//) bad("not a keyring package of " name ": \"" p "\"")
                }
                if (p in seen) bad("\"" p "\" is listed twice")
                seen[p] = 1
                print $1 "\t" $2 "\t" $3 "\t" $4
            }
            END { if (!failed && NR < 1) { print "the manifest is empty" > "/dev/stderr"; exit 1 } }
        ' "$manifest" > "$work/manifest.ok" 2> "$work/awk.err" ||
            die "the manifest of $url is not valid: $(cat "$work/awk.err")"

        # The selected tags, in order, and the newest keyring package last.
        : > "$work/take"
        for tag in $selected; do
            printf '%s\n' "$tag" > "$work/want"
            awk -F'\t' 'NR == FNR { w = $0; next } $1 == "release" && $2 == w' \
                "$work/want" "$work/manifest.ok" > "$work/lines"
            if [ ! -s "$work/lines" ]; then
                notice "release $tag has no packages in the manifest of $url"
                continue
            fi
            cat "$work/lines" >> "$work/take"
            fetched="$fetched $tag"
        done
        awk -F'\t' '$1 == "keyring" { b = $4; sub(/.*\//, "", b); print b "\t" $0 }' "$work/manifest.ok" |
            LC_ALL=C sort | tail -n 1 | cut -f2- >> "$work/take"

        mkdir -p "$work/blobs"
        dirroot="$(cd "$dir" && pwd -P)"
        while IFS="$TAB" read -r kind tag sha path; do
            blob="$work/blobs/$sha"
            if [ ! -f "$blob" ]; then
                fetch_url "$url/$path" "$blob.part" ||
                    die "$url/$path is in the manifest but the site does not have it"
                got="$(sha256sum "$blob.part" | cut -d' ' -f1)"
                [ "$got" = "$sha" ] || die "$path from $url has the SHA-256 $got, but the manifest says $sha"
                mv "$blob.part" "$blob"
            fi
            dst="$dir/$path"
            [ ! -L "$dst" ] || die "$dst is a symbolic link"
            if [ -e "$dst" ]; then
                cmp -s "$blob" "$dst" || die "$dst exists and differs from $path of $url"
            else
                mkdir -p "$(dirname "$dst")"
                case "$(cd "$(dirname "$dst")" && pwd -P)/" in
                    "$dirroot"/*) ;;
                    *) die "$path would be stored outside $dir" ;;
                esac
                cp "$blob" "$dst"
            fi
            [ -z "$map" ] || printf '%s\t%s\t%s\tsite\n' "$tag" "$sha" "$path" >> "$map"
            log "fetched $path ($kind $tag)"
        done < "$work/take"
    fi
fi
fetched="${fetched# }"
set_output tags "$fetched"
[ -z "$map" ] || set_output map "$map"
log "earlier releases fetched into $dir: ${fetched:-none}"

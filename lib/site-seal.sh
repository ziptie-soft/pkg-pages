#!/bin/sh
# Sign the metadata of a built site: the only step of a site build that holds the signing key. It
# reads a list of files to sign and writes only their signature files.
#
# Usage:
#   site-seal.sh --site DIR --to-sign FILE --public-key PIN [--import-key true|false]
#
#   --site DIR           the site site-build.sh built (unsigned metadata and all)
#   --to-sign FILE       one path relative to DIR per line; each must match exactly one of:
#                          deb/dists/<suite>/Release           -> InRelease and Release.gpg
#                          rpm/<arch>/repodata/repomd.xml      -> repomd.xml.asc
#                          pkg-pages.tsv                       -> pkg-pages.tsv.asc
#                        Anything else, a symbolic link (the file or any directory above it), a
#                        file that is not regular and a file over 16 MiB is an error; the whole
#                        list is checked before the first signature is made.
#   --public-key PIN     the pin; the signing key must be a subkey it lists, and every signature
#                        is verified against it (gpg_verify) after it is made
#   --import-key true|false  first import REPO_SIGNING_KEY into GNUPGHOME, failing closed against
#                        the pin, as `linux-signing.sh import` does (default false: a key already
#                        in GNUPGHOME signs; only an explicit GNUPGHOME counts)
#
# No pin and no key is the only unsigned run: a notice, nothing is signed. A pin that exists with
# no key, or a key without a pin, is an error (docs/signing.md).
#
# Tools: gpg and gpgv, wc, sort, uniq. The key is taken out of the environment first, so the tools
# this script runs never see it.
#
# Outputs (GITHUB_OUTPUT): signed=true|false, fingerprint; and PKG_PAGES_SIGNED,
# PKG_PAGES_FINGERPRINT in GITHUB_ENV. Progress goes to stderr.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"
signing_key="${REPO_SIGNING_KEY-}"
unset REPO_SIGNING_KEY

usage() {
    die "usage: $0 --site DIR --to-sign FILE --public-key PIN [--import-key true|false] (see the header of $0)"
}

site='' to_sign='' pin='' import_key=false
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --site) site="$2" ;;
        --to-sign) to_sign="$2" ;;
        --public-key) pin="$2" ;;
        --import-key) import_key="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$site" ] && [ -n "$to_sign" ] || usage
check_bool import-key "$import_key"
[ -d "$site" ] || die "site $site is not a directory"
[ -f "$to_sign" ] && [ ! -L "$to_sign" ] || die "to-sign $to_sign is not a regular file"
require_tools wc sort uniq

# --- The key ---------------------------------------------------------------------------------
# --import-key: the fail-closed import against the pin, in this process (signing.sh). Otherwise a
# key already in an explicit GNUPGHOME signs: on a developer's machine ~/.gnupg holds personal keys.
fpr=
if [ "$import_key" = true ]; then
    require_tools gpg
    [ -n "$pin" ] || die "--import-key needs --public-key"
    fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
elif [ -n "${GNUPGHOME:-}" ] && command -v gpg > /dev/null 2>&1; then
    fpr="$(secret_fpr)"
fi
signing_key=''

set_signed() {
    if [ -n "$fpr" ]; then
        set_output signed true
        set_output fingerprint "$fpr"
        set_env PKG_PAGES_SIGNED true
        set_env PKG_PAGES_FINGERPRINT "$fpr"
    else
        set_output signed false
        set_output fingerprint ''
        set_env PKG_PAGES_SIGNED false
    fi
}

if [ -z "$fpr" ]; then
    # Fail closed: a pin that exists means the site must be signed.
    [ -z "$pin" ] || [ ! -e "$pin" ] ||
        die "public-key $pin exists but there is no signing key: set signing-key, or the site would go out unsigned"
    notice "no signing key and no public-key: nothing is signed"
    set_signed
    exit 0
fi
require_tools gpg gpgv
[ -n "$pin" ] || die "gpg holds a signing key but no public-key was given"
[ "$(pin_fpr "$pin")" = "$fpr" ] || die "the signing key $fpr is not the key of public-key $pin"
[ -s "$to_sign" ] || die "to-sign $to_sign is empty, but a signing key is present"

# --- Check the whole list first --------------------------------------------------------------
work=''
make_tmpdir work
: > "$work/paths"
while IFS= read -r rel || [ -n "$rel" ]; do
    kind=
    if printf '%s\n' "$rel" | LC_ALL=C grep -Eq '^deb/dists/[A-Za-z0-9._-]+/Release$'; then
        kind=release
    elif printf '%s\n' "$rel" | LC_ALL=C grep -Eq '^rpm/[A-Za-z0-9_-]+/repodata/repomd\.xml$'; then
        kind=repomd
    elif [ "$rel" = pkg-pages.tsv ]; then
        kind=manifest
    fi
    [ -n "$kind" ] || die "to-sign: '$rel' is not a file this step signs (Release, repomd.xml or pkg-pages.tsv)"
    case "/$rel/" in */./* | */../*) die "to-sign: '$rel' has a . or .. segment" ;; esac
    # Neither the file nor a directory above it may be a link, or gpg would read or write elsewhere.
    acc=$rel
    while :; do
        [ ! -L "$site/$acc" ] || die "to-sign: $acc is a symbolic link"
        case "$acc" in */*) acc=${acc%/*} ;; *) break ;; esac
    done
    [ -f "$site/$rel" ] || die "to-sign: $rel is missing or is not a regular file"
    size="$(wc -c < "$site/$rel" | tr -d ' ')"
    [ "$size" -le 16777216 ] || die "to-sign: $rel is $size bytes; the limit is 16 MiB"
    printf '%s\n' "$rel" >> "$work/paths"
done < "$to_sign"
[ -z "$(LC_ALL=C sort "$work/paths" | LC_ALL=C uniq -d)" ] || die "to-sign lists a file twice"

# --- Sign ------------------------------------------------------------------------------------
gpg_sign() {
    gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$fpr" "$@"
}
# detach SIGNATURE DATA: a detached, armored signature, written to a fresh file (never through a
# link or into another file that shares the name).
detach() {
    rm -f "$1"
    gpg_sign --armor --detach-sign --output "$1" "$2"
    gpg_verify "$pin" "$1" "$2"
}
while IFS= read -r rel; do
    f="$site/$rel"
    case "$rel" in
        deb/dists/*/Release)
            rm -f "${f%Release}InRelease"
            gpg_sign --clearsign --output "${f%Release}InRelease" "$f"
            gpg_verify "$pin" "${f%Release}InRelease"
            detach "${f%Release}Release.gpg" "$f"
            ;;
        rpm/*/repodata/repomd.xml) detach "$f.asc" "$f" ;;
        pkg-pages.tsv) detach "$f.asc" "$f" ;;
    esac
    log "signed $rel"
done < "$work/paths"
set_signed

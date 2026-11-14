#!/bin/sh
# Check a built site the way a client will see it: the files exist, the release is listed, every
# signature verifies against the pin (not against whatever key did the signing), and the manifest,
# when there is one, agrees with the package files. Needs no secret.
#
# Usage:
#   site-check.sh --site DIR --name NAME --version VERSION [--suite S] [--component C]
#                 [--deb-architectures "A B"] [--public-key PIN]
#
#   --site DIR                the site, as pages-repo.sh or site-build.sh and site-seal.sh built it
#   --name NAME               the name of <name>.asc, deb/<name>.list and rpm/<name>.repo
#   --version VERSION         the release; each --deb-architectures Packages index must list it
#   --suite S, --component C  the APT layout (defaults stable and main)
#   --deb-architectures "A B" the Debian architectures that must list VERSION (all is skipped)
#   --public-key PIN          the pin. Given: the site must be signed; InRelease, Release.gpg,
#                             every repomd.xml.asc and pkg-pages.tsv.asc are checked with
#                             gpg_verify, and every .rpm with rpmkeys. <name>.asc must be the pin,
#                             byte for byte. rpm/RPM-GPG-KEY-<name> must be what pin_rpm_key
#                             makes of it (no revoked or expired subkey), the .repo must name it
#                             in gpgkey=, and every .rpm and repomd.xml.asc must verify against
#                             that file alone. Absent: the site must be unsigned and no
#                             signature is checked.
#
# Which parts exist is read from the site: deb/ when deb/<name>.list or deb/dists is there, rpm/
# likewise, nix/ when it holds a flake file. When pkg-pages.tsv exists it is checked as well: its
# header (the name, and the pin's primary fingerprint or - without a pin), every line's format,
# every listed file present with the listed SHA-256, and every .deb and .rpm of the site listed.
#
# Tools: gpg and gpgv with a pin; rpmkeys with a pin and .rpm files; gzip, tar, sed, awk, find,
# sha256sum, sort, comm. Fails with the first problem it finds.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

usage() {
    die "usage: $0 --site DIR --name NAME --version VERSION [--suite S] [--component C] [--deb-architectures \"A B\"] [--public-key PIN] (see the header of $0)"
}

site='' name='' version='' suite=stable component=main deb_archs='' pin=''
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --site) site="$2" ;;
        --name) name="$2" ;;
        --version) version="$2" ;;
        --suite) suite="$2" ;;
        --component) component="$2" ;;
        --deb-architectures) deb_archs="$2" ;;
        --public-key) pin="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$site" ] && [ -n "$name" ] && [ -n "$version" ] || usage
[ -d "$site" ] || die "site $site is not a directory"
check_name name "$name"
check_word suite "$suite"
check_word component "$component"
for a in $deb_archs; do check_word deb-architectures "$a"; done
case "$version" in
    '' | *[!A-Za-z0-9.+~_-]*) die "version must match [A-Za-z0-9.+~_-]+, not '$version'" ;;
esac
require_tools gzip sed awk find sha256sum sort comm

# gpg only reads the pin here. Use a private home unless the caller has one (a signing run does).
if [ -z "${GNUPGHOME:-}" ] && [ -n "$pin" ]; then
    GNUPGHOME=''
    make_tmpdir GNUPGHOME
    chmod 700 "$GNUPGHOME"
    export GNUPGHOME
fi
work=''
make_tmpdir work

fail() { die "self-check: $*"; }
need() { [ -s "$site/$1" ] || fail "$1 is missing or empty"; }

need index.html

# --- Nix -------------------------------------------------------------------------------------
if [ -e "$site/nix/flake.tar.gz" ] || [ -e "$site/nix/flake.nix" ] || [ -e "$site/nix/flake.lock" ]; then
    require_tools tar cmp
    need nix/flake.tar.gz
    need nix/flake.nix
    need nix/flake.lock
    tar -tzf "$site/nix/flake.tar.gz" | LC_ALL=C sort > "$work/nix-files"
    printf 'flake.lock\nflake.nix\n' > "$work/nix-expected"
    cmp -s "$work/nix-expected" "$work/nix-files" || fail "flake.tar.gz must contain only flake.lock and flake.nix"
fi

# --- Which layouts the site has --------------------------------------------------------------
has_deb=false has_rpm=false
if [ -e "$site/deb/$name.list" ] || [ -d "$site/deb/dists" ]; then has_deb=true; fi
if [ -e "$site/rpm/$name.repo" ] || [ -n "$(find "$site/rpm" -mindepth 2 -maxdepth 2 -name repodata 2> /dev/null)" ]; then
    has_rpm=true
fi

# --- APT -------------------------------------------------------------------------------------
if [ "$has_deb" = true ]; then
    need "deb/$name.list"
    need "deb/dists/$suite/Release"
    n=0
    for d in "$site/deb/dists/$suite/$component"/binary-*/; do
        [ -d "$d" ] || continue
        n=$((n + 1))
        [ -s "${d}Packages.gz" ] || fail "${d#"$site"/}Packages.gz is missing or empty"
    done
    [ "$n" -gt 0 ] || fail "deb/dists/$suite/$component has no binary-<arch> directory"
    # Every required architecture's index lists the release (cargo-deb's 1.2.3-1 included).
    for a in $deb_archs; do
        [ "$a" != all ] || continue
        need "deb/dists/$suite/$component/binary-$a/Packages.gz"
        gzip -cd "$site/deb/dists/$suite/$component/binary-$a/Packages.gz" | sed -n 's/^Version: //p' > "$work/versions"
        ok=false
        while IFS= read -r v; do
            if pkg_matches_version deb "$v" "$version"; then ok=true; fi
        done < "$work/versions"
        [ "$ok" = true ] || fail "binary-$a/Packages does not list $version"
    done
fi

# --- DNF -------------------------------------------------------------------------------------
if [ "$has_rpm" = true ]; then
    need "rpm/$name.repo"
    n=0
    for d in "$site"/rpm/*/; do
        [ -d "$d" ] || continue
        n=$((n + 1))
        [ -s "${d}repodata/repomd.xml" ] || fail "${d#"$site"/}repodata/repomd.xml is missing or empty"
    done
    [ "$n" -gt 0 ] || fail "rpm/ has no <arch> directory"
fi

# --- Signatures ------------------------------------------------------------------------------
if [ -n "$pin" ]; then
    require_tools gpg gpgv
    need "$name.asc"
    cmp -s "$pin" "$site/$name.asc" || fail "$name.asc is not the public key $pin, byte for byte"
    verify() { gpg_verify "$pin" "$@"; }
    if [ "$has_deb" = true ]; then
        need "deb/dists/$suite/InRelease"
        verify "$site/deb/dists/$suite/InRelease"
        verify "$site/deb/dists/$suite/Release.gpg" "$site/deb/dists/$suite/Release"
    fi
    if [ "$has_rpm" = true ]; then
        grep -qx gpgcheck=1 "$site/rpm/$name.repo" || fail "gpgcheck=1 is missing from $name.repo"
        # dnf's key: the pin without revoked or expired subkeys, byte for byte what a fresh
        # pin_rpm_key makes, with one primary and a signing subkey.
        rpm_key="$site/rpm/RPM-GPG-KEY-$name"
        need "rpm/RPM-GPG-KEY-$name"
        awk -v s="/rpm/RPM-GPG-KEY-$name" '/^gpgkey=/ && substr($0, length($0) - length(s) + 1) == s { f = 1 } END { exit !f }' "$site/rpm/$name.repo" ||
            fail "$name.repo has no gpgkey= line for rpm/RPM-GPG-KEY-$name"
        pin_rpm_key "$pin" "$work/rpm-key"
        cmp -s "$work/rpm-key" "$rpm_key" || fail "rpm/RPM-GPG-KEY-$name is not the pin without its revoked and expired subkeys"
        gpg --batch --with-colons --show-keys "$rpm_key" > "$work/rpm-key.colons" 2> /dev/null ||
            fail "rpm/RPM-GPG-KEY-$name is not an OpenPGP certificate"
        [ "$(grep -c '^pub:' "$work/rpm-key.colons")" -eq 1 ] || fail "rpm/RPM-GPG-KEY-$name must hold exactly one primary key"
        if awk -F: '$1 == "sub" && $2 ~ /[re]/ { f = 1 } END { exit !f }' "$work/rpm-key.colons"; then
            fail "rpm/RPM-GPG-KEY-$name holds a revoked or expired subkey"
        fi
        awk -F: '$1 == "sub" && index($12, "s") { f = 1 } END { exit !f }' "$work/rpm-key.colons" ||
            fail "rpm/RPM-GPG-KEY-$name holds no signing subkey"
        # Everything dnf checks verifies against that key alone.
        for d in "$site"/rpm/*/; do
            [ -d "$d" ] || continue
            need "${d#"$site"/}repodata/repomd.xml.asc"
            verify "${d}repodata/repomd.xml.asc" "${d}repodata/repomd.xml"
            gpg_verify "$rpm_key" "${d}repodata/repomd.xml.asc" "${d}repodata/repomd.xml"
        done
        set -- "$site"/rpm/*/*.rpm
        [ -e "$1" ] || fail "rpm/ holds no .rpm file"
        check_rpm "$pin" "$@"
        check_rpm "$rpm_key" "$@"
    fi
fi

# --- The manifest ----------------------------------------------------------------------------
manifest="$site/pkg-pages.tsv"
if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || fail "pkg-pages.tsv is not a regular file"
    if [ -n "$pin" ]; then
        need pkg-pages.tsv.asc
        gpg_verify "$pin" "$manifest.asc" "$manifest"
    fi
    [ -z "$(tail -c 1 "$manifest")" ] || fail "pkg-pages.tsv does not end with a newline"
    want_fpr=-
    [ -z "$pin" ] || want_fpr="$(pin_fpr "$pin")"
    : > "$work/listed"
    n=0
    while IFS='	' read -r kind tag sum path extra; do
        n=$((n + 1))
        if [ "$n" -eq 1 ]; then
            [ "$kind" = '#pkg-pages-manifest' ] && [ "$tag" = 1 ] && [ "$sum" = "$name" ] &&
                [ "$path" = "$want_fpr" ] && [ -z "$extra" ] ||
                fail "the header of pkg-pages.tsv is not '#pkg-pages-manifest 1 $name $want_fpr'"
            continue
        fi
        [ -z "$extra" ] || fail "pkg-pages.tsv line $n has more than four fields"
        case "$kind" in
            release) printf '%s\n' "$tag" | LC_ALL=C grep -Eq '^[A-Za-z0-9._+/-]+$' || fail "pkg-pages.tsv line $n: bad tag '$tag'" ;;
            keyring) [ "$tag" = - ] || fail "pkg-pages.tsv line $n: a keyring line has - for its tag" ;;
            *) fail "pkg-pages.tsv line $n: unknown kind '$kind'" ;;
        esac
        printf '%s\n' "$sum" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || fail "pkg-pages.tsv line $n: bad SHA-256 '$sum'"
        if ! printf '%s\n' "$path" | LC_ALL=C grep -Eq '^(deb/pool/[A-Za-z0-9._+~/-]+\.deb|rpm/[A-Za-z0-9_-]+/[A-Za-z0-9._+~-]+\.rpm)$'; then
            fail "pkg-pages.tsv line $n: bad path '$path'"
        fi
        case "/$path/" in *//* | */./* | */../*) fail "pkg-pages.tsv line $n: bad path '$path'" ;; esac
        [ -f "$site/$path" ] && [ ! -L "$site/$path" ] || fail "pkg-pages.tsv lists $path, which the site does not have"
        [ "$(sha256sum "$site/$path" | cut -d' ' -f1)" = "$sum" ] || fail "$path does not match the SHA-256 in pkg-pages.tsv"
        printf '%s\n' "$path" >> "$work/listed"
    done < "$manifest"
    [ "$n" -ge 1 ] || fail "pkg-pages.tsv is empty"
    LC_ALL=C sort "$work/listed" > "$work/listed.sorted"
    [ -z "$(LC_ALL=C uniq -d "$work/listed.sorted")" ] || fail "pkg-pages.tsv lists $(LC_ALL=C uniq -d "$work/listed.sorted" | head -n 1) twice"
    # Every package file of the site is listed: a file the manifest doesn't name is unvouched for.
    (
        cd "$site"
        [ ! -d deb/pool ] || find deb/pool \( -name '*.deb' -o -name '*.rpm' \)
        [ ! -d rpm ] || find rpm \( -name '*.deb' -o -name '*.rpm' \)
    ) > "$work/found"
    [ -z "$(
        cd "$site"
        [ ! -d deb/pool ] || find deb/pool \( -name '*.deb' -o -name '*.rpm' \) ! -type f
        [ ! -d rpm ] || find rpm \( -name '*.deb' -o -name '*.rpm' \) ! -type f
    )" ] || fail "a package file of the site is not a regular file"
    LC_ALL=C sort "$work/found" > "$work/found.sorted"
    unlisted="$(LC_ALL=C comm -13 "$work/listed.sorted" "$work/found.sorted" | head -n 1)"
    [ -z "$unlisted" ] || fail "$unlisted is not listed in pkg-pages.tsv"
fi

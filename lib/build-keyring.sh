#!/bin/sh
# Build the <name>-keyring .deb from the pin. Needs no secret.
# No .rpm: rpm can't import a key from a package scriptlet (the transaction holds the rpm database
# lock). DNF takes its key from rpm/RPM-GPG-KEY-<name> through gpgkey= (docs/signing.md).
#
# Usage:
#   build-keyring.sh --pin FILE --name NAME --out DIR
#       Writes DIR/NAME-keyring_VERSION_all.deb. DIR is created.
#
# The version is YYYYMMDD.HHMMSS (UTC), taken from the newest signature packet in the pin, so a
# new subkey, a rotation or a revocation, which add signatures, give a higher version, and the same
# pin always gives the same version. The .deb is built reproducibly: the same pin gives a
# byte-identical package.
#
# Prints a notice when the pin has fewer than two usable (not revoked, not expired) signing
# subkeys: without a standby subkey a rotation has no key to move to.
#
# Outputs, when run in GitHub Actions (GITHUB_OUTPUT is set): deb=<path> and version=<version>.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

usage() {
    die "usage: $0 --pin FILE --name NAME --out DIR"
}

pin=
name=
out=
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --pin) pin="$2" ;;
        --name) name="$2" ;;
        --out) out="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$pin" ] && [ -n "$name" ] && [ -n "$out" ] || usage

check_name name "$name"
require_tools gpg awk date

# Every gpg call runs in a private, empty home, so nothing here touches the caller's keyring.
GNUPGHOME=
make_tmpdir GNUPGHOME
chmod 700 "$GNUPGHOME"
export GNUPGHOME

# pin_fpr also refuses a pin that holds secret key material or more than one key.
pin_fpr "$pin" > /dev/null
require_tools dpkg-deb

# keyring_epoch PIN: the largest creation time (seconds since the epoch) of the signature packets.
keyring_epoch() {
    gpg --batch --list-packets "$1" 2> /dev/null | awk '
        /^:/ { sig = ($0 ~ /^:signature packet:/) }
        sig && match($0, /created [0-9]+,/) {
            t = substr($0, RSTART + 8, RLENGTH - 9) + 0
            if (t > max) max = t
        }
        END { if (max > 0) printf "%d\n", max }'
}

# usable_signers PIN: how many subkeys can sign: 's' among the capabilities, not revoked or expired.
usable_signers() {
    gpg --batch --with-colons --show-keys "$1" 2> /dev/null | awk -F: '
        $1 == "sub" && index($12, "s") && $2 !~ /[re]/ { n++ }
        END { print n + 0 }'
}

epoch="$(keyring_epoch "$pin")"
[ -n "$epoch" ] || die "public-key $pin holds no signature, so it has no version"
version="$(date -u -d "@$epoch" +%Y%m%d.%H%M%S)"
pkg="$name-keyring"

if [ "$(usable_signers "$pin")" -lt 2 ]; then
    notice "public-key $pin lists fewer than two usable signing subkeys; add a standby subkey so a rotation has a key to move to"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd)"
umask 022
work=
make_tmpdir work

# build_deb: DIR/NAME-keyring_VERSION_all.deb, holding the pin as /usr/share/keyrings/NAME-keyring.asc.
build_deb() {
    _root="$work/deb"
    mkdir -p "$_root/DEBIAN" "$_root/usr/share/keyrings"
    cp "$pin" "$_root/usr/share/keyrings/$pkg.asc"
    cat > "$_root/DEBIAN/control" << EOF
Package: $pkg
Version: $version
Architecture: all
Multi-Arch: foreign
Section: misc
Priority: optional
Maintainer: pkg-pages <noreply@pkg-pages.invalid>
Description: OpenPGP key of the $name package repositories
 Installs the public key that signs the $name APT repository, for use
 as the signed-by key of its sources entry.
EOF
    chmod 644 "$_root/DEBIAN/control" "$_root/usr/share/keyrings/$pkg.asc"
    find "$_root" -exec touch -h -d "@$epoch" {} +
    deb_file="$out/${pkg}_${version}_all.deb"
    SOURCE_DATE_EPOCH="$epoch" dpkg-deb --root-owner-group -Zgzip --build "$_root" "$deb_file" > /dev/null ||
        die "dpkg-deb failed"
    log "built $deb_file"
}

build_deb
set_output deb "$deb_file"
set_output version "$version"

#!/bin/sh
# Throwaway test material, generated on the fly so that no key or package is ever committed.
# Used by the bats tests and by the CI workflow.
#
# Usage:
#   tests/fixtures.sh key DIR [NAME]
#       A test key like the one docs/signing.md describes: a certify-only primary and a signing
#       subkey, no passphrase. Writes into DIR (created, must not exist):
#         home/       its GNUPGHOME (holds the primary's secret: the "offline" maintainer copy)
#         pin.asc     the public certificate, as a project commits it
#         ci.asc      the signing subkey alone, without the primary's secret: the CI secret
#         fpr, sub    the primary's and the subkey's fingerprints
#   tests/fixtures.sh deb OUTDIR NAME VERSION ARCH
#       A minimal .deb (dpkg-deb), file name as cargo-deb writes it. Installs
#       /usr/share/NAME/VERSION, holding VERSION and $FIXTURE_NOTE.
#   tests/fixtures.sh rpm OUTDIR NAME VERSION ARCH [RELEASE]
#       A minimal .rpm (rpmbuild), release 1 by default. Installs /usr/share/NAME/VERSION.
#
# Test keys are 2048-bit RSA (fast to generate); real ones are 4096.
set -eu

die() {
    echo "fixtures.sh: $*" >&2
    exit 1
}

key() {
    dir="$1"
    uid="${2:-pkg-pages test} <test@example.invalid>"
    [ ! -e "$dir" ] || die "$dir exists"
    mkdir -p "$dir/home"
    chmod 700 "$dir/home"
    g() { gpg --homedir "$dir/home" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"; }
    g --quick-gen-key "$uid" rsa2048 cert never 2> /dev/null
    fpr="$(g --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    sub="$(g --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g --armor --export "$fpr" > "$dir/pin.asc"
    g --armor --export-secret-subkeys "$sub!" > "$dir/ci.asc"
    printf '%s\n' "$fpr" > "$dir/fpr"
    printf '%s\n' "$sub" > "$dir/sub"
}

deb() {
    out="$1" name="$2" version="$3" arch="$4"
    command -v dpkg-deb > /dev/null || die "dpkg-deb is not installed"
    mkdir -p "$out"
    root="$(mktemp -d)"
    mkdir -p "$root/DEBIAN" "$root/usr/share/$name"
    # FIXTURE_NOTE changes the contents, for "same name and version, other bytes" tests.
    printf '%s %s\n' "$version" "${FIXTURE_NOTE:-}" > "$root/usr/share/$name/$version"
    cat > "$root/DEBIAN/control" << EOF
Package: $name
Version: $version
Architecture: $arch
Maintainer: pkg-pages tests <test@example.invalid>
Description: pkg-pages test package
 Installs one file.
EOF
    dpkg-deb --root-owner-group -Zgzip --build "$root" "$out/${name}_${version}_$arch.deb" > /dev/null
    rm -rf "$root"
}

rpm_() {
    out="$1" name="$2" version="$3" arch="$4" release="${5:-1}"
    command -v rpmbuild > /dev/null || die "rpmbuild is not installed"
    mkdir -p "$out"
    top="$(mktemp -d)"
    if [ "$arch" = noarch ]; then buildarch="BuildArch: noarch"; else buildarch=; fi
    cat > "$top/$name.spec" << EOF
Name: $name
Version: $version
Release: $release
Summary: pkg-pages test package
License: Apache-2.0
$buildarch

%description
Installs one file.

%install
mkdir -p %{buildroot}/usr/share/$name
echo $version > %{buildroot}/usr/share/$name/$version

%files
/usr/share/$name/$version
EOF
    target=
    [ "$arch" = noarch ] || target="--target $arch"
    # shellcheck disable=SC2086 # $target is empty or two words
    rpmbuild --quiet -bb $target --define "_topdir $top" --define "_rpmdir $top/out" \
        --define '_build_id_links none' --define 'debug_package %{nil}' \
        "$top/$name.spec" > /dev/null 2>&1 || {
        rpmbuild -bb $target --define "_topdir $top" --define "_rpmdir $top/out" "$top/$name.spec" >&2 || true
        die "rpmbuild failed"
    }
    find "$top/out" -name '*.rpm' -exec cp {} "$out/" \;
    rm -rf "$top"
}

[ "$#" -ge 1 ] || die "usage: $0 key DIR [NAME] | deb OUTDIR NAME VERSION ARCH | rpm OUTDIR NAME VERSION ARCH [RELEASE]"
cmd="$1"
shift
# Not `[ ... ] && key "$@" || die`: set -e does not apply inside such a list.
case "$cmd" in
    key) [ "$#" -ge 1 ] || die "usage: $0 key DIR [NAME]" ;;
    deb) [ "$#" -eq 4 ] || die "usage: $0 deb OUTDIR NAME VERSION ARCH" ;;
    rpm) [ "$#" -ge 4 ] || die "usage: $0 rpm OUTDIR NAME VERSION ARCH [RELEASE]" ;;
    *) die "unknown command $cmd" ;;
esac
case "$cmd" in
    key) key "$@" ;;
    deb) deb "$@" ;;
    rpm) rpm_ "$@" ;;
esac

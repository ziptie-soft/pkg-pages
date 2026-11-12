#!/bin/sh
# Install packages on a clean distribution, as a user would, then run a smoke command. Runs as
# root inside the distro container that the install-test action starts (lib/run.sh).
#
# Usage:
#   install-test.sh [--pin FILE] FILE...
#
#   FILE...   all .deb (apt-get, Debian and Ubuntu) or all .rpm (dnf, Fedora and RHEL). Only
#             the packages for the container's own architecture, and all/noarch ones, are
#             installed (read from each package's metadata), so one call can get every
#             architecture's packages; it fails when none fits
#   --pin     check the .rpm signatures against this public key first, as dnf does with
#             gpgcheck=1; skipped when the file does not exist (an unsigned project)
#   PKG_PAGES_SMOKE  shell command run after the install with `sh -eu -c` (optional)
#
# The packages are copied to a temporary directory first: APT downloads as the _apt user, who
# can't read some bind mounts.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

pin=
if [ "${1:-}" = --pin ]; then
    [ "$#" -ge 2 ] || die "usage: $0 [--pin FILE] FILE..."
    pin="$2"
    shift 2
fi
[ "$#" -ge 1 ] || die "usage: $0 [--pin FILE] FILE..."

kind=
for f in "$@"; do
    [ -f "$f" ] || die "$f is not a file"
    case "$f" in
        *.deb) k=deb ;;
        *.rpm) k=rpm ;;
        *) die "$f is neither a .deb nor an .rpm" ;;
    esac
    [ -z "$kind" ] || [ "$kind" = "$k" ] || die "install .deb and .rpm files in separate tests"
    kind="$k"
done

case "$kind" in
    rpm)
        command -v dnf > /dev/null || die ".rpm packages need an image with dnf (fedora)"
        native="$(rpm --eval '%{_arch}')"
        any=noarch
        ;;
    deb)
        command -v apt-get > /dev/null || die ".deb packages need an image with apt-get (debian, ubuntu)"
        native="$(dpkg --print-architecture)"
        any=all
        ;;
esac

# Copy the packages for this architecture to a directory every user can read.
stage=''
make_tmpdir stage
chmod 755 "$stage"
for f in "$@"; do
    a="$(pkg_meta "$f" | cut -f4)"
    if [ "$a" = "$native" ] || [ "$a" = "$any" ]; then
        cp "$f" "$stage/"
    else
        log "skipping ${f##*/}: $a, not $native"
    fi
done
[ -n "$(ls -A "$stage")" ] || die "none of the packages is for $native (or $any)"
chmod 644 "$stage"/*
set -- "$stage"/*

case "$kind" in
    rpm)
        if [ -n "$pin" ] && [ -f "$pin" ]; then
            check_rpm "$pin" "$@"
        else
            notice "no public key: the .rpm signatures were not checked"
        fi
        dnf install -y -q "$@"
        ;;
    deb)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq "$@"
        ;;
esac
log "installed: $(for f in "$@"; do printf '%s ' "${f##*/}"; done)"

if [ -n "${PKG_PAGES_SMOKE:-}" ]; then
    log "running the smoke command"
    sh -eu -c "$PKG_PAGES_SMOKE"
fi

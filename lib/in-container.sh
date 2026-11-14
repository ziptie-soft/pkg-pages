#!/bin/sh
# The entry point of every container that run.sh starts (docker mode). Not meant to be run by
# hand. It installs the tools of PKG_PAGES_TOOLS, runs COMMAND, then gives the paths of
# PKG_PAGES_WRITES back to PKG_PAGES_OWNER (uid:gid), since the container runs as root.
# REPO_SIGNING_KEY is taken out of the environment while the tools are installed, and given
# back to COMMAND only.
#
# --install-only (run.sh's first, throwaway container): install the missing tools, remove the
# package caches, and stop there. It exits 10 when nothing was missing, so run.sh commits no image.
#
# Usage (inside the container): in-container.sh --install-only | COMMAND [ARG]...
set -eu
install_only=false
if [ "${1:-}" = --install-only ]; then
    install_only=true
    shift
fi

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"

# package_for MANAGER TOOL: the distribution package that provides TOOL.
package_for() {
    case "$1:$2" in
        apt:gpg) echo gnupg ;;
        apt:gpgv) echo gpgv ;;
        apt:rpm | apt:rpmsign | apt:rpmkeys | apt:rpmbuild) echo rpm ;;
        apt:apt-ftparchive) echo apt-utils ;;
        apt:createrepo_c) echo createrepo-c ;;
        apt:dpkg-deb) echo dpkg ;;
        apt:tar) echo tar ;;
        apt:gzip) echo gzip ;;
        apt:xz) echo xz-utils ;;
        dnf:gpg | dnf:gpgv) echo gnupg2 ;;
        dnf:rpm | dnf:rpmkeys) echo rpm ;;
        dnf:rpmsign) echo rpm-sign ;;
        dnf:rpmbuild) echo rpm-build ;;
        dnf:createrepo_c) echo createrepo_c ;;
        dnf:dpkg-deb) echo dpkg ;;
        dnf:tar) echo tar ;;
        dnf:gzip) echo gzip ;;
        dnf:xz) echo xz ;;
        dnf:apt-ftparchive) die "apt-ftparchive is not available on Fedora; use the debian image" ;;
        *) die "don't know which package provides $2 ($1)" ;;
    esac
}

# The signing key is for COMMAND only: the package manager and the maintainer scripts it runs
# never see it in their environment.
key_set=false
if [ -n "${REPO_SIGNING_KEY+set}" ]; then
    key_set=true
    signing_key="$REPO_SIGNING_KEY"
    unset REPO_SIGNING_KEY
fi

# Only what is missing, so images that already have a tool skip the package manager.
pkgs=
manager=
if command -v apt-get > /dev/null; then manager=apt; elif command -v dnf > /dev/null; then manager=dnf; fi
for tool in ${PKG_PAGES_TOOLS:-}; do
    command -v "$tool" > /dev/null && continue
    [ -n "$manager" ] || die "$tool is missing and the image has neither apt-get nor dnf"
    pkgs="$pkgs $(package_for "$manager" "$tool")"
done
if [ -n "$pkgs" ]; then
    log "installing$pkgs"
    # Package manager chatter goes to stderr, so stdout stays the command's own.
    # shellcheck disable=SC2086 # pkgs is a space-separated list
    case "$manager" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >&2
            apt-get install -y -qq --no-install-recommends ca-certificates $pkgs >&2
            ;;
        dnf) dnf install -y -q $pkgs >&2 ;;
    esac
fi

if [ "$install_only" = true ]; then
    [ -n "$pkgs" ] || exit 10
    # The caches would only make the committed image bigger.
    case "$manager" in
        apt) apt-get clean >&2 && rm -rf /var/lib/apt/lists/* ;;
        dnf) dnf clean all >&2 ;;
    esac
    exit 0
fi

if [ "$key_set" = true ]; then
    REPO_SIGNING_KEY="$signing_key"
    export REPO_SIGNING_KEY
    unset signing_key
fi

status=0
"$@" || status=$?

if [ -n "${PKG_PAGES_OWNER:-}" ]; then
    printf '%s\n' "${PKG_PAGES_WRITES:-}" | while IFS= read -r p; do
        [ -z "$p" ] || [ ! -e "$p" ] || chown -R "$PKG_PAGES_OWNER" "$p"
    done
fi
exit "$status"

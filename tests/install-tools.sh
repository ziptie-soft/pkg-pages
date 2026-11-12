# shellcheck shell=sh
# Install bats and every tool the lib/ scripts and the tests use, in a fresh images.env
# container (as root). Sourced by tests/container.sh and by the CI `container-tests` job.
# Fedora has no apt-ftparchive, so the APT tests skip there.
if command -v apt-get > /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # rpm brings rpmbuild, rpmsign and rpmkeys on Debian and Ubuntu.
    apt-get install -y -qq --no-install-recommends \
        bats ca-certificates gnupg gpgv apt-utils createrepo-c rpm dpkg-dev > /dev/null
elif command -v dnf > /dev/null; then
    # dnf5 prints progress even with -q; show it only when the install fails. (No `set --`:
    # this file is sourced, and the caller's arguments must survive.)
    _pkgs='bats gnupg2 rpm-sign rpm-build createrepo_c dpkg findutils diffutils'
    # shellcheck disable=SC2086 # a list of package names
    dnf install -y -q $_pkgs > /dev/null 2>&1 || dnf install -y $_pkgs
else
    echo "install-tools.sh: neither apt-get nor dnf found" >&2
    exit 1
fi

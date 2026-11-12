#!/bin/sh
# Run the bats suite inside one of the images.env containers, with every tool the scripts use
# installed, as root. Tests that need a tool the host lacks (apt-ftparchive, rpmsign, ...) or root
# (installing from the built repositories) are skipped by `mise run test` and run here.
#
# Usage: tests/container.sh debian|ubuntu|fedora [BATS_ARGS...]
#   DOCKER   container engine (default: podman if installed, else docker)
#
# The checkout is mounted read-only at /src; the tests write only to their own temp directories.
# Examples: tests/container.sh debian
#           tests/container.sh fedora tests/signing.bats
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 1 ] || { echo "usage: $0 debian|ubuntu|fedora [BATS_ARGS...]" >&2; exit 2; }
distro="$1"
shift

var="$(printf '%s' "$distro" | tr '[:lower:]' '[:upper:]')_IMAGE"
image="$(sed -n "s/^${var}=//p" "$root/images.env")"
[ -n "$image" ] || { echo "no $var in images.env" >&2; exit 2; }
docker="${DOCKER:-$(command -v podman || command -v docker || true)}"
[ -n "$docker" ] || { echo "neither podman nor docker is installed" >&2; exit 2; }

[ "$#" -gt 0 ] || set -- tests
# -t only when attached to a terminal, so CI logs stay plain.
tty=
[ ! -t 1 ] || tty=-t
# shellcheck disable=SC2086 # $tty is empty or -t
# label=disable: SELinux hosts (Fedora) otherwise deny the container access to the mount.
exec "$docker" run --rm -i $tty --security-opt label=disable \
    -v "$root:/src:ro" -w /src \
    -e PKG_PAGES_TEST_SYSTEM=1 \
    "$image" sh -euc '. /src/tests/install-tools.sh; exec bats "$@"' sh "$@"

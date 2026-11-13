#!/bin/sh
# Refresh lib/nix/flake.lock with the pinned Nix image. Run by maintainers only, never in CI.
# Usage: dev/nix-lock.sh. Reads nixpkgs_ref from lib/nix-flake.sh and writes the lock file there.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="$(sed -n 's/^nixpkgs_ref=//p' "$root/lib/nix-flake.sh")"
case "$ref" in nixpkgs-unstable) ;; *) echo "unexpected nixpkgs_ref '$ref'" >&2; exit 1 ;; esac
image="$(sed -n 's/^NIX_IMAGE=//p' "$root/images.env")"
[ -n "$image" ] || { echo "images.env has no NIX_IMAGE" >&2; exit 1; }
docker="${DOCKER:-$(command -v podman || command -v docker || true)}"
[ -n "$docker" ] || { echo "neither podman nor docker is installed" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-nix-lock.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf ' {\n  inputs.nixpkgs.url = "github:NixOS/nixpkgs/%s";\n  outputs = { self, nixpkgs }: { };\n}\n' "$ref" > "$tmp/flake.nix"
"$docker" run --rm -i --security-opt label=disable \
    --volume "$tmp:/work" --workdir /work "$image" \
    nix --extra-experimental-features 'nix-command flakes' flake lock
[ -s "$tmp/flake.lock" ] || { echo "Nix did not write flake.lock" >&2; exit 1; }
cp "$tmp/flake.lock" "$root/lib/nix/flake.lock"
printf 'Updated %s/lib/nix/flake.lock for %s\n' "$root" "$ref"

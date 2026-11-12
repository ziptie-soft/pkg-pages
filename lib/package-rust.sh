#!/bin/sh
# Build .deb and .rpm packages of a Rust crate with cargo-deb and cargo-generate-rpm: what the
# source projects' `linux-assets` jobs do, minus their project-specific checks. Used by the
# package-rust action; runs on the build runner, never in a job that holds a signing key.
#
# Usage:
#   package-rust.sh [--target TRIPLE] [--package CRATE] [--formats "deb rpm"] [--out DIR]
#                   [--version VERSION] [--build true|false] [--install-tools true|false]
#                   [--cargo-deb-version V] [--cargo-generate-rpm-version V]
#
#   --target        Rust target triple (default: the host's). Pass it for cross builds, which
#                   also need the target's linker; an arm runner is simpler.
#   --package       crate of a workspace (cargo -p); default: the current directory's crate
#   --formats       deb, rpm or both (default "deb rpm")
#   --out           directory the packages are written to (default dist; created)
#   --version       override the crate version in both packages (default: Cargo.toml's)
#   --build         run `cargo build --release --locked` first (default true); false when the
#                   release binaries are already built
#   --install-tools cargo install --locked the pinned cargo-deb / cargo-generate-rpm when the
#                   installed ones are missing or another version (default true)
#
# The crate configures its packages as usual: [package.metadata.deb] and
# [package.metadata.generate-rpm] in Cargo.toml. Each package is checked after the build: its
# metadata must be readable, and its name and version must be what Cargo.toml (or --version)
# says.
#
# Outputs (GITHUB_OUTPUT): deb, rpm (paths, space-separated), deb-arch, rpm-arch, version.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"

usage() { die "usage: $0 [--target TRIPLE] [--package CRATE] [--formats \"deb rpm\"] [--out DIR] [--version VERSION] [--build true|false] [--install-tools true|false] [--cargo-deb-version V] [--cargo-generate-rpm-version V]"; }

target='' package='' formats="deb rpm" out=dist version='' build=true install=true
deb_tool_version=3.8.0 rpm_tool_version=0.21.1
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --target) target="$2" ;;
        --package) package="$2" ;;
        --formats) formats="$2" ;;
        --out) out="$2" ;;
        --version) version="$2" ;;
        --build) build="$2" ;;
        --install-tools) install="$2" ;;
        --cargo-deb-version) deb_tool_version="$2" ;;
        --cargo-generate-rpm-version) rpm_tool_version="$2" ;;
        *) usage ;;
    esac
    shift 2
done

check_bool build "$build"
check_bool install-tools "$install"
check_relpath out "$out"
[ -z "$target" ] || check_word target "$target"
case "$package" in *[!A-Za-z0-9_-]*) die "package must be a crate name, not '$package'" ;; esac
case "$version" in *[!A-Za-z0-9.+~-]*) die "version must match [A-Za-z0-9.+~-]*, not '$version'" ;; esac
for v in "$deb_tool_version" "$rpm_tool_version"; do
    printf '%s\n' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "tool versions must be X.Y.Z, not '$v'"
done
want_deb=false want_rpm=false
for f in $formats; do
    case "$f" in
        deb) want_deb=true ;;
        rpm) want_rpm=true ;;
        *) die "formats must be deb and/or rpm, not '$f'" ;;
    esac
done
[ "$want_deb" = true ] || [ "$want_rpm" = true ] || die "formats is empty"
require_tools cargo

# --- Tools -----------------------------------------------------------------------------------
# The tools are called as cargo-deb and cargo-generate-rpm rather than `cargo deb`: the same
# binaries, but found on PATH even when cargo is a wrapper (rustup proxies, mise) that resets it.
# installed_version TOOL: the version `TOOL --version` reports, or nothing.
installed_version() {
    "$1" --version 2> /dev/null | awk '{ print $NF; exit }' | sed 's/^v//' || true
}
ensure_tool() {
    crate="$1" want="$2"
    have="$(installed_version "$crate")"
    [ "$have" != "$want" ] || return 0
    [ "$install" = true ] || die "$crate ${have:-is not installed}; want $want (or pass install-tools: true)"
    log "installing $crate $want (found: ${have:-none})"
    cargo install --locked --quiet "$crate@$want"
}
[ "$want_deb" = false ] || ensure_tool cargo-deb "$deb_tool_version"
[ "$want_rpm" = false ] || ensure_tool cargo-generate-rpm "$rpm_tool_version"

# --- Build -----------------------------------------------------------------------------------
# Common cargo arguments; each is one word, so plain word splitting is safe here.
cargo_args=
[ -z "$target" ] || cargo_args="$cargo_args --target $target"
[ -z "$package" ] || cargo_args="$cargo_args --package $package"
if [ "$build" = true ]; then
    # shellcheck disable=SC2086
    cargo build --release --locked $cargo_args
fi

# The crate version, for the checks below. `cargo pkgid` prints path+file:///dir#VERSION or
# path+file:///dir#NAME@VERSION; in a workspace root it needs --package.
if [ -n "$package" ]; then
    pkgid="$(cargo pkgid --package "$package")" || die "cargo pkgid --package $package failed"
else
    pkgid="$(cargo pkgid)" || die "cargo pkgid failed; in a workspace, pass package"
fi
crate_version="${pkgid##*#}"
crate_version="${crate_version##*@}"
expected="${version:-$crate_version}"
[ -n "$expected" ] || die "could not read the crate version from '$pkgid'"

mkdir -p "$out"
stage=''
make_tmpdir stage
debs='' rpms='' deb_arch='' rpm_arch=''
if [ "$want_deb" = true ]; then
    set --
    [ -z "$version" ] || set -- --deb-version "$version"
    # shellcheck disable=SC2086
    cargo-deb --no-build $cargo_args --output "$stage/" "$@" > /dev/null
fi
if [ "$want_rpm" = true ]; then
    set --
    [ -z "$version" ] || set -- --set-metadata "version = \"$(printf '%s' "$version" | sed 's/-/~/')\""
    # shellcheck disable=SC2086 # cargo-generate-rpm's --target only names the directory
    cargo-generate-rpm $cargo_args --output "$stage/" "$@"
fi

# --- Check and move into OUT -----------------------------------------------------------------
for f in "$stage"/*; do
    [ -f "$f" ] || continue
    case "$f" in
        *.deb) kind=deb ;;
        *.rpm) kind=rpm ;;
        *) continue ;;
    esac
    if [ "$kind" = deb ]; then reader=dpkg-deb; else reader=rpm; fi
    if command -v "$reader" > /dev/null; then
        m="$(pkg_meta "$f")"
        pver="$(printf '%s' "$m" | cut -f3)"
        parch="$(printf '%s' "$m" | cut -f4)"
        pkg_matches_version "$kind" "$pver" "$expected" ||
            die "${f##*/} has version $pver, but the crate version is $expected"
    else
        log "${f##*/}: $reader is not installed, so its metadata was not checked"
        # Both tools name files NAME_VERSION_ARCH.deb and NAME-VERSION-RELEASE.ARCH.rpm.
        if [ "$kind" = deb ]; then parch="${f##*_}"; parch="${parch%.deb}"; else parch="${f%.rpm}"; parch="${parch##*.}"; fi
    fi
    mv "$f" "$out/"
    dest="$out/${f##*/}"
    if [ "$kind" = deb ]; then
        debs="$debs $dest"
        deb_arch="$parch"
    else
        rpms="$rpms $dest"
        rpm_arch="$parch"
    fi
    log "built $dest"
done
[ "$want_deb" = false ] || [ -n "$debs" ] || die "cargo deb wrote no .deb"
[ "$want_rpm" = false ] || [ -n "$rpms" ] || die "cargo generate-rpm wrote no .rpm"

set_output deb "${debs# }"
set_output rpm "${rpms# }"
set_output deb-arch "$deb_arch"
set_output rpm-arch "$rpm_arch"
set_output version "$expected"

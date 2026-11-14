#!/bin/sh
# Build the APT and DNF repositories site from a directory of .deb and .rpm files, ready to be
# served by GitHub Pages (or any static file server). Rewritten from SkeLLLa/star-forge's
# packaging/ci/pages-repo.sh to read each package's own metadata instead of matching file names.
#
# This is the one-process form of the staged build: it signs the .rpm files, builds the keyring
# package, then runs lib/site-build.sh (the layout), lib/site-seal.sh (the signatures of the
# metadata) and lib/site-check.sh (what a client will see), one after the other. The stages are
# also usable alone, so that the one that parses packages need not hold the key.
#
# Usage:
#   pages-repo.sh --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]...
#
# Required:
#   --packages DIR          every .deb and .rpm the site publishes (searched recursively); any
#                           other file, or a symbolic link, is an error
#   --out DIR               the site directory to create; it must not exist
#   --base-url URL          where OUT is served: https://... or file:///..., letters, digits and . _ ~ : / % + @ = , - only
#   --version VERSION       the release; a package of it must be among the packages
#   --name NAME             base name of <name>.asc, deb/<name>.list, rpm/<name>.repo
# Optional:
#   --title TEXT            landing page title, .repo name and APT Description; one line (default "NAME package repositories")
#   --description TEXT      one line for the landing page
#   --homepage URL          project link on the landing page
#   --suite SUITE           APT suite and codename (default stable)
#   --component COMPONENT   APT component (default main)
#   --deb-architectures "A B"  Debian architectures that must each have a VERSION package built
#                           for exactly that architecture (all counts only when listed itself)
#   --rpm-architectures "A B"  the same for RPM architectures (noarch likewise)
#   --nix-archives "SYSTEM=PATH…" --nix-binaries "A B" --nix-url-base URL
#                           opt in to a hash-pinned flake of prebuilt archives
#
# Published architectures: those of the packages, plus the required ones. all/noarch packages
# are listed in every one of them; with only all/noarch packages, amd64 arm64 / x86_64 aarch64.
#   --public-key FILE       the pin; required when signing, published as <name>.asc
#   --directory-listings true|false  an index.html in every directory (default true)
#   --footer true|false     add a pkg-pages footer to the landing page and listings (default true)
#   --footer-version V      the pkg-pages version the footer names (default: version.txt beside lib/)
#   --packslip-project PROJECT  show packslip and mise install commands for this project (default off)
#   --packslip-pin PIN      optional packslip signer pin (ps1_ followed by 26 base32 characters)
#   --extra-site DIR        merged into the site root; may not overwrite a file of the site
#   --resign-history true|false  re-sign an earlier release's .rpm that doesn't verify against the
#                           pin, with a warning (default true), or fail on it (false)
#   --import-key true|false first import REPO_SIGNING_KEY into GNUPGHOME, failing closed against
#                           --public-key, as `linux-signing.sh import` does (default false)
#   --tag TAG               this release's tag. Given: the site lists its packages in
#                           pkg-pages.tsv (signed when the site is), each under its release's tag
#   --history-map FILE      which of the packages are earlier releases': lines of <tag><TAB>
#                           <sha256><TAB><path><TAB><site|release>, as fetch-history.sh --map
#                           writes them. Needs --tag. Without it every package is listed under --tag.
#   --keyring-package true|false  build the <name>-keyring .deb from the pin and publish it, so
#                           the .list uses it as the APT key (default false; signed sites with
#                           .deb files only, else a notice)
#
# Signing: the site is signed when --import-key imported a key, or when GNUPGHOME is set and
# already holds one: every .rpm (rpmsign) here, then InRelease, Release.gpg, every repomd.xml and
# pkg-pages.tsv by lib/site-seal.sh. Otherwise it is unsigned ([trusted=yes], gpgcheck=0). Whether
# a run *must* be signed is decided by the import, which fails closed (docs/signing.md).
#
# Tools: apt-ftparchive and dpkg-deb when there are .deb files; createrepo_c and rpm when there
# are .rpm files; gpg, gpgv, rpmsign and rpmkeys when signing; gzip, sed, awk, find, sha256sum.
#
# Outputs (GITHUB_OUTPUT): signed=true|false, fingerprint, site-path; and PKG_PAGES_SIGNED,
# PKG_PAGES_FINGERPRINT in GITHUB_ENV. Progress goes to stderr.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"
# The key is for signing_import alone, which reads the shell variable: no tool this script runs,
# the package readers included, gets it in its environment.
signing_key="${REPO_SIGNING_KEY-}"
unset REPO_SIGNING_KEY

usage() {
    die "usage: $0 --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]... (see the header of $0)"
}

# The options this script acts on are read into variables; the rest stay in "$@" (shifted to the
# back, one pair at a time) for site-build.sh, which checks them.
packages='' out='' base_url='' version='' name='' suite=stable component=main deb_archs='' pin=''
import_key=false resign_history=true tag='' history_map='' keyring_package=false
[ $(($# % 2)) -eq 0 ] || usage
pairs=$(($# / 2))
while [ "$pairs" -gt 0 ]; do
    opt="$1" val="$2"
    shift 2
    pairs=$((pairs - 1))
    case "$opt" in
        --packages) packages="$val" ;;
        --out) out="$val" ;;
        --base-url) base_url="${val%/}" ;;
        --version) version="$val" ;;
        --name) name="$val" ;;
        --suite) suite="$val" ;;
        --component) component="$val" ;;
        --deb-architectures) deb_archs="$val" ;;
        --public-key) pin="$val" ;;
        --import-key) import_key="$val" ;;
        --resign-history) resign_history="$val" ;;
        --tag) tag="$val" ;;
        --history-map) history_map="$val" ;;
        --keyring-package) keyring_package="$val" ;;
        --title | --description | --homepage | --rpm-architectures | --nix-archives | --nix-binaries | \
            --nix-url-base | --directory-listings | --footer | --footer-version | --packslip-project | \
            --packslip-pin | --extra-site)
            set -- "$@" "$opt" "$val"
            ;;
        *) usage ;;
    esac
done
check_bool import-key "$import_key"
check_bool resign-history "$resign_history"
check_bool keyring-package "$keyring_package"

[ -n "$packages" ] && [ -n "$out" ] && [ -n "$base_url" ] && [ -n "$version" ] && [ -n "$name" ] || usage
[ -d "$packages" ] || die "packages $packages is not a directory"
[ ! -e "$out" ] && [ ! -L "$out" ] || die "out $out already exists"
check_name name "$name"
[ -z "$history_map" ] || [ -n "$tag" ] || die "--history-map needs --tag"
[ -z "$history_map" ] || [ -f "$history_map" ] || die "history-map $history_map is not a file"
require_tools gzip sed awk find sha256sum sort

# --- Signing ---------------------------------------------------------------------------------
# --import-key: the fail-closed import of REPO_SIGNING_KEY against the pin (signing.sh), in this
# same process, so the key and the build share one GNUPGHOME and one container. Otherwise, a
# key already in GNUPGHOME signs; only an explicit GNUPGHOME counts, because on a developer's
# machine ~/.gnupg holds personal keys.
fpr=
if [ "$import_key" = true ]; then
    require_tools gpg
    [ -n "$pin" ] || die "--import-key needs --public-key"
    fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
elif [ -n "${GNUPGHOME:-}" ] && command -v gpg > /dev/null 2>&1; then
    fpr="$(secret_fpr)"
fi
signing_key=''
has_rpm_files=false has_deb_files=false
[ -z "$(find "$packages" -name '*.rpm' | head -n 1)" ] || has_rpm_files=true
[ -z "$(find "$packages" -name '*.deb' | head -n 1)" ] || has_deb_files=true
if [ -n "$fpr" ]; then
    require_tools gpg gpgv
    [ -n "$pin" ] || die "gpg holds a signing key but no public-key was given"
    [ "$(pin_fpr "$pin")" = "$fpr" ] || die "the signing key $fpr is not the key of public-key $pin"
    if [ "$has_rpm_files" = true ]; then require_tools rpmsign rpmkeys; fi
fi

work=''
make_tmpdir work

# --- A work copy, when the .rpm files are signed or the history is split off -------------------
# The caller's directory is never modified. In the copy, an earlier release's .rpm that doesn't
# verify against the pin (from before signing, or by a revoked subkey, or put on a release by
# anyone who can edit it) is re-signed with a warning, or refused (--resign-history false); this
# release's unsigned files are signed. The history map names files by the SHA-256 they had when
# fetched, so it is rewritten to the SHA-256 of the re-signed ones.
sb_packages="$packages" sb_history='' sb_map=''
need_copy=false
{ [ -n "$fpr" ] && [ "$has_rpm_files" = true ]; } && need_copy=true
[ -z "$history_map" ] || need_copy=true
if [ "$need_copy" = true ]; then
    mkdir "$work/packages"
    cp -R "$packages/." "$work/packages/"
    sb_packages="$work/packages"
    : > "$work/sha-before"   # sha256<TAB>path relative to the packages
    find "$work/packages" -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#"$work/packages/"}"
    done > "$work/sha-before"
fi
if [ -n "$fpr" ] && [ "$has_rpm_files" = true ]; then
    find "$work/packages" -type f -name '*.rpm' | LC_ALL=C sort > "$work/rpms"
    hist_db=''
    rpm_db_with_pin "$pin" hist_db
    while IFS= read -r f; do
        orig="$packages/${f#"$work/packages/"}"
        meta="$(pkg_meta "$f")"
        v="$(printf '%s' "$meta" | cut -f3)"
        if pkg_matches_version rpm "$v" "$version"; then continue; fi
        if rpm_verifies "$pin" "$f" "$hist_db"; then continue; fi
        desc="$(printf '%s' "$meta" | cut -f2-4 | tr '\t' ' ')"
        [ "$resign_history" = true ] ||
            die "$orig ($desc) is from an earlier release and not signed by public-key $pin; with resign-history false it is not re-signed"
        warning "re-signing $orig ($desc): an earlier release's .rpm that is not signed by public-key $pin"
    done < "$work/rpms"
    # Files that already verify (this release's, from sign-rpm) stay byte-identical.
    sign_files() {
        set --
        while IFS= read -r _f; do set -- "$@" "$_f"; done < "$work/rpms"
        sign_rpm "$pin" "$@"
    }
    sign_files
    : > "$work/resigned"   # old sha256<TAB>new sha256
    while IFS= read -r f; do
        old="$(awk -F'\t' -v p="${f#"$work/packages/"}" '$2 == p { print $1; exit }' "$work/sha-before")"
        new="$(sha256sum "$f" | cut -d' ' -f1)"
        [ "$old" = "$new" ] || printf '%s\t%s\n' "$old" "$new" >> "$work/resigned"
    done < "$work/rpms"
fi
if [ -n "$history_map" ]; then
    # Move the earlier releases' files out of the packages: those whose SHA-256 the map lists.
    mkdir "$work/history"
    awk -F'\t' 'NR == FNR { m[$2] = 1; next } ($1 in m) { print $2 }' "$history_map" "$work/sha-before" > "$work/history-files"
    while IFS= read -r rel; do
        mkdir -p "$work/history/${rel%/*}"
        mv "$work/packages/$rel" "$work/history/$rel"
    done < "$work/history-files"
    if [ -s "$work/resigned" ]; then
        awk -F'\t' -v OFS='\t' 'NR == FNR { m[$1] = $2; next } ($2 in m) { $2 = m[$2] } 1' "$work/resigned" "$history_map" > "$work/history-map"
    else
        cp "$history_map" "$work/history-map"
    fi
    sb_history="$work/history" sb_map="$work/history-map"
fi

# --- The keyring package ---------------------------------------------------------------------
sb_keyring=''
if [ "$keyring_package" = true ]; then
    if [ -z "$fpr" ]; then
        notice "keyring-package is true but the site is unsigned: there is no keyring to publish"
    elif [ "$has_deb_files" = false ]; then
        notice "keyring-package is true but there is no .deb: the keyring package is for APT"
    else
        GITHUB_OUTPUT='' "$lib/build-keyring.sh" --pin "$pin" --name "$name" --out "$work/keyring"
        sb_keyring="$work/keyring"
    fi
fi

# --- Build, seal, check ----------------------------------------------------------------------
# The stages write their own outputs; this script writes the ones it documents.
[ -z "$tag" ] || set -- "$@" --tag "$tag"
[ -z "$sb_history" ] || set -- "$@" --history "$sb_history" --history-map "$sb_map"
[ -z "$sb_keyring" ] || set -- "$@" --keyring "$sb_keyring"
[ -z "$fpr" ] || set -- "$@" --public-key "$pin"
GITHUB_OUTPUT='' GITHUB_ENV='' "$lib/site-build.sh" "$@" \
    --packages "$sb_packages" --out "$out" --base-url "$base_url" --version "$version" --name "$name" \
    --suite "$suite" --component "$component" --deb-architectures "$deb_archs" --to-sign "$work/to-sign"
if [ -n "$fpr" ]; then
    GITHUB_OUTPUT='' GITHUB_ENV='' "$lib/site-seal.sh" --site "$out" --to-sign "$work/to-sign" \
        --public-key "$pin" --import-key false
fi
GITHUB_OUTPUT='' GITHUB_ENV='' "$lib/site-check.sh" --site "$out" --name "$name" --version "$version" \
    --suite "$suite" --component "$component" --deb-architectures "$deb_archs" ${fpr:+--public-key "$pin"}

log "wrote $out for $name $version: ${fpr:+signed by }${fpr:-unsigned}"
set_output site-path "$out"
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

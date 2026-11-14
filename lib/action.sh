#!/bin/sh
# The run step of every composite action: validate the action's inputs, then run the matching
# lib/ script, on the runner or in a pinned container (run.sh). Keeping this out of the action.yml
# files makes it testable with bats and keeps `${{ inputs.* }}` out of every `run:` block.
#
# Usage:  action.sh build-repo | build-keyring | build-site | seal-site | check-site | sign-rpm |
#                  check-rpm | fetch-history | install-test | package-rust
#
# Inputs arrive as environment variables set by the step's `env:`, one per input, named
# INPUT_<NAME> with dashes as underscores (INPUT_PUBLIC_KEY for public-key). The secret is
# REPO_SIGNING_KEY. Paths are relative to the working directory, the caller's checkout.
# Outputs go to GITHUB_OUTPUT; see each action.yml.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"

# input NAME: the value of INPUT_NAME, or empty.
input() {
    eval "printf '%s' \"\${INPUT_$1:-}\""
}

# input_or NAME DEFAULT: the value of INPUT_NAME, or DEFAULT when it is empty.
input_or() {
    _v="$(input "$1")"
    printf '%s' "${_v:-$2}"
}

# expand_files LABEL: the newline-separated paths or globs of INPUT_PACKAGES, expanded, one file
# per line on stdout. Fails on an absolute path, '..', or a pattern that matches no file.
expand_files() {
    _patterns="$(input PACKAGES)"
    [ -n "$_patterns" ] || die "packages is empty"
    printf '%s\n' "$_patterns" | while IFS= read -r _p; do
        _p="$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$_p" ] || continue
        check_relpath packages "$_p"
        _n=0
        # Word splitting off, globbing on: a pattern may contain spaces, never several words.
        _ifs="$IFS"
        IFS=
        for _f in $_p; do
            [ -f "$_f" ] || continue
            check_relpath packages "$_f"
            printf '%s\n' "$_f"
            _n=$((_n + 1))
        done
        IFS="$_ifs"
        [ "$_n" -gt 0 ] || die "packages: '$_p' matches no file"
    done
}

# runner_mode: the runner-mode input, checked.
runner_mode() {
    _m="$(input RUNNER_MODE)"
    case "${_m:-docker}" in
        docker | host) printf '%s\n' "${_m:-docker}" ;;
        *) die "runner-mode must be docker or host, not '$_m'" ;;
    esac
}

# public_key: the public-key input, checked (a relative path; the file may be absent).
public_key() {
    _k="$(input PUBLIC_KEY)"
    _k="${_k:-packaging/signing/repo.asc}"
    check_relpath public-key "$_k"
    printf '%s\n' "$_k"
}

# with_files CMD...: run CMD with the expanded package files appended as arguments.
with_files() {
    _wf=''
    make_tmpdir _wf
    expand_files > "$_wf/list"
    while IFS= read -r _f; do
        set -- "$@" "$_f"
    done < "$_wf/list"
    "$@"
}

# default_name: the repository name, lowercased, with _ turned into -.
default_name() {
    _repo="${GITHUB_REPOSITORY:-}"
    [ -n "$_repo" ] || die "name is empty and GITHUB_REPOSITORY is not set"
    printf '%s\n' "${_repo#*/}" | tr '[:upper:]' '[:lower:]' | tr _ -
}

# default_base_url: https://<owner>.github.io/<repo> from the repository, lowercased as GitHub
# serves it; a user or organisation site (<owner>.github.io) is served at the root.
default_base_url() {
    _repo="${GITHUB_REPOSITORY:-}"
    [ -n "$_repo" ] || die "base-url is empty and GITHUB_REPOSITORY is not set"
    _owner="$(printf '%s' "${_repo%%/*}" | tr '[:upper:]' '[:lower:]')"
    _rname="${_repo#*/}"
    if [ "$(printf '%s' "$_rname" | tr '[:upper:]' '[:lower:]')" = "$_owner.github.io" ]; then
        printf 'https://%s.github.io\n' "$_owner"
    else
        printf 'https://%s.github.io/%s\n' "$_owner" "$_rname"
    fi
}

# name_input: the name input, or default_name.
name_input() {
    _n="$(input NAME)"
    [ -n "$_n" ] || _n="$(default_name)"
    printf '%s\n' "$_n"
}

# base_url_input: the base-url input, or default_base_url.
base_url_input() {
    _u="$(input BASE_URL)"
    [ -n "$_u" ] || _u="$(default_base_url)"
    printf '%s\n' "$_u"
}

# homepage_input: the homepage input, or the repository URL (empty without a repository).
homepage_input() {
    _h="$(input HOMEPAGE)"
    if [ -z "$_h" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
        _h="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
    fi
    printf '%s\n' "$_h"
}

# site_tools ARCHIVES: the tools of the site build, ARCHIVES being the nix-archives input.
site_tools() {
    _t="gpg gpgv apt-ftparchive dpkg-deb createrepo_c rpm rpmkeys"
    if [ -n "$1" ]; then
        _t="$_t tar gzip"
        case "$1" in *.tar.xz*) _t="$_t xz" ;; esac
    fi
    printf '%s\n' "$_t"
}

# cleanup_on_exit PATH...: remove each PATH when the script exits, with make_tmpdir's directories
# (they are in the working directory, so docker mode can mount them; make_tmpdir's are in /tmp).
cleanup_on_exit() {
    for _c in "$@"; do
        _cleanup_paths="$_cleanup_paths
$_c"
    done
}

# with_key CMD...: run the stage function CMD with REPO_SIGNING_KEY in the environment, and only
# for it. build_repo takes the key out of the environment first, so a stage that parses packages
# (build_site) never inherits it, and a container gets it only when run.sh is told --env for it.
with_key() {
    REPO_SIGNING_KEY="$signing_key"
    export REPO_SIGNING_KEY
    "$@"
    unset REPO_SIGNING_KEY
}

# build_repo: the site build as stages, each its own run.sh call, in <out>.work/ (removed at the
# end), so that the key is never in a container that parses packages:
#   build-keyring   the <name>-keyring .deb (no key)
#   sign-rpm        this release's .rpm files, then the history's (the key)
#   build-site      the layout, from the signed copies (no key)
#   seal-site       the signatures of the metadata (the key; reads text files only)
#   check-site      what a client will see (no key)
# Each stage is the function of the action of the same name, with its inputs set here. The
# caller's directories are never modified: the signed .rpm files are copies in <out>.work/.
build_repo() {
    runner_mode > /dev/null # fails on a bad runner-mode, before anything is made
    br_pin="$(public_key)"
    signing_key="${REPO_SIGNING_KEY-}"
    unset REPO_SIGNING_KEY

    br_packages="$(input PACKAGES)"
    check_relpath packages "$br_packages"
    [ -d "$br_packages" ] || die "packages $br_packages is not a directory"
    br_version="$(input VERSION)"
    [ -n "$br_version" ] || die "version is empty"
    br_tag="$(input TAG)"
    [ -n "$br_tag" ] || die "tag is empty: pass this release's tag, such as v1.2.3"
    br_history="$(input HISTORY)" br_history_map="$(input HISTORY_MAP)"
    if [ -n "$br_history$br_history_map" ]; then
        [ -n "$br_history" ] && [ -n "$br_history_map" ] || die "history and history-map must be set together"
        check_relpath history "$br_history"
        check_relpath history-map "$br_history_map"
        [ -d "$br_history" ] || die "history $br_history is not a directory"
        [ -f "$br_history_map" ] || die "history-map $br_history_map is not a file"
    fi
    br_out="$(input_or OUT site)"
    check_relpath out "$br_out"
    br_work="$br_out.work" br_to_sign="$br_out.to-sign"
    for _p in "$br_out" "$br_work" "$br_to_sign"; do
        [ ! -e "$_p" ] && [ ! -L "$_p" ] || die "$_p already exists"
    done

    # The stages read their inputs from INPUT_*: what the caller left empty is resolved once, here.
    br_name="$(name_input)"
    br_base_url="$(base_url_input)"
    export INPUT_NAME="$br_name" INPUT_BASE_URL="$br_base_url"
    br_keyring_package="$(input_or KEYRING_PACKAGE true)"
    check_bool keyring-package "$br_keyring_package"
    check_bool resign-history "$(input_or RESIGN_HISTORY true)"
    check_bool upload "$(input_or UPLOAD true)"
    br_extra="$(input EXTRA_SITE)"
    [ -z "$br_extra" ] || check_relpath extra-site "$br_extra"
    br_nix_archives="$(input NIX_ARCHIVES)" br_nix_binaries="$(input NIX_BINARIES)" \
        br_nix_url_base="$(input NIX_URL_BASE)"
    validate_nix_inputs "$br_nix_archives" "$br_nix_binaries" "$br_nix_url_base"

    # No pin and no key is the only unsigned build; any other combination fails before a stage runs.
    br_signed=false
    if [ -f "$br_pin" ] || [ -n "$signing_key" ]; then
        br_signed=true
        [ -f "$br_pin" ] || die "signing-key is set but public-key $br_pin does not exist (docs/signing.md#fail-closed-matrix)"
        [ -n "$signing_key" ] || die "public-key $br_pin exists but signing-key is empty (docs/signing.md#fail-closed-matrix)"
    fi

    # sign-rpm takes patterns: a path with a pattern character would match something else.
    if [ "$br_signed" = true ]; then
        case "$br_work/$(find "$br_packages" -type f -name '*.rpm')" in
            *'*'* | *'?'* | *'['* | *\\*) die "packages or out: a path holds one of * ? [ \\, which sign-rpm would read as a pattern" ;;
        esac
    fi

    mkdir "$br_work"
    cleanup_on_exit "$br_work" "$br_to_sign"
    # The stages' outputs (site-path, to-sign, signed, ...) stay in the work directory; this
    # function writes the ones build-repo documents.
    real_output="${GITHUB_OUTPUT:-}"
    GITHUB_OUTPUT="$br_work/outputs"
    export GITHUB_OUTPUT
    : > "$GITHUB_OUTPUT"

    # The keyring package, for a signed site with .deb files.
    br_keyring=''
    if [ "$br_keyring_package" = true ]; then
        br_has_deb=false
        [ -z "$(find "$br_packages" -name '*.deb' | head -n 1)" ] || br_has_deb=true
        [ -z "$br_history" ] || [ -z "$(find "$br_history" -name '*.deb' | head -n 1)" ] || br_has_deb=true
        if [ "$br_signed" = false ]; then
            notice "keyring-package is true but the site is unsigned: there is no keyring to publish"
        elif [ "$br_has_deb" = false ]; then
            notice "keyring-package is true but there is no .deb: the keyring package is for APT"
        else
            export INPUT_OUT="$br_work/keyring"
            build_keyring
            br_keyring="$br_work/keyring"
        fi
    fi

    # Signing: this release's .rpm files and the history's, in copies. An earlier release's .rpm
    # follows the current subkey when its bytes are proven; an unproven one needs resign-history.
    br_sb_packages="$br_packages" br_sb_history="$br_history" br_sb_map="$br_history_map"
    if [ "$br_signed" = true ]; then
        mkdir "$br_work/packages"
        cp -R "$br_packages/." "$br_work/packages/"
        br_sb_packages="$br_work/packages"
        br_hist_rpm=false
        if [ -n "$br_history" ]; then
            mkdir "$br_work/history"
            cp -R "$br_history/." "$br_work/history/"
            cp "$br_history_map" "$br_work/history.map"
            br_sb_history="$br_work/history" br_sb_map="$br_work/history.map"
            [ -z "$(find "$br_sb_history" -name '*.rpm' | head -n 1)" ] || br_hist_rpm=true
        fi
        br_rpms="$(find "$br_sb_packages" -type f -name '*.rpm' | LC_ALL=C sort)"
        if [ -n "$br_rpms" ] || [ "$br_hist_rpm" = true ]; then
            export INPUT_PACKAGES="$br_rpms" INPUT_HISTORY='' INPUT_HISTORY_MAP=''
            [ "$br_hist_rpm" = false ] || export INPUT_HISTORY="$br_sb_history" INPUT_HISTORY_MAP="$br_sb_map"
            with_key sign_rpm
        fi
    fi

    # The layout. It holds no key and signs nothing.
    export INPUT_PACKAGES="$br_sb_packages" INPUT_HISTORY="$br_sb_history" INPUT_HISTORY_MAP="$br_sb_map"
    export INPUT_KEYRING="$br_keyring" INPUT_OUT="$br_out"
    build_site

    br_fpr=''
    if [ "$br_signed" = true ]; then
        export INPUT_SITE="$br_out" INPUT_TO_SIGN="$br_to_sign"
        with_key seal_site
        br_fpr="$(sed -n 's/^fingerprint=//p' "$GITHUB_OUTPUT" | tail -n 1)"
    fi
    export INPUT_SITE="$br_out"
    check_site

    GITHUB_OUTPUT="$real_output"
    log "wrote $br_out for $br_name $br_version: ${br_fpr:+signed by }${br_fpr:-unsigned}"
    set_output site-path "$br_out"
    if [ "$br_signed" = true ]; then
        set_output signed true
        set_output fingerprint "$br_fpr"
        set_env PKG_PAGES_SIGNED true
        set_env PKG_PAGES_FINGERPRINT "$br_fpr"
    else
        set_output signed false
        set_output fingerprint ''
        set_env PKG_PAGES_SIGNED false
    fi
}

# validate_nix_inputs ARCHIVES BINARIES URL: enforce all-or-none and checkout-relative archive paths.
validate_nix_inputs() {
    _archives=$1 _binaries=$2 _url=$3
    [ -z "$_archives$_binaries$_url" ] && return 0
    [ -n "$_archives" ] && [ -n "$_binaries" ] && [ -n "$_url" ] ||
        die "nix-archives, nix-binaries and nix-url-base must be set together"
    while IFS= read -r _entry; do
        [ -n "$_entry" ] || continue
        case "$_entry" in *=*) _path=${_entry#*=} ;; *) die "nix-archives entries must be SYSTEM=PATH" ;; esac
        check_relpath nix-archives "$_path"
    done <<EOF
$_archives
EOF
}

build_keyring() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    name="$(name_input)"
    out="$(input_or OUT keyring)"
    check_relpath out "$out"
    "$lib/run.sh" "$mode" --image debian --tools "gpg dpkg-deb" --writes "$out" -- \
        "$lib/build-keyring.sh" --pin "$pin" --name "$name" --out "$out"
}

# build_site: lib/site-build.sh. Holds no key and signs nothing, so the container that parses
# the packages never sees one (seal_site signs, in another).
build_site() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    packages="$(input PACKAGES)"
    check_relpath packages "$packages"
    history="$(input HISTORY)" history_map="$(input HISTORY_MAP)"
    [ -z "$history$history_map" ] || {
        [ -n "$history" ] && [ -n "$history_map" ] || die "history and history-map must be set together"
        check_relpath history "$history"
        check_relpath history-map "$history_map"
    }
    keyring="$(input KEYRING)"
    [ -z "$keyring" ] || check_relpath keyring "$keyring"
    tag="$(input TAG)"
    [ -n "$tag" ] || die "tag is empty"
    version="$(input VERSION)"
    [ -n "$version" ] || die "version is empty"
    out="$(input_or OUT site)"
    check_relpath out "$out"
    name="$(name_input)"
    base_url="$(base_url_input)"
    homepage="$(homepage_input)"
    listings="$(input DIRECTORY_LISTINGS)"
    footer="$(input FOOTER)"
    extra="$(input EXTRA_SITE)"
    [ -z "$extra" ] || check_relpath extra-site "$extra"
    nix_archives="$(input NIX_ARCHIVES)" nix_binaries="$(input NIX_BINARIES)" \
        nix_url_base="$(input NIX_URL_BASE)"
    validate_nix_inputs "$nix_archives" "$nix_binaries" "$nix_url_base"

    # The list of files to sign is written beside the site, outside it, so it is never published.
    "$lib/run.sh" "$mode" --image debian --tools "$(site_tools "$nix_archives")" \
        --writes "$out" --writes "$out.to-sign" -- \
        "$lib/site-build.sh" \
        --packages "$packages" --out "$out" --to-sign "$out.to-sign" \
        --version "$version" --name "$name" --tag "$tag" \
        --base-url "$base_url" --homepage "$homepage" \
        --title "$(input TITLE)" --description "$(input DESCRIPTION)" \
        --suite "$(input_or SUITE stable)" \
        --component "$(input_or COMPONENT main)" \
        --deb-architectures "$(input DEB_ARCHITECTURES)" \
        --rpm-architectures "$(input RPM_ARCHITECTURES)" \
        --nix-archives "$nix_archives" --nix-binaries "$nix_binaries" --nix-url-base "$nix_url_base" \
        --public-key "$pin" \
        --history "$history" --history-map "$history_map" --keyring "$keyring" \
        --directory-listings "${listings:-true}" \
        --footer "${footer:-true}" \
        --footer-version "$(input FOOTER_VERSION)" \
        --packslip-project "$(input PACKSLIP_PROJECT)" \
        --packslip-pin "$(input PACKSLIP_PIN)" \
        --extra-site "$extra"
}

# seal_site: lib/site-seal.sh, the one step of the site build that holds the key. It needs only
# gpg and reads nothing but the to-sign list's text files.
seal_site() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    site="$(input SITE)"
    check_relpath site "$site"
    to_sign="$(input TO_SIGN)"
    check_relpath to-sign "$to_sign"
    "$lib/run.sh" "$mode" --image debian --tools "gpg gpgv" \
        --gnupg --env REPO_SIGNING_KEY --writes "$site" -- \
        "$lib/site-seal.sh" --site "$site" --to-sign "$to_sign" --public-key "$pin" --import-key true
}

# check_site: lib/site-check.sh, then the Pages artifact (action.yml). Needs no secret.
check_site() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    site="$(input SITE)"
    check_relpath site "$site"
    version="$(input VERSION)"
    [ -n "$version" ] || die "version is empty"
    name="$(name_input)"
    check_bool upload "$(input_or UPLOAD true)"
    # A pin that exists: the site must be signed by it. Without one the site must be unsigned.
    set -- --site "$site" --name "$name" --version "$version" \
        --suite "$(input_or SUITE stable)" \
        --component "$(input_or COMPONENT main)" \
        --deb-architectures "$(input DEB_ARCHITECTURES)"
    [ ! -f "$pin" ] || set -- "$@" --public-key "$pin"
    "$lib/run.sh" "$mode" --image debian --tools "gpg gpgv rpm rpmkeys tar gzip" --read-only -- \
        "$lib/site-check.sh" "$@"
}

sign_rpm() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    history="$(input HISTORY)" history_map="$(input HISTORY_MAP)"
    [ -z "$history$history_map" ] || {
        [ -n "$history" ] && [ -n "$history_map" ] || die "history and history-map must be set together"
        check_relpath history "$history"
        check_relpath history-map "$history_map"
    }
    resign="$(input_or RESIGN_HISTORY false)"
    check_bool resign-history "$resign"
    # packages may be empty only when there is a history to sign.
    if [ -n "$(input PACKAGES)" ] || [ -z "$history" ]; then
        lists=''
        make_tmpdir lists
        expand_files > "$lists/files"
        # run.sh arguments: --writes FILE for each file (rpmsign replaces the file, so in docker
        # mode the new one is root's and must be chowned back), then the command and the files.
        set --
        while IFS= read -r f; do set -- "$@" --writes "$f"; done < "$lists/files"
        set -- "$@" -- "$lib/linux-signing.sh" --pin "$pin" sign-rpm
        while IFS= read -r f; do set -- "$@" "$f"; done < "$lists/files"
        "$lib/run.sh" "$mode" --image fedora --tools "gpg rpmsign rpmkeys" \
            --gnupg --env REPO_SIGNING_KEY "$@"
    fi
    if [ -n "$history" ]; then
        # Earlier releases follow the current subkey: the files and the map are rewritten.
        "$lib/run.sh" "$mode" --image fedora --tools "gpg rpmsign rpmkeys" \
            --gnupg --env REPO_SIGNING_KEY --writes "$history" --writes "$history_map" -- \
            "$lib/linux-signing.sh" --pin "$pin" sign-history --map "$history_map" \
            --resign-unproven "$resign" "$history"
        set_output history-map "$history_map"
    fi
}

check_rpm() {
    mode="$(runner_mode)"
    pin="$(public_key)"
    allow="$(input ALLOW_UNSIGNED)"
    allow="${allow:-true}"
    check_bool allow-unsigned "$allow"
    if [ "$allow" = true ]; then flag=--allow-unsigned; else flag=; fi
    # shellcheck disable=SC2086 # flag is empty or one word
    with_files "$lib/run.sh" "$mode" --image fedora --tools rpmkeys --read-only -- \
        "$lib/linux-signing.sh" --pin "$pin" check-rpm $flag
}

fetch_history() {
    dir="$(input DIR)"
    check_relpath dir "$dir"
    from="$(input_or FROM releases)"
    case "$from" in
        releases | site) ;;
        *) die "from must be 'releases' or 'site', not '$from'" ;;
    esac
    map="$(input MAP)"
    [ -z "$map" ] || check_relpath map "$map"
    # Newlines or spaces between the tags; the script reads words.
    tags="$(printf '%s' "$(input TAGS)" | tr '\n' ' ')"
    # The site's address and name default as build-repo's do, so the same repository finds its own site.
    set -- --from "$from"
    if [ "$from" = site ]; then
        url="$(input URL)"
        [ -n "$url" ] || url="$(default_base_url)"
        name="$(name_input)"
        pin="$(public_key)"
        set -- "$@" --url "$url" --name "$name" --public-key "$pin"
    fi
    "$lib/fetch-history.sh" --dir "$dir" \
        --keep "$(input_or KEEP 9)" \
        --patterns "$(input_or PATTERNS '*.deb *.rpm')" \
        --exclude-tag "$(input EXCLUDE_TAG)" \
        --include-prereleases "$(input_or INCLUDE_PRERELEASES false)" \
        --repository "$(input_or REPOSITORY "${GITHUB_REPOSITORY:-}")" \
        --tags "$tags" --map "$map" "$@"
}

install_test() {
    pin="$(public_key)"
    distro="$(input DISTRO)"
    [ -n "$distro" ] || die "distro is empty"
    PKG_PAGES_SMOKE="$(input SMOKE)"
    export PKG_PAGES_SMOKE
    # --net: it installs the packages, with the package manager.
    with_files "$lib/run.sh" docker --image "$distro" --net --env PKG_PAGES_SMOKE -- \
        "$lib/install-test.sh" --pin "$pin"
}

package_rust() {
    "$lib/package-rust.sh" \
        --target "$(input TARGET)" \
        --package "$(input PACKAGE)" \
        --formats "$(input_or FORMATS 'deb rpm')" \
        --version "$(input VERSION)" \
        --out "$(input_or OUT dist)" \
        --build "$(input_or BUILD true)" \
        --cargo-deb-version "$(input_or CARGO_DEB_VERSION 3.8.0)" \
        --cargo-generate-rpm-version "$(input_or CARGO_GENERATE_RPM_VERSION 0.21.1)"
}

[ "$#" -eq 1 ] || die "usage: $0 build-repo | build-keyring | build-site | seal-site | check-site | sign-rpm | check-rpm | fetch-history | install-test | package-rust"
case "$1" in
    build-repo) build_repo ;;
    build-keyring) build_keyring ;;
    build-site) build_site ;;
    seal-site) seal_site ;;
    check-site) check_site ;;
    sign-rpm) sign_rpm ;;
    check-rpm) check_rpm ;;
    fetch-history) fetch_history ;;
    install-test) install_test ;;
    package-rust) package_rust ;;
    *) die "unknown action '$1'" ;;
esac

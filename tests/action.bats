#!/usr/bin/env bats
# lib/action.sh (the run step of every action) and the action.yml files: defaults, input
# validation, and what reaches run.sh. docker mode runs against a fake engine (see run.bats).

load helpers

setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    export GITHUB_OUTPUT="$TMP/github_output" GITHUB_ENV="$TMP/github_env"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_ENV"
    unset GITHUB_ACTIONS REPO_SIGNING_KEY GNUPGHOME
    for v in $(env | sed -n 's/^\(INPUT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
    mkdir -p "$TMP/bin" "$TMP/work"
    # The fake engine has no tools image, and records phase 1 in install.args, finding nothing
    # missing (exit 10). The command's run: one argument per line in docker.args, its environment
    # in docker.env.
    cat > "$TMP/bin/docker" << 'EOF'
#!/bin/sh
case "$1" in image) exit 1 ;; rm) exit 0 ;; esac
for a in "$@"; do
    [ "$a" = --install-only ] || continue
    printf '%s\n' "$@" > "$FAKE_LOG/install.args"
    exit 10
done
printf '%s\n' "$@" > "$FAKE_LOG/docker.args"
env > "$FAKE_LOG/docker.env"
EOF
    chmod +x "$TMP/bin/docker"
    export FAKE_LOG="$TMP" PATH="$TMP/bin:$PATH" DOCKER=docker
    export GITHUB_REPOSITORY=SkeLLLa/Star_Forge GITHUB_SERVER_URL=https://github.com
    cd "$TMP/work" || return 1
}

teardown() {
    cd /
    rm -rf "$TMP"
}

# arg_after A: the argument that follows A in the recorded docker command line.
arg_after() {
    awk -v a="$1" 'prev == a { print; exit } { prev = $0 }' "$TMP/docker.args"
}

# writes: the paths run.sh will chown back (the multi-line PKG_PAGES_WRITES value), one per line.
writes() {
    awk '$0 == "PKG_PAGES_WRITES=" { on = 1; next } on && (/^--/ || /@sha256:/) { exit } on' "$TMP/docker.args"
}

build_repo() {
    mkdir -p pkgs
    export INPUT_PACKAGES=pkgs INPUT_VERSION=1.2.3
    run "$LIB/action.sh" build-repo
}

@test "build-repo defaults: name, base-url and homepage from the repository" {
    build_repo
    assert_status 0
    [ "$(arg_after --name)" = star-forge ]
    [ "$(arg_after --base-url)" = https://skellla.github.io/Star_Forge ]
    [ "$(arg_after --homepage)" = https://github.com/SkeLLLa/Star_Forge ]
    [ "$(arg_after --out)" = site ]
    [ "$(arg_after --suite)" = stable ]
    [ "$(arg_after --component)" = main ]
    [ "$(arg_after --public-key)" = packaging/signing/repo.asc ]
    [ "$(arg_after --directory-listings)" = true ]
    [ "$(arg_after --footer)" = true ]
    [ "$(arg_after --resign-history)" = true ]
    [ "$(arg_after --import-key)" = true ]
    # No tag and no map: no manifest, and no keyring package, as before.
    [ -z "$(arg_after --tag)" ]
    [ -z "$(arg_after --history-map)" ]
    [ "$(arg_after --keyring-package)" = false ]
    [ "$(arg_after --tmpfs)" = /pkg-pages-gnupg:rw,mode=0700 ]
    grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
    [ "$(arg_after --network)" = none ]
}

@test "build-repo passes the tag, the history map and keyring-package through" {
    : > hist.map
    export INPUT_TAG=v1.2.3 INPUT_HISTORY_MAP=hist.map INPUT_KEYRING_PACKAGE=true
    build_repo
    assert_status 0
    [ "$(arg_after --tag)" = v1.2.3 ]
    [ "$(arg_after --history-map)" = hist.map ]
    [ "$(arg_after --keyring-package)" = true ]
    # The map is read, never written: only the site is handed back.
    [ "$(writes)" = site ]
}

@test "build-repo: a history map needs a tag, and the new inputs are checked" {
    export INPUT_HISTORY_MAP=hist.map
    build_repo
    assert_status 1
    assert_output_contains "history-map needs tag"
    export INPUT_TAG=v1 INPUT_HISTORY_MAP=../hist.map
    build_repo
    assert_status 1
    export INPUT_HISTORY_MAP=/tmp/hist.map
    build_repo
    assert_status 1
    unset INPUT_HISTORY_MAP
    export INPUT_KEYRING_PACKAGE=yes
    build_repo
    assert_status 1
}

@test "build-repo: a user site (<owner>.github.io) is served at the root" {
    export GITHUB_REPOSITORY=Owner/owner.github.io
    build_repo
    assert_status 0
    [ "$(arg_after --base-url)" = https://owner.github.io ]
}

@test "build-repo passes the caller's values through" {
    export INPUT_NAME=hello INPUT_BASE_URL=https://pkgs.example.com INPUT_SUITE=trixie \
        INPUT_COMPONENT=contrib INPUT_TITLE='T <x>' INPUT_DEB_ARCHITECTURES='amd64 arm64' \
        INPUT_OUT=public INPUT_RESIGN_HISTORY=false INPUT_DIRECTORY_LISTINGS=false INPUT_FOOTER=false INPUT_FOOTER_VERSION=1.2.3 \
        INPUT_PACKSLIP_PROJECT=github.com/Owner/Repo INPUT_PACKSLIP_PIN=ps1_4yd5vxao3lfzaox72lynxuotke
    build_repo
    assert_status 0
    [ "$(arg_after --name)" = hello ]
    [ "$(arg_after --base-url)" = https://pkgs.example.com ]
    [ "$(arg_after --suite)" = trixie ]
    [ "$(arg_after --title)" = 'T <x>' ]
    [ "$(arg_after --deb-architectures)" = 'amd64 arm64' ]
    [ "$(arg_after --out)" = public ]
    [ "$(arg_after --footer)" = false ]
    [ "$(arg_after --resign-history)" = false ]
    [ "$(arg_after --footer-version)" = 1.2.3 ]
    [ "$(arg_after --packslip-project)" = github.com/Owner/Repo ]
    [ "$(arg_after --packslip-pin)" = ps1_4yd5vxao3lfzaox72lynxuotke ]
    [ "$(writes)" = public ]
}

@test "build-repo validates Nix archive paths and passes the opted-in values" {
    touch archives.tar.gz
    export INPUT_NIX_ARCHIVES="x86_64-linux=archives.tar.gz" INPUT_NIX_BINARIES=bin/hello \
        INPUT_NIX_URL_BASE=https://example.test/releases
    build_repo
    assert_status 0
    [ "$(arg_after --nix-archives)" = "x86_64-linux=archives.tar.gz" ]
    [ "$(arg_after --nix-binaries)" = bin/hello ]
    [ "$(arg_after --nix-url-base)" = https://example.test/releases ]
    tools="$(sed -n 's/^PKG_PAGES_TOOLS=//p' "$TMP/install.args")"
    case " $tools " in *" gzip "*" tar "*) ;; *) false ;; esac
    grep -qxF "$TMP/work:$TMP/work" "$TMP/docker.args"
    export INPUT_NIX_ARCHIVES="x86_64-linux=../outside.tar.gz"
    build_repo
    assert_status 1
    export INPUT_NIX_ARCHIVES=x86_64-linux=archives.tar.gz INPUT_NIX_BINARIES='' INPUT_NIX_URL_BASE=''
    build_repo
    assert_status 1
}

@test "build-repo rejects unsafe paths and bad modes" {
    export INPUT_OUT=/tmp/site;   build_repo; assert_status 1
    export INPUT_OUT=../site;     build_repo; assert_status 1
    unset INPUT_OUT
    export INPUT_PUBLIC_KEY=/etc/key.asc; build_repo; assert_status 1
    unset INPUT_PUBLIC_KEY
    export INPUT_EXTRA_SITE=../docs; build_repo; assert_status 1
    unset INPUT_EXTRA_SITE
    export INPUT_RUNNER_MODE=vm;  build_repo; assert_status 1
    unset INPUT_RUNNER_MODE
    export INPUT_UPLOAD=yes;      build_repo; assert_status 1
    unset INPUT_UPLOAD
    export INPUT_VERSION=; run "$LIB/action.sh" build-repo; assert_status 1
}

@test "build-repo in host mode runs pages-repo.sh directly" {
    mkdir -p pkgs
    export INPUT_PACKAGES=pkgs INPUT_VERSION=1.2.3 INPUT_RUNNER_MODE=host
    # pages-repo.sh fails on the empty directory: proof that it ran here, not in docker.
    run "$LIB/action.sh" build-repo
    [ ! -e "$TMP/docker.args" ]
    assert_status 1
}

# tools: the tools phase 1 of the docker run installed, sorted, space-separated.
tools() {
    sed -n 's/^PKG_PAGES_TOOLS=//p' "$TMP/install.args" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
}

@test "build-keyring: name from the repository, the pin, the Debian image, no key and no network" {
    run "$LIB/action.sh" build-keyring
    assert_status 0
    [ "$(arg_after --pin)" = packaging/signing/repo.asc ]
    [ "$(arg_after --name)" = star-forge ]
    [ "$(arg_after --out)" = keyring ]
    [ "$(writes)" = keyring ]
    [ "$(tools)" = "dpkg-deb gpg" ]
    grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
    [ "$(arg_after --network)" = none ]
    refute grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    refute grep -q pkg-pages-gnupg "$TMP/docker.args"
}

@test "build-keyring passes the caller's values and rejects unsafe ones" {
    export INPUT_NAME=hello INPUT_OUT=pkgs/keyring INPUT_PUBLIC_KEY=keys/pin.asc
    run "$LIB/action.sh" build-keyring
    assert_status 0
    [ "$(arg_after --name)" = hello ]
    [ "$(arg_after --out)" = pkgs/keyring ]
    [ "$(arg_after --pin)" = keys/pin.asc ]
    export INPUT_OUT=../keyring
    run "$LIB/action.sh" build-keyring
    assert_status 1
    export INPUT_OUT=keyring INPUT_PUBLIC_KEY=/etc/pin.asc
    run "$LIB/action.sh" build-keyring
    assert_status 1
    export INPUT_PUBLIC_KEY=pin.asc INPUT_RUNNER_MODE=vm
    run "$LIB/action.sh" build-keyring
    assert_status 1
    unset GITHUB_REPOSITORY INPUT_RUNNER_MODE
    run "$LIB/action.sh" build-keyring
    assert_status 0
    unset INPUT_NAME
    run "$LIB/action.sh" build-keyring
    assert_status 1
    assert_output_contains "name is empty"
}

build_site() {
    mkdir -p pkgs
    export INPUT_PACKAGES="${INPUT_PACKAGES-pkgs}" INPUT_VERSION="${INPUT_VERSION-1.2.3}" INPUT_TAG="${INPUT_TAG-v1.2.3}"
    run "$LIB/action.sh" build-site
}

@test "build-site defaults: the repository's name and URLs, no key, the to-sign list beside the site" {
    build_site
    assert_status 0
    [ "$(arg_after --name)" = star-forge ]
    [ "$(arg_after --base-url)" = https://skellla.github.io/Star_Forge ]
    [ "$(arg_after --homepage)" = https://github.com/SkeLLLa/Star_Forge ]
    [ "$(arg_after --tag)" = v1.2.3 ]
    [ "$(arg_after --out)" = site ]
    [ "$(arg_after --to-sign)" = site.to-sign ]
    [ "$(arg_after --suite)" = stable ]
    [ "$(arg_after --component)" = main ]
    [ "$(arg_after --public-key)" = packaging/signing/repo.asc ]
    [ "$(arg_after --directory-listings)" = true ]
    [ "$(arg_after --footer)" = true ]
    [ "$(writes)" = "site
site.to-sign" ]
    # It parses the packages, so it holds no key: none in the arguments, none in the environment.
    refute grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    refute grep -q pkg-pages-gnupg "$TMP/docker.args"
    [ "$(arg_after --network)" = none ]
    # The same tools as build-repo, except the one that signs.
    [ "$(tools)" = "apt-ftparchive createrepo_c dpkg-deb gpg gpgv rpm rpmkeys" ]
    grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
}

@test "build-site passes the history, the keyring and the caller's values through" {
    mkdir -p hist kr
    : > hist.map
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map INPUT_KEYRING=kr INPUT_NAME=hello \
        INPUT_BASE_URL=https://pkgs.example.com INPUT_OUT=public INPUT_TITLE='T <x>' \
        INPUT_DEB_ARCHITECTURES='amd64 arm64' INPUT_FOOTER=false INPUT_FOOTER_VERSION=1.2.3 \
        INPUT_PACKSLIP_PROJECT=github.com/Owner/Repo INPUT_PUBLIC_KEY=keys/pin.asc
    build_site
    assert_status 0
    [ "$(arg_after --history)" = hist ]
    [ "$(arg_after --history-map)" = hist.map ]
    [ "$(arg_after --keyring)" = kr ]
    [ "$(arg_after --name)" = hello ]
    [ "$(arg_after --base-url)" = https://pkgs.example.com ]
    [ "$(arg_after --out)" = public ]
    [ "$(arg_after --to-sign)" = public.to-sign ]
    [ "$(arg_after --title)" = 'T <x>' ]
    [ "$(arg_after --deb-architectures)" = 'amd64 arm64' ]
    [ "$(arg_after --footer)" = false ]
    [ "$(arg_after --footer-version)" = 1.2.3 ]
    [ "$(arg_after --packslip-project)" = github.com/Owner/Repo ]
    [ "$(arg_after --public-key)" = keys/pin.asc ]
    [ "$(writes)" = "public
public.to-sign" ]
}

@test "build-site needs a tag and a version, takes history and history-map together, and rejects unsafe paths" {
    export INPUT_TAG=
    build_site; assert_status 1; assert_output_contains "tag is empty"
    export INPUT_TAG=v1.2.3 INPUT_VERSION=
    run "$LIB/action.sh" build-site; assert_status 1; assert_output_contains "version is empty"
    export INPUT_VERSION=1.2.3 INPUT_HISTORY=hist
    run "$LIB/action.sh" build-site; assert_status 1; assert_output_contains "together"
    export INPUT_HISTORY='' INPUT_HISTORY_MAP=hist.map
    run "$LIB/action.sh" build-site; assert_status 1; assert_output_contains "together"
    unset INPUT_HISTORY INPUT_HISTORY_MAP
    for v in INPUT_PACKAGES INPUT_OUT INPUT_KEYRING INPUT_EXTRA_SITE INPUT_PUBLIC_KEY; do
        export "$v=../x"
        build_site; assert_status 1
        export "$v=/etc/x"
        build_site; assert_status 1
        unset "$v"
    done
    export INPUT_HISTORY=../h INPUT_HISTORY_MAP=h.map
    build_site; assert_status 1
    export INPUT_HISTORY=h INPUT_HISTORY_MAP=../h.map
    build_site; assert_status 1
    unset INPUT_HISTORY INPUT_HISTORY_MAP
    export INPUT_RUNNER_MODE=vm
    build_site; assert_status 1
}

@test "build-site validates the Nix inputs as build-repo does" {
    touch archives.tar.xz
    export INPUT_NIX_ARCHIVES=x86_64-linux=archives.tar.xz INPUT_NIX_BINARIES=bin/hello \
        INPUT_NIX_URL_BASE=https://example.test/releases
    build_site
    assert_status 0
    case " $(tools) " in *" tar "*) ;; *) false ;; esac
    case " $(tools) " in *" xz "*) ;; *) false ;; esac
    export INPUT_NIX_URL_BASE=''
    build_site
    assert_status 1
}

@test "build-site in host mode runs site-build.sh directly" {
    export INPUT_RUNNER_MODE=host
    build_site
    # site-build.sh fails on the empty directory (or a missing tool): it ran here, not in docker.
    [ ! -e "$TMP/docker.args" ]
    assert_status 1
}

@test "seal-site: the key by name in a tmpfs home, the pin, only gpg, and the site marked as written" {
    mkdir site
    : > site.to-sign
    export INPUT_SITE=site INPUT_TO_SIGN=site.to-sign
    run "$LIB/action.sh" seal-site
    assert_status 0
    [ "$(arg_after --site)" = site ]
    [ "$(arg_after --to-sign)" = site.to-sign ]
    [ "$(arg_after --public-key)" = packaging/signing/repo.asc ]
    [ "$(arg_after --import-key)" = true ]
    [ "$(arg_after --tmpfs)" = /pkg-pages-gnupg:rw,mode=0700 ]
    grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    [ "$(writes)" = site ]
    [ "$(tools)" = "gpg gpgv" ]
    [ "$(arg_after --network)" = none ]
    grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
    # The key's value is never an argument.
    export REPO_SIGNING_KEY='-----BEGIN SECRET-----'
    run "$LIB/action.sh" seal-site
    assert_status 0
    refute grep -q 'BEGIN SECRET' "$TMP/docker.args"
}

@test "seal-site needs the site and the list, as checkout-relative paths" {
    export INPUT_SITE=site
    run "$LIB/action.sh" seal-site; assert_status 1
    export INPUT_SITE='' INPUT_TO_SIGN=site.to-sign
    run "$LIB/action.sh" seal-site; assert_status 1
    export INPUT_SITE=../site
    run "$LIB/action.sh" seal-site; assert_status 1
    export INPUT_SITE=site INPUT_TO_SIGN=/tmp/site.to-sign
    run "$LIB/action.sh" seal-site; assert_status 1
    export INPUT_TO_SIGN=site.to-sign INPUT_RUNNER_MODE=vm
    run "$LIB/action.sh" seal-site; assert_status 1
}

@test "check-site: no key, a read-only checkout, no network, --public-key only for a pin that exists" {
    mkdir site
    export INPUT_SITE=site INPUT_VERSION=1.2.3 INPUT_DEB_ARCHITECTURES='amd64 arm64'
    run "$LIB/action.sh" check-site
    assert_status 0
    [ "$(arg_after --site)" = site ]
    [ "$(arg_after --name)" = star-forge ]
    [ "$(arg_after --version)" = 1.2.3 ]
    [ "$(arg_after --suite)" = stable ]
    [ "$(arg_after --component)" = main ]
    [ "$(arg_after --deb-architectures)" = 'amd64 arm64' ]
    refute grep -qx -- --public-key "$TMP/docker.args"
    grep -qxF "$TMP/work:$TMP/work:ro" "$TMP/docker.args"
    refute grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    [ "$(arg_after --network)" = none ]
    case " $(tools) " in *" gpgv "*) ;; *) false ;; esac
    case " $(tools) " in *" rpmkeys "*) ;; *) false ;; esac
    : > pin.asc
    export INPUT_PUBLIC_KEY=pin.asc INPUT_NAME=hello INPUT_SUITE=trixie INPUT_COMPONENT=contrib
    run "$LIB/action.sh" check-site
    assert_status 0
    [ "$(arg_after --public-key)" = pin.asc ]
    [ "$(arg_after --name)" = hello ]
    [ "$(arg_after --suite)" = trixie ]
    [ "$(arg_after --component)" = contrib ]
}

@test "check-site validates its inputs" {
    export INPUT_SITE=site INPUT_VERSION=1.2.3
    run "$LIB/action.sh" check-site; assert_status 0
    export INPUT_VERSION=
    run "$LIB/action.sh" check-site; assert_status 1; assert_output_contains "version is empty"
    export INPUT_VERSION=1.2.3 INPUT_UPLOAD=yes
    run "$LIB/action.sh" check-site; assert_status 1
    unset INPUT_UPLOAD
    export INPUT_SITE=/tmp/site
    run "$LIB/action.sh" check-site; assert_status 1
    export INPUT_SITE=../site
    run "$LIB/action.sh" check-site; assert_status 1
    unset INPUT_SITE
    run "$LIB/action.sh" check-site; assert_status 1
    export INPUT_SITE=site INPUT_PUBLIC_KEY=../pin.asc
    run "$LIB/action.sh" check-site; assert_status 1
}

@test "sign-rpm expands globs and marks every file as written" {
    mkdir -p dist/a dist/b
    touch dist/a/x.rpm dist/b/y.rpm 'dist/b/with space.rpm'
    export INPUT_PACKAGES='dist/*/*.rpm'
    run "$LIB/action.sh" sign-rpm
    assert_status 0
    grep -qx dist/a/x.rpm "$TMP/docker.args"
    grep -qx 'dist/b/with space.rpm' "$TMP/docker.args"
    [ "$(writes)" = "dist/a/x.rpm
dist/b/with space.rpm
dist/b/y.rpm" ]
    [ "$(arg_after sign-rpm)" = dist/a/x.rpm ]
    grep -qxF "$(sed -n 's/^FEDORA_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
}

# sign_history: run sign-rpm for a history directory and its map (this release's packages: none).
sign_history() {
    mkdir -p hist
    : > hist.map
    export INPUT_HISTORY="${INPUT_HISTORY-hist}" INPUT_HISTORY_MAP="${INPUT_HISTORY_MAP-hist.map}"
    run "$LIB/action.sh" sign-rpm
}

@test "sign-rpm with a history and no packages: one run, the map and the directory marked as written" {
    sign_history
    assert_status 0
    [ "$(arg_after sign-history)" = --map ]
    [ "$(arg_after --map)" = hist.map ]
    [ "$(arg_after --resign-unproven)" = false ]
    [ "$(writes)" = "hist
hist.map" ]
    # The key by name, in a tmpfs home, as for the other files.
    grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    [ "$(arg_after --tmpfs)" = /pkg-pages-gnupg:rw,mode=0700 ]
    grep -qxF "$(sed -n 's/^FEDORA_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
    [ "$(output_value history-map)" = hist.map ]
    refute grep -qx sign-rpm "$TMP/docker.args"
}

@test "sign-rpm signs this release's files first, then the history, and resign-history passes on" {
    mkdir -p dist
    touch dist/x.rpm
    export INPUT_PACKAGES=dist/x.rpm INPUT_RESIGN_HISTORY=true
    sign_history
    assert_status 0
    # The fake engine keeps the last command line: the history run.
    [ "$(arg_after --resign-unproven)" = true ]
    [ "$(arg_after sign-history)" = --map ]
    [ "$(output_value history-map)" = hist.map ]
    export INPUT_HISTORY='' INPUT_HISTORY_MAP=''
    run "$LIB/action.sh" sign-rpm
    assert_status 0
    [ "$(arg_after sign-rpm)" = dist/x.rpm ]
}

@test "sign-rpm needs packages or a history, takes history and history-map together, and checks them" {
    run "$LIB/action.sh" sign-rpm
    assert_status 1
    assert_output_contains "packages is empty"
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=''
    sign_history; assert_status 1; assert_output_contains "together"
    export INPUT_HISTORY='' INPUT_HISTORY_MAP=hist.map
    sign_history; assert_status 1; assert_output_contains "together"
    export INPUT_HISTORY=../hist INPUT_HISTORY_MAP=hist.map
    sign_history; assert_status 1
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=/tmp/hist.map
    sign_history; assert_status 1
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map INPUT_RESIGN_HISTORY=maybe
    sign_history; assert_status 1
    [ ! -e "$TMP/docker.args" ]
}

@test "packages: several lines, blank lines ignored, each must match" {
    mkdir -p dist
    touch dist/x.rpm dist/y.rpm
    export INPUT_PACKAGES='dist/x.rpm

  dist/y.rpm  '
    run "$LIB/action.sh" check-rpm
    assert_status 0
    grep -qx dist/y.rpm "$TMP/docker.args"
    grep -qxF "$TMP/work:$TMP/work:ro" "$TMP/docker.args"
    [ "$(arg_after --network)" = none ]
    export INPUT_PACKAGES='dist/x.rpm
dist/none-*.rpm'
    run "$LIB/action.sh" check-rpm
    assert_status 1
    assert_output_contains "matches no file"
}

@test "packages may not escape the checkout" {
    for p in /etc/passwd '../*.rpm' 'dist/../../x.rpm'; do
        export INPUT_PACKAGES="$p"
        run "$LIB/action.sh" check-rpm
        assert_status 1
    done
}

@test "packages globs that expand outside the checkout are refused" {
    touch "$TMP/x.rpm"
    export INPUT_PACKAGES='.*/x.rpm'
    run "$LIB/action.sh" sign-rpm
    assert_status 1
    [ ! -e "$TMP/docker.args" ]
}

@test "check-rpm: allow-unsigned true (default) passes --allow-unsigned, false doesn't" {
    touch x.rpm
    export INPUT_PACKAGES=x.rpm
    run "$LIB/action.sh" check-rpm
    assert_status 0
    grep -qx -- --allow-unsigned "$TMP/docker.args"
    export INPUT_ALLOW_UNSIGNED=false
    run "$LIB/action.sh" check-rpm
    refute grep -qx -- --allow-unsigned "$TMP/docker.args"
    export INPUT_ALLOW_UNSIGNED=maybe
    run "$LIB/action.sh" check-rpm
    assert_status 1
}

# fetch_args: run `action.sh fetch-history` against a copy of lib/ whose fetch-history.sh only
# records its arguments, one per line, in fetch.args.
fetch_args() {
    rm -rf "${TMP:?}/lib"
    cp -R "$LIB" "$TMP/lib"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_LOG/fetch.args"\n' > "$TMP/lib/fetch-history.sh"
    export INPUT_DIR="${INPUT_DIR-hist}"
    run "$TMP/lib/action.sh" fetch-history
}

# fetch_arg_after A: the argument that follows A in the recorded fetch-history.sh arguments.
fetch_arg_after() {
    awk -v a="$1" 'prev == a { print; exit } { prev = $0 }' "$TMP/fetch.args"
}

@test "fetch-history defaults: releases, as before, with no site arguments" {
    fetch_args
    assert_status 0
    [ "$(fetch_arg_after --dir)" = hist ]
    [ "$(fetch_arg_after --from)" = releases ]
    [ "$(fetch_arg_after --keep)" = 9 ]
    [ "$(fetch_arg_after --patterns)" = '*.deb *.rpm' ]
    [ "$(fetch_arg_after --repository)" = SkeLLLa/Star_Forge ]
    [ "$(fetch_arg_after --include-prereleases)" = false ]
    [ -z "$(fetch_arg_after --tags)" ]
    [ -z "$(fetch_arg_after --map)" ]
    for a in --url --name --public-key; do
        refute grep -qx -- "$a" "$TMP/fetch.args"
    done
}

@test "fetch-history from the site: url, name and pin default as build-repo's do" {
    export INPUT_FROM=site INPUT_TAGS='v1.0.0
v0.9.0' INPUT_MAP=hist.map
    fetch_args
    assert_status 0
    [ "$(fetch_arg_after --from)" = site ]
    [ "$(fetch_arg_after --url)" = https://skellla.github.io/Star_Forge ]
    [ "$(fetch_arg_after --name)" = star-forge ]
    [ "$(fetch_arg_after --public-key)" = packaging/signing/repo.asc ]
    [ "$(fetch_arg_after --tags)" = 'v1.0.0 v0.9.0' ]
    [ "$(fetch_arg_after --map)" = hist.map ]
    export GITHUB_REPOSITORY=Owner/owner.github.io
    fetch_args
    [ "$(fetch_arg_after --url)" = https://owner.github.io ]
    export INPUT_URL=file:///srv/site INPUT_NAME=hello INPUT_PUBLIC_KEY=keys/pin.asc
    fetch_args
    [ "$(fetch_arg_after --url)" = file:///srv/site ]
    [ "$(fetch_arg_after --name)" = hello ]
    [ "$(fetch_arg_after --public-key)" = keys/pin.asc ]
    # With the address and the name given, no repository is needed.
    unset GITHUB_REPOSITORY
    fetch_args
    assert_status 0
    unset INPUT_URL
    fetch_args
    assert_status 1
    assert_output_contains "base-url is empty"
}

@test "fetch-history rejects a bad source and paths that leave the checkout" {
    export INPUT_FROM=ftp
    fetch_args; assert_status 1; assert_output_contains "from must be"
    export INPUT_FROM=releases INPUT_MAP=../hist.map
    fetch_args; assert_status 1
    export INPUT_MAP=/tmp/hist.map
    fetch_args; assert_status 1
    unset INPUT_MAP
    export INPUT_DIR=../hist
    fetch_args; assert_status 1
    export INPUT_FROM=site INPUT_DIR=hist INPUT_PUBLIC_KEY=/etc/pin.asc
    fetch_args; assert_status 1
}

@test "install-test: the distro image, the network, and the smoke command by environment, not argv" {
    touch x.deb
    export INPUT_PACKAGES=x.deb INPUT_DISTRO=ubuntu INPUT_SMOKE='hello --version; echo ok'
    run "$LIB/action.sh" install-test
    assert_status 0
    grep -qxF "$(sed -n 's/^UBUNTU_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
    # It installs packages: the default network and capabilities, and a writable root.
    refute grep -qxE -- '--network|--cap-drop|--read-only' "$TMP/docker.args"
    grep -qx PKG_PAGES_SMOKE "$TMP/docker.args"
    refute grep -q 'hello --version' "$TMP/docker.args"
    grep -q '^PKG_PAGES_SMOKE=hello --version; echo ok$' "$TMP/docker.env"
    export INPUT_DISTRO=archlinux
    run "$LIB/action.sh" install-test
    assert_status 1
}

@test "unknown actions are refused" {
    run "$LIB/action.sh" deploy
    assert_status 1
    run "$LIB/action.sh"
    assert_status 1
}

# --- The action.yml files --------------------------------------------------------------------

# inputs FILE: the input names declared in an action.yml.
inputs() {
    awk '/^inputs:/ { on = 1; next } /^[a-z]/ { on = 0 } on && /^  [a-z][a-z-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$1"
}

@test "every input of every action reaches its run step through env:" {
    # Inputs used by `with:` or `working-directory:` rather than by lib/action.sh.
    skip_inputs=" signing-key token artifact-name retention-days working-directory "
    for f in "$ROOT"/action.yml "$ROOT"/*/action.yml; do
        for i in $(inputs "$f"); do
            case "$skip_inputs" in *" $i "*) continue ;; esac
            var="INPUT_$(echo "$i" | tr a-z- A-Z_)"
            grep -qF "$var: \${{ inputs.$i }}" "$f" || { echo "$f: input $i is not passed as $var"; false; }
        done
    done
}

@test "no action interpolates an expression into run:" {
    for f in "$ROOT"/action.yml "$ROOT"/*/action.yml; do
        refute grep -nE '^ +run: .*\$\{\{' "$f"
    done
}

@test "the secret inputs reach the scripts only as REPO_SIGNING_KEY and GH_TOKEN" {
    grep -qF 'REPO_SIGNING_KEY: ${{ inputs.signing-key }}' "$ROOT/action.yml"
    grep -qF 'REPO_SIGNING_KEY: ${{ inputs.signing-key }}' "$ROOT/sign-rpm/action.yml"
    grep -qF 'REPO_SIGNING_KEY: ${{ inputs.signing-key }}' "$ROOT/seal-site/action.yml"
    # Only the two actions that sign take the key.
    for d in build-keyring build-site check-site check-rpm fetch-history install-test package-rust; do
        refute grep -q 'signing-key' "$ROOT/$d/action.yml"
    done
    grep -qF 'GH_TOKEN: ${{ inputs.token }}' "$ROOT/fetch-history/action.yml"
}

@test "every action.yml calls lib/action.sh with its own name" {
    grep -qF '"$GITHUB_ACTION_PATH/lib/action.sh" build-repo' "$ROOT/action.yml"
    for d in build-keyring build-site seal-site check-site sign-rpm check-rpm fetch-history install-test package-rust; do
        grep -qF "\"\$GITHUB_ACTION_PATH/../lib/action.sh\" $d" "$ROOT/$d/action.yml"
    done
}

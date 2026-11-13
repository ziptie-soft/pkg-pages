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
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_LOG/docker.args"\nenv > "$FAKE_LOG/docker.env"\n' > "$TMP/bin/docker"
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
    [ "$(arg_after --import-key)" = true ]
    [ "$(arg_after --tmpfs)" = /pkg-pages-gnupg:rw,mode=0700 ]
    grep -qx REPO_SIGNING_KEY "$TMP/docker.args"
    grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
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
        INPUT_OUT=public INPUT_DIRECTORY_LISTINGS=false INPUT_FOOTER=false INPUT_FOOTER_VERSION=1.2.3 \
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
    grep -Eq '^PKG_PAGES_TOOLS=.*tar gzip$' "$TMP/docker.args"
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

@test "packages: several lines, blank lines ignored, each must match" {
    mkdir -p dist
    touch dist/x.rpm dist/y.rpm
    export INPUT_PACKAGES='dist/x.rpm

  dist/y.rpm  '
    run "$LIB/action.sh" check-rpm
    assert_status 0
    grep -qx dist/y.rpm "$TMP/docker.args"
    grep -qxF "$TMP/work:$TMP/work:ro" "$TMP/docker.args"
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

@test "install-test: the distro image, and the smoke command by environment, not argv" {
    touch x.deb
    export INPUT_PACKAGES=x.deb INPUT_DISTRO=ubuntu INPUT_SMOKE='hello --version; echo ok'
    run "$LIB/action.sh" install-test
    assert_status 0
    grep -qxF "$(sed -n 's/^UBUNTU_IMAGE=//p' "$ROOT/images.env")" "$TMP/docker.args"
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
    grep -qF 'GH_TOKEN: ${{ inputs.token }}' "$ROOT/fetch-history/action.yml"
}

@test "every action.yml calls lib/action.sh with its own name" {
    grep -qF '"$GITHUB_ACTION_PATH/lib/action.sh" build-repo' "$ROOT/action.yml"
    for d in sign-rpm check-rpm fetch-history install-test package-rust; do
        grep -qF "\"\$GITHUB_ACTION_PATH/../lib/action.sh\" $d" "$ROOT/$d/action.yml"
    done
}

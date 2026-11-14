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
    # in docker.env. These are the last call's; call.N.args, call.N.env and install.N.args keep
    # every call (one run.sh call is one install and one run), for the staged build-repo.
    cat > "$TMP/bin/docker" << 'EOF'
#!/bin/sh
case "$1" in image) exit 1 ;; rm) exit 0 ;; esac
for a in "$@"; do
    [ "$a" = --install-only ] || continue
    n=$(($(cat "$FAKE_LOG/installs" 2> /dev/null || echo 0) + 1))
    echo "$n" > "$FAKE_LOG/installs"
    printf '%s\n' "$@" > "$FAKE_LOG/install.args"
    cp "$FAKE_LOG/install.args" "$FAKE_LOG/install.$n.args"
    exit 10
done
n=$(($(cat "$FAKE_LOG/calls" 2> /dev/null || echo 0) + 1))
echo "$n" > "$FAKE_LOG/calls"
printf '%s\n' "$@" > "$FAKE_LOG/docker.args"
env > "$FAKE_LOG/docker.env"
cp "$FAKE_LOG/docker.args" "$FAKE_LOG/call.$n.args"
cp "$FAKE_LOG/docker.env" "$FAKE_LOG/call.$n.env"
EOF
    chmod +x "$TMP/bin/docker"
    export FAKE_LOG="$TMP" PATH="$TMP/bin:$PATH" DOCKER=docker
    export GITHUB_REPOSITORY=SkeLLLa/Star_Forge GITHUB_SERVER_URL=https://github.com
    cd "$TMP/work" || return 1
}

teardown() {
    cd /
    kill_agents "$TMP"
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

# --- build-repo: the stages --------------------------------------------------------------------
# The fake engine keeps every call (call.N.args, call.N.env, install.N.args), one per stage.

# stages: the stages that ran, in order, one word each (the lib script; for linux-signing.sh the
# command), space-separated.
stages() {
    _n=1
    _seq=
    while [ -f "$TMP/call.$_n.args" ]; do
        _s="$(sed -n "s|^$LIB/\\([a-z-]*\\)\\.sh\$|\\1|p" "$TMP/call.$_n.args" | grep -vx in-container)"
        [ "$_s" != linux-signing ] || _s="$(grep -xE 'sign-rpm|sign-history' "$TMP/call.$_n.args")"
        _seq="$_seq $_s"
        _n=$((_n + 1))
    done
    printf '%s\n' "${_seq# }"
}

# carg N A: the argument that follows A in the command line of call N.
carg() {
    awk -v a="$2" 'prev == a { print; exit } { prev = $0 }' "$TMP/call.$1.args"
}

# cwrites N: the paths call N hands back to the calling user, one per line.
cwrites() {
    awk '$0 == "PKG_PAGES_WRITES=" { on = 1; next } on && (/^--/ || /@sha256:/) { exit } on' "$TMP/call.$1.args"
}

# ctools N: the tools call N installed, sorted, space-separated.
ctools() {
    sed -n 's/^PKG_PAGES_TOOLS=//p' "$TMP/install.$1.args" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
}

# has_key N: call N was given the key (by name, in a tmpfs home), and nothing else was.
has_key() {
    grep -qx REPO_SIGNING_KEY "$TMP/call.$1.args" &&
        grep -qx '/pkg-pages-gnupg:rw,mode=0700' "$TMP/call.$1.args" &&
        grep -qx 'REPO_SIGNING_KEY=-----BEGIN SECRET-----' "$TMP/call.$1.env"
}

# no_key N: call N has no key: not in its arguments, its environment or a gpg home.
no_key() {
    refute grep -qx REPO_SIGNING_KEY "$TMP/call.$1.args"
    refute grep -q pkg-pages-gnupg "$TMP/call.$1.args"
    refute grep -q '^REPO_SIGNING_KEY=' "$TMP/call.$1.env"
}

build_repo() {
    mkdir -p pkgs
    export INPUT_PACKAGES="${INPUT_PACKAGES-pkgs}" INPUT_VERSION="${INPUT_VERSION-1.2.3}" \
        INPUT_TAG="${INPUT_TAG-v1.2.3}"
    run "$LIB/action.sh" build-repo
}

# signed_inputs: a pin, a key, this release's packages and a history, as a caller's checkout has them.
signed_inputs() {
    mkdir -p packaging/signing pkgs hist
    : > packaging/signing/repo.asc
    touch pkgs/a.deb pkgs/b.rpm hist/old.rpm hist/old.deb
    : > hist.map
    export REPO_SIGNING_KEY='-----BEGIN SECRET-----' INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map
}

@test "build-repo defaults: an unsigned site is the layout and its check, with the repository's name and URLs" {
    mkdir -p pkgs
    touch pkgs/a.deb pkgs/b.rpm
    build_repo
    assert_status 0
    [ "$(stages)" = "site-build site-check" ]
    # keyring-package is on by default, and an unsigned site has no key to publish.
    assert_output_contains "keyring-package is true but the site is unsigned"
    [ "$(carg 1 --packages)" = pkgs ]
    [ "$(carg 1 --name)" = star-forge ]
    [ "$(carg 1 --base-url)" = https://skellla.github.io/Star_Forge ]
    [ "$(carg 1 --homepage)" = https://github.com/SkeLLLa/Star_Forge ]
    [ "$(carg 1 --out)" = site ]
    [ "$(carg 1 --to-sign)" = site.to-sign ]
    [ "$(carg 1 --tag)" = v1.2.3 ]
    [ "$(carg 1 --version)" = 1.2.3 ]
    [ "$(carg 1 --suite)" = stable ]
    [ "$(carg 1 --component)" = main ]
    [ "$(carg 1 --public-key)" = packaging/signing/repo.asc ]
    [ "$(carg 1 --directory-listings)" = true ]
    [ "$(carg 1 --footer)" = true ]
    [ -z "$(carg 1 --history)" ]
    [ -z "$(carg 1 --keyring)" ]
    [ "$(cwrites 1)" = "site
site.to-sign" ]
    [ "$(carg 2 --site)" = site ]
    [ "$(carg 2 --name)" = star-forge ]
    [ "$(carg 2 --version)" = 1.2.3 ]
    refute grep -qx -- --public-key "$TMP/call.2.args"
    for n in 1 2; do
        no_key "$n"
        grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/call.$n.args"
        [ "$(carg "$n" --network)" = none ]
    done
    # The work directory and the to-sign list are gone, and the outputs are build-repo's own.
    [ ! -e site.work ]
    [ ! -e site.to-sign ]
    [ "$(output_value site-path)" = site ]
    [ "$(output_value signed)" = false ]
    [ -z "$(output_value fingerprint)" ]
    [ -z "$(output_value to-sign)" ]
    grep -qx PKG_PAGES_SIGNED=false "$GITHUB_ENV"
}

@test "build-repo, signed: build-keyring, sign-rpm, sign-history, build-site, seal-site, check-site, each its own call" {
    signed_inputs
    export INPUT_RESIGN_HISTORY=true
    build_repo
    assert_status 0
    # keyring-package is not set: the default builds the keyring.
    [ "$(stages)" = "build-keyring sign-rpm sign-history site-build site-seal site-check" ]
    # The key reaches the two signing stages and the seal, and none of the three that parse packages.
    for n in 2 3 5; do has_key "$n"; done
    for n in 1 4 6; do no_key "$n"; done
    refute grep -q 'BEGIN SECRET' "$TMP"/call.*.args
    # The tools: nothing that signs where packages are parsed.
    [ "$(ctools 1)" = "dpkg-deb gpg" ]
    [ "$(ctools 2)" = "gpg rpmkeys rpmsign" ]
    [ "$(ctools 3)" = "gpg rpmkeys rpmsign" ]
    [ "$(ctools 4)" = "apt-ftparchive createrepo_c dpkg-deb gpg gpgv rpm rpmkeys" ]
    [ "$(ctools 5)" = "gpg gpgv" ]
    [ "$(ctools 6)" = "gpg gpgv gzip rpm rpmkeys tar" ]
    for n in 2 3; do grep -qxF "$(sed -n 's/^FEDORA_IMAGE=//p' "$ROOT/images.env")" "$TMP/call.$n.args"; done
    for n in 1 4 5 6; do grep -qxF "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" "$TMP/call.$n.args"; done
    # The keyring is built into the work directory; the .rpm files and the history are signed there.
    [ "$(carg 1 --out)" = site.work/keyring ]
    [ "$(cwrites 1)" = site.work/keyring ]
    [ "$(carg 2 sign-rpm)" = site.work/packages/b.rpm ]
    [ "$(cwrites 2)" = site.work/packages/b.rpm ]
    [ "$(carg 3 --map)" = site.work/history.map ]
    [ "$(carg 3 --resign-unproven)" = true ]
    [ "$(cwrites 3)" = "site.work/history
site.work/history.map" ]
    [ "$(carg 4 --packages)" = site.work/packages ]
    [ "$(carg 4 --history)" = site.work/history ]
    [ "$(carg 4 --history-map)" = site.work/history.map ]
    [ "$(carg 4 --keyring)" = site.work/keyring ]
    [ "$(carg 4 --public-key)" = packaging/signing/repo.asc ]
    [ "$(carg 4 --out)" = site ]
    [ "$(carg 4 --to-sign)" = site.to-sign ]
    [ "$(carg 5 --site)" = site ]
    [ "$(carg 5 --to-sign)" = site.to-sign ]
    [ "$(carg 5 --public-key)" = packaging/signing/repo.asc ]
    [ "$(cwrites 5)" = site ]
    [ "$(carg 6 --public-key)" = packaging/signing/repo.asc ]
    [ "$(carg 6 --site)" = site ]
    grep -qxF "$TMP/work:$TMP/work:ro" "$TMP/call.6.args"
    [ ! -e site.work ]
    [ ! -e site.to-sign ]
    [ "$(output_value signed)" = true ]
    [ "$(output_value site-path)" = site ]
    grep -qx PKG_PAGES_SIGNED=true "$GITHUB_ENV"
}

# reset_calls: forget the calls the fake engine recorded.
reset_calls() {
    rm -f "$TMP"/call.* "$TMP"/install.* "$TMP/installs" "$TMP/calls" "$TMP/docker.args" "$TMP/docker.env"
}

@test "build-repo, signed: keyring-package false opts out of the keyring, and with it of the stage" {
    signed_inputs
    export INPUT_KEYRING_PACKAGE=false
    build_repo
    assert_status 0
    [ "$(stages)" = "sign-rpm sign-history site-build site-seal site-check" ]
    [ -z "$(carg 3 --keyring)" ]
    refute grep -q 'keyring' <<< "$output"
}

@test "build-repo, signed: a stage with nothing to do is left out" {
    signed_inputs
    # Only .deb files: nothing for rpmsign, in this release or the history.
    rm pkgs/b.rpm hist/old.rpm
    build_repo
    assert_status 0
    [ "$(stages)" = "build-keyring site-build site-seal site-check" ]
    # Only .rpm files: no keyring package (a notice), and the history is signed.
    reset_calls
    rm -rf pkgs hist
    mkdir pkgs hist
    touch pkgs/b.rpm hist/old.rpm
    build_repo
    assert_status 0
    [ "$(stages)" = "sign-rpm sign-history site-build site-seal site-check" ]
    assert_output_contains "there is no .deb"
    # No history: nothing is passed on to sign-rpm and build-site.
    reset_calls
    unset INPUT_HISTORY INPUT_HISTORY_MAP
    build_repo
    assert_status 0
    [ "$(stages)" = "sign-rpm site-build site-seal site-check" ]
    [ -z "$(carg 4 --history)" ]
    # A history without .rpm files has nothing to sign either.
    reset_calls
    rm -rf hist
    mkdir hist
    touch hist/old.deb
    INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map build_repo
    assert_status 0
    [ "$(stages)" = "build-keyring sign-rpm site-build site-seal site-check" ]
    [ "$(carg 3 --history)" = site.work/history ]
}

@test "build-repo, unsigned: no signing stage, the caller's directories as they are, and a notice about the keyring" {
    mkdir -p pkgs hist
    touch pkgs/a.deb pkgs/b.rpm hist/old.rpm
    : > hist.map
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map INPUT_RESIGN_HISTORY=true
    build_repo
    assert_status 0
    [ "$(stages)" = "site-build site-check" ]
    [ "$(carg 1 --packages)" = pkgs ]
    [ "$(carg 1 --history)" = hist ]
    [ "$(carg 1 --history-map)" = hist.map ]
    assert_output_contains "the site is unsigned"
    [ "$(output_value signed)" = false ]
}

@test "build-repo fails closed before any stage: a pin without a key, a key without a pin" {
    signed_inputs
    unset REPO_SIGNING_KEY
    build_repo
    assert_status 1
    assert_output_contains "signing-key is empty"
    rm packaging/signing/repo.asc
    export REPO_SIGNING_KEY='-----BEGIN SECRET-----'
    build_repo
    assert_status 1
    assert_output_contains "public-key packaging/signing/repo.asc does not exist"
    [ ! -e "$TMP/docker.args" ]
    [ ! -e site.work ]
    refute grep -q 'BEGIN SECRET' <<< "$output"
}

@test "build-repo needs a tag, and history with history-map; a map or a history that isn't there is an error" {
    export INPUT_TAG=
    build_repo
    assert_status 1
    assert_output_contains "tag is empty"
    export INPUT_TAG=v1 INPUT_HISTORY=hist
    build_repo
    assert_status 1
    assert_output_contains "together"
    export INPUT_HISTORY='' INPUT_HISTORY_MAP=hist.map
    build_repo
    assert_status 1
    assert_output_contains "together"
    export INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map
    build_repo
    assert_status 1
    assert_output_contains "history hist is not a directory"
    mkdir hist
    build_repo
    assert_status 1
    assert_output_contains "history-map hist.map is not a file"
    : > hist.map
    build_repo
    assert_status 0
    for bad in ../hist /tmp/hist; do
        export INPUT_HISTORY="$bad"
        build_repo
        assert_status 1
    done
    export INPUT_HISTORY=hist
    for bad in ../hist.map /tmp/hist.map; do
        export INPUT_HISTORY_MAP="$bad"
        build_repo
        assert_status 1
    done
    export INPUT_HISTORY_MAP=hist.map INPUT_KEYRING_PACKAGE=yes
    build_repo
    assert_status 1
    export INPUT_KEYRING_PACKAGE=true INPUT_RESIGN_HISTORY=maybe
    build_repo
    assert_status 1
}

@test "build-repo: packages is a directory, out and its work directory don't exist yet" {
    export INPUT_PACKAGES=nowhere
    build_repo
    assert_status 1
    assert_output_contains "packages nowhere is not a directory"
    unset INPUT_PACKAGES
    mkdir site
    build_repo
    assert_status 1
    assert_output_contains "site already exists"
    rmdir site
    mkdir site.work
    build_repo
    assert_status 1
    assert_output_contains "site.work already exists"
    rmdir site.work
    : > site.to-sign
    build_repo
    assert_status 1
    assert_output_contains "site.to-sign already exists"
    # What was there before is left alone.
    [ -f site.to-sign ]
    [ ! -e "$TMP/docker.args" ]
}

@test "build-repo: a name that sign-rpm would read as a pattern is refused" {
    signed_inputs
    touch 'pkgs/c[1].rpm'
    build_repo
    assert_status 1
    assert_output_contains "pattern"
    [ ! -e "$TMP/docker.args" ]
    [ ! -e site.work ]
}

@test "build-repo: a user site (<owner>.github.io) is served at the root" {
    export GITHUB_REPOSITORY=Owner/owner.github.io
    build_repo
    assert_status 0
    [ "$(carg 1 --base-url)" = https://owner.github.io ]
    [ "$(carg 1 --name)" = owner.github.io ]
}

@test "build-repo passes the caller's values through to the stages" {
    signed_inputs
    export INPUT_NAME=hello INPUT_BASE_URL=https://pkgs.example.com INPUT_SUITE=trixie \
        INPUT_COMPONENT=contrib INPUT_TITLE='T <x>' INPUT_DEB_ARCHITECTURES='amd64 arm64' \
        INPUT_OUT=public INPUT_RESIGN_HISTORY=false INPUT_DIRECTORY_LISTINGS=false INPUT_FOOTER=false INPUT_FOOTER_VERSION=1.2.3 \
        INPUT_PACKSLIP_PROJECT=github.com/Owner/Repo INPUT_PACKSLIP_PIN=ps1_4yd5vxao3lfzaox72lynxuotke \
        INPUT_PUBLIC_KEY=packaging/signing/repo.asc INPUT_KEYRING_PACKAGE=true
    build_repo
    assert_status 0
    [ "$(stages)" = "build-keyring sign-rpm sign-history site-build site-seal site-check" ]
    [ "$(carg 1 --name)" = hello ]
    [ "$(carg 1 --out)" = public.work/keyring ]
    [ "$(carg 3 --resign-unproven)" = false ]
    [ "$(carg 3 --map)" = public.work/history.map ]
    [ "$(carg 4 --name)" = hello ]
    [ "$(carg 4 --base-url)" = https://pkgs.example.com ]
    [ "$(carg 4 --suite)" = trixie ]
    [ "$(carg 4 --component)" = contrib ]
    [ "$(carg 4 --title)" = 'T <x>' ]
    [ "$(carg 4 --deb-architectures)" = 'amd64 arm64' ]
    [ "$(carg 4 --out)" = public ]
    [ "$(carg 4 --to-sign)" = public.to-sign ]
    [ "$(carg 4 --footer)" = false ]
    [ "$(carg 4 --directory-listings)" = false ]
    [ "$(carg 4 --footer-version)" = 1.2.3 ]
    [ "$(carg 4 --packslip-project)" = github.com/Owner/Repo ]
    [ "$(carg 4 --packslip-pin)" = ps1_4yd5vxao3lfzaox72lynxuotke ]
    [ "$(carg 5 --site)" = public ]
    [ "$(carg 6 --name)" = hello ]
    [ "$(carg 6 --suite)" = trixie ]
    [ "$(carg 6 --component)" = contrib ]
    [ "$(carg 6 --deb-architectures)" = 'amd64 arm64' ]
    [ "$(output_value site-path)" = public ]
    [ ! -e public.work ]
    [ ! -e public.to-sign ]
}

@test "build-repo validates Nix archive paths and passes the opted-in values to build-site" {
    touch archives.tar.gz
    export INPUT_NIX_ARCHIVES="x86_64-linux=archives.tar.gz" INPUT_NIX_BINARIES=bin/hello \
        INPUT_NIX_URL_BASE=https://example.test/releases
    build_repo
    assert_status 0
    [ "$(carg 1 --nix-archives)" = "x86_64-linux=archives.tar.gz" ]
    [ "$(carg 1 --nix-binaries)" = bin/hello ]
    [ "$(carg 1 --nix-url-base)" = https://example.test/releases ]
    case " $(ctools 1) " in *" gzip "*" tar "*) ;; *) false ;; esac
    grep -qxF "$TMP/work:$TMP/work" "$TMP/call.1.args"
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
    [ ! -e "$TMP/docker.args" ]
}

@test "build-repo in host mode runs the stages here, and still cleans up" {
    mkdir -p pkgs
    export INPUT_PACKAGES=pkgs INPUT_VERSION=1.2.3 INPUT_TAG=v1.2.3 INPUT_RUNNER_MODE=host
    # site-build.sh fails on the empty directory (or a missing tool): proof that it ran here, not in docker.
    run "$LIB/action.sh" build-repo
    [ ! -e "$TMP/docker.args" ]
    assert_status 1
    [ ! -e site.work ]
    [ ! -e site.to-sign ]
}

# --- build-repo, host mode, with the real tools ----------------------------------------------
# What the stage tests above can't show: the stages work together, on real packages and a real key.
# Skipped without the tools; tests/container.sh debian runs them.

# real_inputs: a project key, this release's packages (hello 1.2.3) and an earlier release's
# (hello 1.2.2, unsigned) in a checkout, and the inputs of a host-mode run.
real_inputs() {
    need gpg gpgv dpkg-deb apt-ftparchive createrepo_c rpm rpmbuild rpmsign rpmkeys gzip tar
    "$FIXTURES" key "$TMP/key" "project a"
    mkdir -p packaging/signing
    cp "$TMP/key/pin.asc" packaging/signing/repo.asc
    "$FIXTURES" deb pkgs hello 1.2.3-1 amd64
    "$FIXTURES" rpm pkgs hello 1.2.3 x86_64
    "$FIXTURES" deb hist hello 1.2.2-1 amd64
    "$FIXTURES" rpm hist hello 1.2.2 x86_64
    export INPUT_RUNNER_MODE=host INPUT_PACKAGES=pkgs INPUT_VERSION=1.2.3 INPUT_TAG=v1.2.3 \
        INPUT_NAME=hello INPUT_BASE_URL="file://$TMP/work/site" \
        INPUT_HISTORY=hist INPUT_HISTORY_MAP=hist.map
}

# write_map SOURCE: the history map of hist/: every file is release v1.2.2's, from SOURCE (site|release).
write_map() {
    : > hist.map
    for f in hist/*; do
        printf 'v1.2.2\t%s\t%s\t%s\n' "$(sha "$f")" "${f#hist/}" "$1" >> hist.map
    done
}

# with_secret: hand the project's signing subkey to the action, as a workflow's secret.
with_secret() {
    REPO_SIGNING_KEY="$(cat "$TMP/key/ci.asc")"
    export REPO_SIGNING_KEY
}

# spy TOOL...: put a wrapper in front of each TOOL that records the environment it ran in.
spy() {
    mkdir -p "$TMP/spy"
    for t in "$@"; do
        printf '#!/bin/sh\nenv >> "%s/spy.env"\nexec "%s" "$@"\n' "$TMP" "$(command -v "$t")" > "$TMP/spy/$t"
        chmod +x "$TMP/spy/$t"
    done
    export PATH="$TMP/spy:$PATH"
}

@test "build-repo end to end, unsigned: the history under its tag, nothing left behind" {
    real_inputs
    rm -rf packaging
    write_map site
    before="$(sha pkgs/hello-1.2.3-1.x86_64.rpm)"
    run "$LIB/action.sh" build-repo
    assert_status 0
    [ -f site/index.html ]
    [ -f site/deb/hello.list ]
    [ ! -e site/pkg-pages.tsv.asc ]
    [ "$(output_value signed)" = false ]
    [ "$(output_value site-path)" = site ]
    m=site/pkg-pages.tsv
    grep -qP '^release\tv1\.2\.3\t[0-9a-f]{64}\trpm/x86_64/hello-1\.2\.3-1\.x86_64\.rpm$' "$m"
    grep -qP '^release\tv1\.2\.2\t[0-9a-f]{64}\trpm/x86_64/hello-1\.2\.2-1\.x86_64\.rpm$' "$m"
    grep -qP '^release\tv1\.2\.2\t[0-9a-f]{64}\tdeb/pool/main/h/hello/hello_1\.2\.2-1_amd64\.deb$' "$m"
    [ ! -e site.work ]
    [ ! -e site.to-sign ]
    [ "$(sha pkgs/hello-1.2.3-1.x86_64.rpm)" = "$before" ]
}

@test "build-repo end to end, signed: this release and proven history signed, the caller's files untouched, no key where packages are parsed" {
    real_inputs
    with_secret
    write_map site
    spy apt-ftparchive createrepo_c dpkg-deb
    cur="$(sha pkgs/hello-1.2.3-1.x86_64.rpm)"
    old="$(sha hist/hello-1.2.2-1.x86_64.rpm)"
    map="$(cat hist.map)"
    run "$LIB/action.sh" build-repo
    assert_status 0
    [ "$(output_value signed)" = true ]
    [ "$(output_value fingerprint)" = "$(cat "$TMP/key/fpr")" ]
    # Both releases' .rpm files are signed by the pin, in the site; the caller's are as they were.
    "$LIB/linux-signing.sh" --pin "$TMP/key/pin.asc" check-rpm site/rpm/x86_64/hello-1.2.3-1.x86_64.rpm site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm
    [ "$(sha site/rpm/x86_64/hello-1.2.3-1.x86_64.rpm)" != "$cur" ]
    [ "$(sha site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm)" != "$old" ]
    [ "$(sha pkgs/hello-1.2.3-1.x86_64.rpm)" = "$cur" ]
    [ "$(sha hist/hello-1.2.2-1.x86_64.rpm)" = "$old" ]
    [ "$(cat hist.map)" = "$map" ]
    # The manifest names the files as the site holds them, the earlier one under its own tag, signed.
    grep -qxF "$(printf 'release\tv1.2.2\t%s\trpm/x86_64/hello-1.2.2-1.x86_64.rpm' "$(sha site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm)")" site/pkg-pages.tsv
    [ "$(head -n 1 site/pkg-pages.tsv | cut -f4)" = "$(cat "$TMP/key/fpr")" ]
    [ -s site/pkg-pages.tsv.asc ]
    [ -s site/deb/dists/stable/InRelease ]
    [ -s site/rpm/x86_64/repodata/repomd.xml.asc ]
    [ ! -e site.work ]
    [ ! -e site.to-sign ]
    # The tools that parse packages never had the key.
    [ -s "$TMP/spy.env" ]
    refute grep -q REPO_SIGNING_KEY "$TMP/spy.env"
}

@test "build-repo end to end, signed: the keyring package is published by default, and keyring-package false leaves it out" {
    real_inputs
    with_secret
    write_map site
    run "$LIB/action.sh" build-repo
    assert_status 0
    ls site/deb/pool/main/h/hello-keyring/hello-keyring_*_all.deb
    grep -q 'signed-by=/usr/share/keyrings/hello-keyring.asc' site/deb/hello.list
    grep -qP '^keyring\t-\t[0-9a-f]{64}\tdeb/pool/main/h/hello-keyring/' site/pkg-pages.tsv
    rm -rf site
    export INPUT_KEYRING_PACKAGE=false
    run "$LIB/action.sh" build-repo
    assert_status 0
    [ ! -e site/deb/pool/main/h/hello-keyring ]
    refute grep -q 'hello-keyring' site/deb/hello.list
    refute grep -q '^keyring' site/pkg-pages.tsv
}

@test "build-repo end to end: an earlier .rpm that nothing proves needs resign-history" {
    real_inputs
    with_secret
    write_map release
    export INPUT_RESIGN_HISTORY=false
    run "$LIB/action.sh" build-repo
    assert_status 1
    assert_output_contains "nothing proves its bytes"
    assert_output_contains "hello-1.2.2-1.x86_64.rpm"
    [ ! -e site ]
    [ ! -e site.work ]
    export INPUT_RESIGN_HISTORY=true
    run "$LIB/action.sh" build-repo
    assert_status 0
    assert_output_contains "signing it anyway"
    "$LIB/linux-signing.sh" --pin "$TMP/key/pin.asc" check-rpm site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm
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

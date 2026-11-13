#!/usr/bin/env bats
# lib/pages-repo.sh: the site layout, metadata-driven package handling, signing, the landing
# page, extra-site, the self-check, and installing from the result with apt and dnf.
# Needs dpkg-deb, apt-ftparchive, rpmbuild and createrepo_c (tests/container.sh debian); the
# rpm-only tests also run on Fedora.

load helpers

setup_file() {
    keys
    P="$BATS_FILE_TMPDIR/pkgs"
    export P
    if command -v dpkg-deb > /dev/null; then
        "$FIXTURES" deb "$P/deb" hello 1.2.3-1 amd64
        "$FIXTURES" deb "$P/deb" hello 1.2.3-1 arm64
        "$FIXTURES" deb "$P/deb" hello 1.2.2-1 amd64
        "$FIXTURES" deb "$P/deb" hello-doc 1.2.3 all
        "$FIXTURES" deb "$P/deb" libhello1 1.2.3-1 amd64
    fi
    if command -v rpmbuild > /dev/null; then
        "$FIXTURES" rpm "$P/rpm" hello 1.2.3 x86_64
        "$FIXTURES" rpm "$P/rpm" hello 1.2.3 aarch64
        "$FIXTURES" rpm "$P/rpm" hello 1.2.2 x86_64
        "$FIXTURES" rpm "$P/rpm" hello-doc 1.2.3 noarch
    fi
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

need_deb() { need dpkg-deb apt-ftparchive gzip; }
need_rpm() { need rpm rpmbuild createrepo_c; }
need_both() { need_deb; need_rpm; }

# pkgs KIND...: copy the fixture packages of each KIND (deb, rpm) into $TMP/pkgs.
pkgs() {
    mkdir -p "$TMP/pkgs"
    for k in "$@"; do cp "$P/$k"/* "$TMP/pkgs/"; done
}

# build [OPTION]...: pages-repo.sh into $TMP/site, unsigned, with the usual required options.
build() {
    run "$LIB/pages-repo.sh" --packages "$TMP/pkgs" --out "$TMP/site" \
        --base-url "file://$TMP/site" --version 1.2.3 --name hello "$@"
}

# build_signed [OPTION]...: the same, importing key a against its pin.
# shellcheck disable=SC2120 # the options are optional
build_signed() {
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    build --public-key "$K/a/pin.asc" --import-key true "$@"
}

# use_apt_site: point a private APT configuration at the built site only (no Debian archive).
use_apt_site() {
    install -d /etc/apt/keyrings "$TMP/apt/lists/partial"
    cp "$TMP/site/hello.asc" /etc/apt/keyrings/hello.asc
    cp "$TMP/site/deb/hello.list" "$TMP/apt/sources.list"
    chmod -R a+rX "$TMP"
}

# apt_only ARGS...: apt-get (or apt-cache for `policy`) with only the test site as a source.
apt_only() {
    set -- -o "Dir::Etc::sourcelist=$TMP/apt/sources.list" -o Dir::Etc::sourceparts=- \
        -o "Dir::State::lists=$TMP/apt/lists" "$@"
    case " $* " in
        *" policy "*) apt-cache "$@" ;;
        *) apt-get "$@" ;;
    esac
}

# --- Layout ----------------------------------------------------------------------------------

@test "unsigned site: APT and DNF layout, trusted=yes and gpgcheck=0, no key" {
    need_both
    pkgs deb rpm
    build
    assert_status 0
    s="$TMP/site"
    for f in index.html .nojekyll deb/hello.list deb/dists/stable/Release \
        deb/dists/stable/main/binary-amd64/Packages.gz deb/dists/stable/main/binary-arm64/Packages.gz \
        rpm/hello.repo rpm/x86_64/repodata/repomd.xml rpm/aarch64/repodata/repomd.xml; do
        [ -e "$s/$f" ] || { echo "missing $f"; false; }
    done
    [ ! -e "$s/hello.asc" ]
    [ ! -d "$s/nix" ]
    refute grep -q '<h2>Nix</h2>' "$s/index.html"
    [ ! -e "$s/deb/dists/stable/InRelease" ]
    [ ! -e "$s/rpm/x86_64/repodata/repomd.xml.asc" ]
    [ "$(cat "$s/deb/hello.list")" = "deb [trusted=yes] file://$TMP/site/deb stable main" ]
    grep -qx gpgcheck=0 "$s/rpm/hello.repo"
    grep -qx repo_gpgcheck=0 "$s/rpm/hello.repo"
    grep -qx "baseurl=file://$TMP/site/rpm/\$basearch" "$s/rpm/hello.repo"
    [ "$(output_value signed)" = false ]
}

@test "packages are found by metadata, not file name, and renamed canonically" {
    need_both
    mkdir -p "$TMP/pkgs/nested"
    cp "$P/deb/hello_1.2.3-1_amd64.deb" "$TMP/pkgs/nested/whatever.deb"
    cp "$P/rpm/hello-1.2.3-1.x86_64.rpm" "$TMP/pkgs/renamed.rpm"
    build
    assert_status 0
    [ -f "$TMP/site/deb/pool/main/h/hello/hello_1.2.3-1_amd64.deb" ]
    [ -f "$TMP/site/rpm/x86_64/hello-1.2.3-1.x86_64.rpm" ]
}

@test "Packages lists every version; Architecture: all is in every binary-<arch>" {
    need_deb
    pkgs deb
    build
    assert_status 0
    amd="$(gzip -cd "$TMP/site/deb/dists/stable/main/binary-amd64/Packages.gz")"
    arm="$(gzip -cd "$TMP/site/deb/dists/stable/main/binary-arm64/Packages.gz")"
    echo "$amd" | grep -qx 'Version: 1.2.3-1'
    echo "$amd" | grep -qx 'Version: 1.2.2-1'
    echo "$amd" | grep -qx 'Package: hello-doc'
    echo "$arm" | grep -qx 'Package: hello-doc'
    refute grep -qx 'Version: 1.2.2-1' <<< "$arm"
}

@test "Release names the suite, component, architectures and the title" {
    need_deb
    pkgs deb
    build --suite trixie --component contrib --title "Hello repos"
    assert_status 0
    r="$TMP/site/deb/dists/trixie/Release"
    grep -qx 'Origin: hello' "$r"
    grep -qx 'Suite: trixie' "$r"
    grep -qx 'Codename: trixie' "$r"
    grep -qx 'Components: contrib' "$r"
    grep -qx 'Architectures: amd64 arm64' "$r"
    grep -qx 'Description: Hello repos' "$r"
    [ -d "$TMP/site/deb/pool/contrib" ]
    grep -q ' trixie contrib$' "$TMP/site/deb/hello.list"
}

@test "lib* packages go to pool/<component>/lib<x>/" {
    need_deb
    pkgs deb
    build
    assert_status 0
    [ -f "$TMP/site/deb/pool/main/libh/libhello1/libhello1_1.2.3-1_amd64.deb" ]
}

@test "noarch .rpm files are copied into every rpm/<arch>/" {
    need_rpm
    pkgs rpm
    build
    assert_status 0
    [ -f "$TMP/site/rpm/x86_64/hello-doc-1.2.3-1.noarch.rpm" ]
    [ -f "$TMP/site/rpm/aarch64/hello-doc-1.2.3-1.noarch.rpm" ]
    [ ! -e "$TMP/site/rpm/aarch64/hello-1.2.2-1.x86_64.rpm" ]
}

@test "an rpm-only site needs no APT tools and has no deb/" {
    need_rpm
    pkgs rpm
    build
    assert_status 0
    [ ! -e "$TMP/site/deb" ]
    refute grep -q 'apt install' "$TMP/site/index.html"
}

@test "a deb-only site has no rpm/" {
    need_deb
    pkgs deb
    build
    assert_status 0
    [ ! -e "$TMP/site/rpm" ]
    refute grep -q 'dnf install' "$TMP/site/index.html"
}

@test "only arch-independent packages: published for the default architectures" {
    need_both
    mkdir -p "$TMP/pkgs"
    cp "$P/deb/hello-doc_1.2.3_all.deb" "$P/rpm/hello-doc-1.2.3-1.noarch.rpm" "$TMP/pkgs/"
    build --deb-architectures all --rpm-architectures noarch
    assert_status 0
    [ -d "$TMP/site/deb/dists/stable/main/binary-amd64" ]
    [ -d "$TMP/site/deb/dists/stable/main/binary-arm64" ]
    [ ! -d "$TMP/site/deb/dists/stable/main/binary-all" ]
    [ -d "$TMP/site/rpm/x86_64" ]
    [ -d "$TMP/site/rpm/aarch64" ]
    [ ! -d "$TMP/site/rpm/noarch" ]
}

@test "an all/noarch package does not satisfy a required architecture" {
    need_both
    mkdir -p "$TMP/pkgs"
    cp "$P/deb/hello-doc_1.2.3_all.deb" "$P/rpm/hello-doc-1.2.3-1.noarch.rpm" "$TMP/pkgs/"
    build --deb-architectures amd64
    assert_status 1
    build --rpm-architectures x86_64
    assert_status 1
}

@test "directory listings in every directory, or none" {
    need_deb
    pkgs deb
    build
    assert_status 0
    grep -q 'href="hello_1.2.3-1_amd64.deb"' "$TMP/site/deb/pool/main/h/hello/index.html"
    grep -q 'href="dists/"' "$TMP/site/deb/index.html"
    rm -rf "$TMP/site"
    build --directory-listings false
    assert_status 0
    [ ! -e "$TMP/site/deb/index.html" ]
    [ -e "$TMP/site/index.html" ]
}

@test "landing page and directory listings use local theme assets only" {
    need_deb
    pkgs deb
    build
    for page in "$TMP/site/index.html" "$TMP/site/deb/index.html"; do
        refute grep -Eq '<(link|script)[^>]*(src|href)=' "$page"
        grep -q 'data-theme' "$page"
        grep -q 'prefers-color-scheme' "$page"
    done
}

@test "optional Nix card installs the flake from the site and pins the release archives" {
    need_deb tar sha256sum awk
    pkgs deb
    mkdir -p "$TMP/archive/hello-1.2.3/bin"
    printf '#!/bin/sh\necho hi\n' > "$TMP/archive/hello-1.2.3/bin/hello"
    chmod +x "$TMP/archive/hello-1.2.3/bin/hello"
    tar -czf "$TMP/hello.tar.gz" -C "$TMP/archive" hello-1.2.3
    build --nix-archives "x86_64-linux=$TMP/hello.tar.gz" --nix-binaries bin/hello \
        --nix-url-base 'https://example.test/releases?a=1&b=2'
    assert_status 0
    [ -s "$TMP/site/nix/flake.tar.gz" ]
    [ -s "$TMP/site/nix/flake.nix" ]
    [ -s "$TMP/site/nix/flake.lock" ]
    # The flake is served by the site (base-url); only the archives it pins live at nix-url-base.
    grep -q "nix profile install file://$TMP/site/nix/flake.tar.gz" "$TMP/site/index.html"
    grep -q "nix run file://$TMP/site/nix/flake.tar.gz" "$TMP/site/index.html"
    refute grep -q 'example.test' "$TMP/site/index.html"
    grep -q 'url = "https://example.test/releases?a=1&b=2/hello.tar.gz"' "$TMP/site/nix/flake.nix"
    grep -q 'Prebuilt binaries for x86_64-linux, pinned by SHA-256. The flake itself is not signed.' "$TMP/site/index.html"
    grep -q 'href="nix/"' "$TMP/site/index.html"
    grep -q "sha256 = \"$(sha "$TMP/hello.tar.gz")\"" "$TMP/site/nix/flake.nix"
}

@test "Nix inputs are opt-in and must be supplied together" {
    need_deb
    pkgs deb
    build --nix-binaries bin/hello
    assert_status 1
    assert_output_contains "must be set together"
    [ ! -d "$TMP/site" ]
}

@test "footer is published by default and can be disabled" {
    need_deb
    pkgs deb
    build
    assert_status 0
    grep -q 'ziptie-soft/pkg-pages' "$TMP/site/index.html"
    # The footer names this checkout's version, which release-please bumps in version.txt.
    v="$(cat "$LIB/../version.txt")"
    grep -qF "pkg-pages</a> $v" "$TMP/site/index.html"
    grep -q 'ziptie-soft/pkg-pages' "$TMP/site/deb/index.html"
    rm -rf "$TMP/site"
    build --footer false
    assert_status 0
    refute grep -q '<footer' "$TMP/site/index.html"
    refute grep -q '<footer' "$TMP/site/deb/index.html"
}

# --- Versions and inputs ---------------------------------------------------------------------

@test "fails when the release version is not among the packages" {
    need_deb
    pkgs deb
    run "$LIB/pages-repo.sh" --packages "$TMP/pkgs" --out "$TMP/site" --base-url https://x.github.io/y --version 9.9.9 --name hello
    assert_status 1
    assert_output_contains "no package of version 9.9.9"
    [ ! -e "$TMP/site" ]
}

@test "fails when a required architecture has no package of the version" {
    need_both
    pkgs deb rpm
    build --deb-architectures "amd64 armhf"
    assert_status 1
    assert_output_contains "no armhf .deb of version 1.2.3"
    build --rpm-architectures "x86_64 ppc64le"
    assert_status 1
    assert_output_contains "no ppc64le .rpm"
}

@test "an older version alone does not satisfy a required architecture" {
    need_deb
    mkdir -p "$TMP/pkgs"
    cp "$P/deb/hello_1.2.3-1_arm64.deb" "$P/deb/hello_1.2.2-1_amd64.deb" "$TMP/pkgs/"
    build --deb-architectures "amd64 arm64"
    assert_status 1
    assert_output_contains "no amd64 .deb"
}

@test "fails on a file that is not a package" {
    need_deb
    pkgs deb
    printf 'x' > "$TMP/pkgs/SHA256SUMS"
    build
    assert_status 1
    assert_output_contains "neither a .deb nor an .rpm"
}

@test "fails on a corrupt package" {
    need_deb
    mkdir -p "$TMP/pkgs"
    printf 'not a deb' > "$TMP/pkgs/broken.deb"
    build
    assert_status 1
    assert_output_contains "not a readable .deb"
}

@test "the same package twice: fine when identical, an error when the bytes differ" {
    need_deb
    pkgs deb
    mkdir -p "$TMP/pkgs/again"
    cp "$P/deb/hello_1.2.3-1_amd64.deb" "$TMP/pkgs/again/"
    build
    assert_status 0
    rm -rf "$TMP/site"
    # Same name, version and architecture, other contents.
    FIXTURE_NOTE=other "$FIXTURES" deb "$TMP/other" hello 1.2.3-1 amd64
    cp "$TMP/other/hello_1.2.3-1_amd64.deb" "$TMP/pkgs/again/"
    build
    assert_status 1
    assert_output_contains "but differ"
}

@test "input validation" {
    need_deb
    pkgs deb
    v() { run "$LIB/pages-repo.sh" --packages "$TMP/pkgs" --out "$TMP/site" --version 1.2.3 "$@"; assert_status 1; }
    v --base-url http://x --name hello
    v --base-url https://x --name Hello
    v --base-url https://x --name hello --suite 'a b'
    v --base-url https://x --name hello --directory-listings yes
    v --base-url https://x --name hello --footer yes
    v --base-url https://x --name hello --homepage 'javascript:alert(1)'
    v --base-url https://x --name hello --deb-architectures 'amd64 ../x'
    v --base-url https://x --name hello --extra-site "$TMP/none"
    v --base-url https://x --name hello --bogus 1
    run "$LIB/pages-repo.sh" --packages "$TMP/pkgs"
    assert_status 1
    mkdir "$TMP/site"
    v --base-url https://x --name hello
    assert_output_contains "already exists"
}

# --- Landing page and extra-site -------------------------------------------------------------

@test "the landing page escapes caller strings and names the packages of the release" {
    need_deb
    pkgs deb
    build --title 'Hi <script>alert(1)</script>' --description 'a "b" & <c>' --homepage 'https://example.com/?a=1&b=2'
    assert_status 0
    i="$TMP/site/index.html"
    refute grep -q 'Hi <script>' "$i"
    refute grep -q 'alert(1)</script>' "$i"
    grep -q 'Hi &lt;script&gt;' "$i"
    grep -q 'a &quot;b&quot; &amp; &lt;c&gt;' "$i"
    grep -q 'href="https://example.com/?a=1&amp;b=2"' "$i"
    grep -q 'sudo apt install hello hello-doc libhello1' "$i"
    grep -q 'These repositories are unsigned' "$i"
}

@test "packslip commands are absent by default" {
    need_deb
    pkgs deb
    build
    assert_status 0
    refute grep -qi 'packslip' "$TMP/site/index.html"
}

@test "packslip card shows packslip and mise commands, with an optional signer pin" {
    need_deb
    pkgs deb
    project=github.com/Owner/Repo
    build --packslip-project "$project"
    assert_status 0
    i="$TMP/site/index.html"
    grep -q '<h2>packslip and mise (CLI only)</h2><button type="button" class="copy">Copy</button>' "$i"
    grep -q "packslip install $project" "$i"
    grep -q "mise use -g packslip:$project" "$i"
    refute grep -q 'packslip install .*--pin' "$i"
    grep -q "Installs the release's signed packslip bundle from the GitHub release; packslip checks the signature before it installs." "$i"
    rm -rf "$TMP/site"
    pin=ps1_4yd5vxao3lfzaox72lynxuotke
    build --packslip-project "$project" --packslip-pin "$pin"
    assert_status 0
    grep -q "packslip install $project --pin $pin" "$TMP/site/index.html"
    grep -q "mise use -g packslip:$project" "$TMP/site/index.html"
}

@test "packslip card escapes caller strings" {
    need_deb
    pkgs deb
    build --packslip-project github.com/Owner/Repo --title 'A <b> & c'
    assert_status 0
    grep -q 'A &lt;b&gt; &amp; c' "$TMP/site/index.html"
    grep -q 'packslip install github.com/Owner/Repo' "$TMP/site/index.html"
}

@test "packslip project and pin inputs are validated" {
    need_deb
    pkgs deb
    for project in \
        'github.com/owner/my repo' 'github.com/owner/"repo"' 'github.com/owner/<repo>' \
        'github.com/owner/>repo<' 'github.com/owner/repo&x' 'github.com/owner/..' \
        $'github.com/owner/repo\nextra'; do
        build --packslip-project "$project"
        assert_status 1
        refute [ -e "$TMP/site" ]
    done
    for pin in \
        'bad_4yd5vxao3lfzaox72lynxuotke' 'ps1_4yd5vxao3lfzaox72lynxuotk' \
        'ps1_4yd5vxao3lfzaox72lynxuotkE' $'ps1_4yd5vxao3lfzaox72lynxuotke\nextra'; do
        build --packslip-project github.com/owner/repo --packslip-pin "$pin"
        assert_status 1
        refute [ -e "$TMP/site" ]
    done
    build --packslip-pin ps1_4yd5vxao3lfzaox72lynxuotke
    assert_status 1
    refute [ -e "$TMP/site" ]
}

@test "extra-site is merged into the root" {
    need_deb
    pkgs deb
    mkdir -p "$TMP/extra/docs"
    printf 'docs\n' > "$TMP/extra/docs/index.html"
    printf 'badge\n' > "$TMP/extra/badge.svg"
    build --extra-site "$TMP/extra"
    assert_status 0
    [ "$(cat "$TMP/site/docs/index.html")" = docs ]
    [ -f "$TMP/site/badge.svg" ]
}

@test "extra-site may not overwrite a repository file" {
    need_deb
    pkgs deb
    mkdir -p "$TMP/extra/deb"
    printf 'evil\n' > "$TMP/extra/deb/hello.list"
    build --extra-site "$TMP/extra"
    assert_status 1
    assert_output_contains "would overwrite deb/hello.list"
    rm -rf "$TMP/site" "$TMP/extra"
    mkdir -p "$TMP/extra"
    printf 'x\n' > "$TMP/extra/index.html"
    build --extra-site "$TMP/extra"
    assert_status 1
}

@test "extra-site may not hold symbolic links" {
    need_deb
    pkgs deb
    mkdir -p "$TMP/extra"
    ln -s /etc/passwd "$TMP/extra/passwd"
    build --extra-site "$TMP/extra"
    assert_status 1
    assert_output_contains "symbolic links"
}

# --- Signing ---------------------------------------------------------------------------------

@test "signed site: InRelease, Release.gpg and repomd.xml.asc verify against the pin" {
    need_both
    need gpgv rpmsign rpmkeys
    pkgs deb rpm
    build_signed
    assert_status 0
    s="$TMP/site"
    [ "$(output_value signed)" = true ]
    [ "$(output_value fingerprint)" = "$(cat "$K/a/fpr")" ]
    cmp "$s/hello.asc" "$K/a/pin.asc"
    gpg --batch --dearmor < "$K/a/pin.asc" > "$TMP/pin.gpg"
    gpgv --keyring "$TMP/pin.gpg" "$s/deb/dists/stable/InRelease"
    gpgv --keyring "$TMP/pin.gpg" "$s/deb/dists/stable/Release.gpg" "$s/deb/dists/stable/Release"
    gpgv --keyring "$TMP/pin.gpg" "$s/rpm/x86_64/repodata/repomd.xml.asc" "$s/rpm/x86_64/repodata/repomd.xml"
    grep -qx gpgcheck=1 "$s/rpm/hello.repo"
    grep -qx repo_gpgcheck=1 "$s/rpm/hello.repo"
    grep -qx "gpgkey=file://$TMP/site/hello.asc" "$s/rpm/hello.repo"
    grep -q 'signed-by=/etc/apt/keyrings/hello.asc' "$s/deb/hello.list"
    grep -q "$(cat "$K/a/fpr")" "$s/index.html"
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$s"/rpm/*/*.rpm
}

@test "signing: earlier releases' unsigned .rpm files are signed, signed ones stay identical" {
    need_rpm
    need gpgv rpmsign rpmkeys
    pkgs rpm
    # This release's packages, signed beforehand by sign-rpm.
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP/pkgs/hello-1.2.3-1.x86_64.rpm" 2> /dev/null
    before="$(sha "$TMP/pkgs/hello-1.2.3-1.x86_64.rpm")"
    old="$(sha "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm")"
    rm -rf "$GNUPGHOME"
    build_signed
    assert_status 0
    [ "$(sha "$TMP/site/rpm/x86_64/hello-1.2.3-1.x86_64.rpm")" = "$before" ]
    [ "$(sha "$TMP/site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm")" != "$old" ]
    # The input directory is never modified.
    [ "$(sha "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm")" = "$old" ]
}

@test "signing fails closed: a pin without a key stops the build" {
    need_deb
    pkgs deb
    gnupg_home
    build --public-key "$K/a/pin.asc" --import-key true
    assert_status 1
    [ ! -e "$TMP/site" ]
}

@test "signing fails closed: another project's key stops the build" {
    need_deb
    pkgs deb
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/b/ci.asc")"
    export REPO_SIGNING_KEY
    build --public-key "$K/a/pin.asc" --import-key true
    assert_status 1
}

@test "a key already in GNUPGHOME must match the given public key" {
    need_deb
    need gpgv
    pkgs deb
    gnupg_home
    gpg --batch --quiet --import "$K/b/ci.asc"
    build --public-key "$K/a/pin.asc"
    assert_status 1
    assert_output_contains "is not the key of public-key"
    rm -rf "$TMP/site"
    build
    assert_status 1
    assert_output_contains "no public-key was given"
}

@test "without GNUPGHOME, the user's own keys are never used" {
    need_deb
    pkgs deb
    unset GNUPGHOME
    build
    assert_status 0
    [ "$(output_value signed)" = false ]
}

# --- Installing from the site (root, in a container) -----------------------------------------

@test "apt installs from the signed site with signed-by, and pins an older version" {
    need_deb
    need_system
    need apt-get gpgv
    pkgs deb
    build_signed
    assert_status 0
    use_apt_site
    apt_only update -qq
    # The newest version of the site, not Debian's own "hello".
    [ "$(apt_only policy hello | sed -n 's/^  Candidate: //p')" = 1.2.3-1 ]
    DEBIAN_FRONTEND=noninteractive apt_only install -y -qq hello
    [ -f /usr/share/hello/1.2.3-1 ]
    DEBIAN_FRONTEND=noninteractive apt_only install -y -qq --allow-downgrades hello=1.2.2-1
    [ -f /usr/share/hello/1.2.2-1 ]
    apt-get remove -y -qq hello > /dev/null
}

@test "apt refuses a tampered InRelease" {
    need_deb
    need_system
    need apt-get gpgv
    pkgs deb
    build_signed
    assert_status 0
    sed -i 's/^Origin: hello$/Origin: evil/' "$TMP/site/deb/dists/stable/InRelease"
    use_apt_site
    run apt_only update
    assert_status 100
    assert_output_contains "InRelease"
}

@test "apt refuses the site with another project's key in signed-by" {
    need_deb
    need_system
    need apt-get gpgv
    pkgs deb
    build_signed
    assert_status 0
    use_apt_site
    cp "$K/b/pin.asc" /etc/apt/keyrings/hello.asc
    run apt_only update
    assert_status 100
}

@test "dnf installs from the signed site with gpgcheck and repo_gpgcheck, and downgrades" {
    need_rpm
    need_system
    need dnf gpgv rpmsign
    pkgs rpm
    build_signed
    assert_status 0
    cp "$TMP/site/rpm/hello.repo" /etc/yum.repos.d/pkg-pages-test.repo
    dnf install -y -q --repo hello hello
    [ -f /usr/share/hello/1.2.3 ]
    dnf downgrade -y -q --repo hello hello
    [ -f /usr/share/hello/1.2.2 ]
    dnf remove -y -q hello
    rm /etc/yum.repos.d/pkg-pages-test.repo
}

@test "dnf refuses the site when repomd.xml was changed after signing" {
    need_rpm
    need_system
    need dnf gpgv rpmsign
    pkgs rpm
    build_signed
    assert_status 0
    printf '\n' >> "$TMP/site/rpm/x86_64/repodata/repomd.xml"
    cp "$TMP/site/rpm/hello.repo" /etc/yum.repos.d/pkg-pages-test.repo
    run dnf install -y -q --repo hello --refresh hello
    rm /etc/yum.repos.d/pkg-pages-test.repo
    assert_status 1
}

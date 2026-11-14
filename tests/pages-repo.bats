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
    # A second build in one test starts with a fresh home, as a second step would.
    if [ -d "$TMP/gnupg" ]; then
        gpgconf --homedir "$TMP/gnupg" --kill all > /dev/null 2>&1 || true
        rm -rf "$TMP/gnupg"
    fi
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

@test "fails on a symbolic link among the packages" {
    need_deb
    pkgs deb
    ln -s "$TMP/pkgs/hello_1.2.3-1_amd64.deb" "$TMP/pkgs/link.deb"
    build
    assert_status 1
    assert_output_contains "not a regular file"
}

@test "two .deb files that differ only in their epoch: an error, not an overwrite" {
    need_deb
    pkgs deb
    "$FIXTURES" deb "$TMP/epoch" hello 1:1.2.3-1 amd64
    cp "$TMP/epoch"/*.deb "$TMP/pkgs/"
    build
    assert_status 1
    assert_output_contains "epoch"
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
    # publish.yml names the release, which its pinned actions' version.txt predates.
    build --footer-version 9.8.7
    assert_status 0
    grep -qF "pkg-pages</a> 9.8.7</footer>" "$TMP/site/index.html"
    rm -rf "$TMP/site"
    build --footer-version '1.0<b>'
    assert_status 1
    assert_output_contains "footer-version must match"
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
    v --base-url 'https://x/a&b' --name hello
    v --base-url 'https://x/a;b' --name hello
    v --base-url 'https://x/?q' --name hello
    v --base-url https://x --name Hello
    v --base-url https://x --name hello --title "$(printf 'a\nb')"
    v --base-url https://x --name hello --title "$(printf 'a\tb')"
    v --base-url https://x --name hello --suite 'a b'
    v --base-url https://x --name hello --directory-listings yes
    v --base-url https://x --name hello --footer yes
    v --base-url https://x --name hello --resign-history yes
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
    grep -qx "gpgkey=file://$TMP/site/rpm/RPM-GPG-KEY-hello" "$s/rpm/hello.repo"
    [ -s "$s/rpm/RPM-GPG-KEY-hello" ]
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
    assert_output_contains "re-signing $TMP/pkgs/hello-1.2.2-1.x86_64.rpm"
    refute grep -q 're-signing .*1\.2\.3' <<< "$output"
    # The input directory is never modified.
    [ "$(sha "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm")" = "$old" ]
}

@test "resign-history false: an earlier release's unsigned .rpm stops the build; signed ones pass" {
    need_rpm
    need gpgv rpmsign rpmkeys
    pkgs rpm
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP/pkgs/hello-1.2.3-1.x86_64.rpm" 2> /dev/null
    rm -rf "$GNUPGHOME"
    build_signed --resign-history false
    assert_status 1
    assert_output_contains "resign-history false"
    assert_output_contains "hello-1.2.2"
    rm -rf "$TMP/site" "$GNUPGHOME"
    gnupg_home
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm" 2> /dev/null
    rm -rf "$GNUPGHOME"
    build_signed --resign-history false
    assert_status 0
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

# --- site-check.sh ---------------------------------------------------------------------------

# check [OPTION]...: site-check.sh on $TMP/site.
check() {
    run "$LIB/site-check.sh" --site "$TMP/site" --name hello --version 1.2.3 "$@"
}

@test "site-check passes on a built site and names what is missing" {
    need_deb
    pkgs deb
    build
    assert_status 0
    check --deb-architectures "amd64 arm64"
    assert_status 0
    check --deb-architectures "amd64 armhf"
    assert_status 1
    assert_output_contains "armhf"
    rm "$TMP/site/deb/dists/stable/main/binary-arm64/Packages.gz"
    check
    assert_status 1
    assert_output_contains "Packages.gz is missing"
}

@test "site-check against the pin fails on a tampered InRelease or a missing signature" {
    need_deb
    need gpgv
    pkgs deb
    build_signed
    assert_status 0
    check --public-key "$K/a/pin.asc"
    assert_status 0
    check --public-key "$K/b/pin.asc"
    assert_status 1
    cp "$TMP/site/deb/dists/stable/InRelease" "$TMP/InRelease"
    sed -i 's/^Origin: hello$/Origin: evil/' "$TMP/site/deb/dists/stable/InRelease"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    cp "$TMP/InRelease" "$TMP/site/deb/dists/stable/InRelease"
    rm "$TMP/site/deb/dists/stable/Release.gpg"
    check --public-key "$K/a/pin.asc"
    assert_status 1
}

# --- site-seal.sh ----------------------------------------------------------------------------

# seal_tree: a minimal site tree in $TMP/ss, with a to-sign list naming all three kinds of file.
seal_tree() {
    mkdir -p "$TMP/ss/deb/dists/stable" "$TMP/ss/rpm/x86_64/repodata"
    printf 'Origin: hello\n' > "$TMP/ss/deb/dists/stable/Release"
    printf '<repomd/>\n' > "$TMP/ss/rpm/x86_64/repodata/repomd.xml"
    printf '#pkg-pages-manifest\t1\thello\t-\n' > "$TMP/ss/pkg-pages.tsv"
    printf '%s\n' deb/dists/stable/Release rpm/x86_64/repodata/repomd.xml pkg-pages.tsv > "$TMP/list"
}

# seal [OPTION]...: site-seal.sh on $TMP/ss and $TMP/list with key a, in a fresh GNUPGHOME.
# shellcheck disable=SC2120 # the options are optional
seal() {
    if [ -d "$TMP/gnupg" ]; then
        gpgconf --homedir "$TMP/gnupg" --kill all > /dev/null 2>&1 || true
        rm -rf "$TMP/gnupg"
    fi
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key "$K/a/pin.asc" \
        --import-key true "$@"
}

@test "site-seal signs Release, repomd.xml and the manifest; the signatures verify against the pin" {
    need gpgv
    seal_tree
    seal
    assert_status 0
    s="$TMP/ss"
    [ "$(output_value signed)" = true ]
    [ "$(output_value fingerprint)" = "$(cat "$K/a/fpr")" ]
    gpg --batch --dearmor < "$K/a/pin.asc" > "$TMP/pin.gpg"
    gpgv --keyring "$TMP/pin.gpg" "$s/deb/dists/stable/InRelease"
    gpgv --keyring "$TMP/pin.gpg" "$s/deb/dists/stable/Release.gpg" "$s/deb/dists/stable/Release"
    gpgv --keyring "$TMP/pin.gpg" "$s/rpm/x86_64/repodata/repomd.xml.asc" "$s/rpm/x86_64/repodata/repomd.xml"
    gpgv --keyring "$TMP/pin.gpg" "$s/pkg-pages.tsv.asc" "$s/pkg-pages.tsv"
    # Only the signature files were written.
    [ "$(find "$s" -type f | wc -l)" -eq 7 ]
}

@test "site-seal refuses a path it does not sign, and signs nothing" {
    need gpg
    seal_tree
    for bad in deb/pool/main/h/hello/hello.deb ../list /etc/passwd deb/dists/../Release \
        deb/dists/stable/InRelease index.html deb/dists/stable/Release.gpg ''; do
        printf '%s\ndeb/dists/stable/Release\n' "$bad" > "$TMP/list"
        seal
        assert_status 1
        assert_output_contains "to-sign"
        [ ! -e "$TMP/ss/deb/dists/stable/InRelease" ]
    done
    # The same line twice.
    printf '%s\n%s\n' pkg-pages.tsv pkg-pages.tsv > "$TMP/list"
    seal
    assert_status 1
    [ ! -e "$TMP/ss/pkg-pages.tsv.asc" ]
}

@test "site-seal refuses a symbolic link, a missing file and a file over 16 MiB" {
    need gpg
    seal_tree
    # The file itself, and a directory above it.
    mv "$TMP/ss/pkg-pages.tsv" "$TMP/elsewhere.tsv"
    ln -s "$TMP/elsewhere.tsv" "$TMP/ss/pkg-pages.tsv"
    seal
    assert_status 1
    assert_output_contains "symbolic link"
    [ ! -e "$TMP/elsewhere.tsv.asc" ]
    rm "$TMP/ss/pkg-pages.tsv"
    mv "$TMP/elsewhere.tsv" "$TMP/ss/pkg-pages.tsv"
    mv "$TMP/ss/rpm" "$TMP/rpm-elsewhere"
    ln -s "$TMP/rpm-elsewhere" "$TMP/ss/rpm"
    seal
    assert_status 1
    assert_output_contains "symbolic link"
    [ ! -e "$TMP/rpm-elsewhere/x86_64/repodata/repomd.xml.asc" ]
    rm "$TMP/ss/rpm"
    seal
    assert_status 1
    assert_output_contains "missing"
    mv "$TMP/rpm-elsewhere" "$TMP/ss/rpm"
    # A file of exactly 16 MiB is fine; one byte more is not.
    head -c 16777216 /dev/zero > "$TMP/ss/pkg-pages.tsv"
    seal
    assert_status 0
    rm "$TMP/ss/pkg-pages.tsv.asc"
    head -c 16777217 /dev/zero > "$TMP/ss/pkg-pages.tsv"
    seal
    assert_status 1
    assert_output_contains "16 MiB"
}

@test "site-seal fails closed: a pin needs a key, a key needs a pin, and neither is an unsigned notice" {
    need gpg
    seal_tree
    # No pin and no key: the only unsigned run.
    unset GNUPGHOME REPO_SIGNING_KEY
    run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key "$TMP/nope.asc"
    assert_status 0
    assert_output_contains "nothing is signed"
    [ "$(output_value signed)" = false ]
    [ ! -e "$TMP/ss/pkg-pages.tsv.asc" ]
    # A pin and no key.
    gnupg_home
    run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key "$K/a/pin.asc"
    assert_status 1
    assert_output_contains "no signing key"
    run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key "$K/a/pin.asc" --import-key true
    assert_status 1
    # A key and no pin.
    gpg --batch --quiet --import "$K/a/ci.asc"
    run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key ""
    assert_status 1
    assert_output_contains "no public-key was given"
    # Another project's key.
    seal_other() {
        gpgconf --homedir "$TMP/gnupg" --kill all > /dev/null 2>&1 || true
        rm -rf "$TMP/gnupg"
        gnupg_home
        REPO_SIGNING_KEY="$(cat "$K/b/ci.asc")"
        export REPO_SIGNING_KEY
        run "$LIB/site-seal.sh" --site "$TMP/ss" --to-sign "$TMP/list" --public-key "$K/a/pin.asc" --import-key true
    }
    seal_other
    assert_status 1
    [ ! -e "$TMP/ss/pkg-pages.tsv.asc" ]
}

# --- The manifest, the keyring package and the stages ----------------------------------------

# mline KIND TAG FILE PATH: pkg-pages.tsv has the line KIND, TAG, the SHA-256 of FILE and PATH.
mline() {
    want="$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$(sha "$3")" "$4")"
    grep -qxF "$want" "$TMP/site/pkg-pages.tsv" || {
        printf 'no manifest line for %s %s %s\nmanifest:\n' "$1" "$2" "$4" >&2
        cat "$TMP/site/pkg-pages.tsv" >&2
        return 1
    }
}

# presign FILE...: sign the .rpm files with key a beforehand, as sign-rpm does in publish.yml.
presign() {
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$@" 2> /dev/null
    rm -rf "$GNUPGHOME"
}

@test "manifest: every package file by SHA-256 under its tag, the current tag first, each sorted" {
    need_both
    pkgs deb rpm
    # A pre-release version has a ~ in its file name.
    "$FIXTURES" deb "$TMP/pkgs" hello 1.2.3~rc1-1 amd64
    # Earlier releases, named by SHA-256, in the order their tags must come out.
    {
        printf 'v1.2.2\t%s\thello-1.2.2-1.x86_64.rpm\tsite\n' "$(sha "$P/rpm/hello-1.2.2-1.x86_64.rpm")"
        printf 'v1.2.1\t%s\thello_1.2.2-1_amd64.deb\tsite\n' "$(sha "$P/deb/hello_1.2.2-1_amd64.deb")"
        printf 'v1.2.0\t%s\thello_1.2.3~rc1-1_amd64.deb\trelease\n' "$(sha "$TMP/pkgs/hello_1.2.3~rc1-1_amd64.deb")"
    } > "$TMP/h.map"
    build --tag v1.2.3 --history-map "$TMP/h.map"
    assert_status 0
    m="$TMP/site/pkg-pages.tsv"
    [ "$(head -n 1 "$m" | tr '\t' ' ')" = '#pkg-pages-manifest 1 hello -' ]
    [ "$(tail -n +2 "$m" | cut -f1,2 | uniq | tr '\t' ' ')" = $'release v1.2.3\nrelease v1.2.2\nrelease v1.2.1\nrelease v1.2.0' ]
    for t in v1.2.3 v1.2.2 v1.2.1 v1.2.0; do
        awk -F'\t' -v t="$t" '$2 == t { print $4 }' "$m" > "$TMP/paths"
        LC_ALL=C sort "$TMP/paths" | cmp - "$TMP/paths"
    done
    mline release v1.2.3 "$P/deb/hello_1.2.3-1_amd64.deb" deb/pool/main/h/hello/hello_1.2.3-1_amd64.deb
    mline release v1.2.3 "$P/deb/hello-doc_1.2.3_all.deb" deb/pool/main/h/hello-doc/hello-doc_1.2.3_all.deb
    mline release v1.2.3 "$P/rpm/hello-doc-1.2.3-1.noarch.rpm" rpm/x86_64/hello-doc-1.2.3-1.noarch.rpm
    mline release v1.2.3 "$P/rpm/hello-doc-1.2.3-1.noarch.rpm" rpm/aarch64/hello-doc-1.2.3-1.noarch.rpm
    mline release v1.2.2 "$P/rpm/hello-1.2.2-1.x86_64.rpm" rpm/x86_64/hello-1.2.2-1.x86_64.rpm
    mline release v1.2.1 "$P/deb/hello_1.2.2-1_amd64.deb" deb/pool/main/h/hello/hello_1.2.2-1_amd64.deb
    mline release v1.2.0 "$TMP/pkgs/hello_1.2.3~rc1-1_amd64.deb" 'deb/pool/main/h/hello/hello_1.2.3~rc1-1_amd64.deb'
    # Every package file of the site, and no other line.
    [ "$(tail -n +2 "$m" | wc -l)" -eq "$(find "$TMP/site/deb/pool" "$TMP/site/rpm" -name '*.deb' -o -name '*.rpm' | wc -l)" ]
    # Without --tag there is no manifest.
    rm -rf "$TMP/site"
    build
    assert_status 0
    [ ! -e "$TMP/site/pkg-pages.tsv" ]
}

@test "manifest: earlier files keep their tag once re-signed, and the signed manifest names the pin" {
    need_rpm
    need gpgv rpmsign rpmkeys
    pkgs rpm
    presign "$TMP/pkgs/hello-1.2.3-1.x86_64.rpm" "$TMP/pkgs/hello-1.2.3-1.aarch64.rpm" "$TMP/pkgs/hello-doc-1.2.3-1.noarch.rpm"
    old="$(sha "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm")"
    printf 'v1.2.2\t%s\thello-1.2.2-1.x86_64.rpm\tsite\n' "$old" > "$TMP/h.map"
    build_signed --tag v1.2.3 --history-map "$TMP/h.map"
    assert_status 0
    [ "$(sha "$TMP/site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm")" != "$old" ]
    mline release v1.2.2 "$TMP/site/rpm/x86_64/hello-1.2.2-1.x86_64.rpm" rpm/x86_64/hello-1.2.2-1.x86_64.rpm
    mline release v1.2.3 "$TMP/pkgs/hello-1.2.3-1.x86_64.rpm" rpm/x86_64/hello-1.2.3-1.x86_64.rpm
    [ "$(head -n 1 "$TMP/site/pkg-pages.tsv" | tr '\t' ' ')" = "#pkg-pages-manifest 1 hello $(cat "$K/a/fpr")" ]
    gpg --batch --dearmor < "$K/a/pin.asc" > "$TMP/pin.gpg"
    gpgv --keyring "$TMP/pin.gpg" "$TMP/site/pkg-pages.tsv.asc" "$TMP/site/pkg-pages.tsv"
    # The input is untouched, and the map file too.
    [ "$(sha "$TMP/pkgs/hello-1.2.2-1.x86_64.rpm")" = "$old" ]
    [ "$(cut -f2 "$TMP/h.map")" = "$old" ]
}

@test "a history map needs a tag, and a history file that is not in the map is an error" {
    need_deb
    pkgs deb
    printf 'v1.2.2\t%s\thello_1.2.2-1_amd64.deb\tsite\n' "$(sha "$P/deb/hello_1.2.2-1_amd64.deb")" > "$TMP/h.map"
    build --history-map "$TMP/h.map"
    assert_status 1
    assert_output_contains "--history-map needs --tag"
    # site-build.sh on its own: a history file the map doesn't name.
    mkdir -p "$TMP/cur" "$TMP/hist"
    cp "$P/deb/hello_1.2.3-1_amd64.deb" "$TMP/cur/"
    cp "$P/deb/hello_1.2.2-1_amd64.deb" "$TMP/hist/"
    printf 'v1.2.2\t%s\tother.deb\tsite\n' "$(printf x | sha256sum | cut -d' ' -f1)" > "$TMP/other.map"
    sbuild() { run "$LIB/site-build.sh" --packages "$TMP/cur" --out "$TMP/site" --base-url "file://$TMP/site" --version 1.2.3 --name hello "$@"; }
    sbuild --tag v1.2.3 --history "$TMP/hist" --history-map "$TMP/other.map"
    assert_status 1
    assert_output_contains "is not in the history map"
    sbuild --tag v1.2.3 --history "$TMP/hist"
    assert_status 1
    assert_output_contains "must be given together"
    sbuild --history "$TMP/hist" --history-map "$TMP/h.map"
    assert_status 1
    assert_output_contains "--history needs --tag"
    sbuild --tag v1.2.3 --history "$TMP/hist" --history-map "$TMP/h.map"
    assert_status 0
    mline release v1.2.2 "$P/deb/hello_1.2.2-1_amd64.deb" deb/pool/main/h/hello/hello_1.2.2-1_amd64.deb
    mline release v1.2.3 "$P/deb/hello_1.2.3-1_amd64.deb" deb/pool/main/h/hello/hello_1.2.3-1_amd64.deb
}

@test "a package named <name>-keyring is refused, .deb and .rpm alike" {
    need_both
    pkgs deb rpm
    "$FIXTURES" deb "$TMP/kr" hello-keyring 1.2.3-1 amd64
    cp "$TMP/kr"/*.deb "$TMP/pkgs/"
    build
    assert_status 1
    assert_output_contains "hello-keyring"
    assert_output_contains "reserves"
    rm -f "$TMP/pkgs"/hello-keyring*
    "$FIXTURES" rpm "$TMP/kr2" hello-keyring 1.2.3 noarch
    cp "$TMP/kr2"/*.rpm "$TMP/pkgs/"
    build --keyring-package false
    assert_status 1
    assert_output_contains "reserves"
}

@test "keyring package: published with the packages, named by the .list and the landing page" {
    need_deb
    need gpgv
    pkgs deb
    build_signed --tag v1.2.3 --keyring-package true
    assert_status 0
    s="$TMP/site"
    kr="$(find "$s/deb/pool/main/h/hello-keyring" -name 'hello-keyring_*_all.deb')"
    [ -f "$kr" ]
    [ "$(cat "$s/deb/hello.list")" = "deb [signed-by=/usr/share/keyrings/hello-keyring.asc] file://$TMP/site/deb stable main" ]
    i="$s/index.html"
    grep -q "sudo curl -fsSLo /usr/share/keyrings/hello-keyring.asc file://$TMP/site/hello.asc" "$i"
    grep -q "sudo curl -fsSLo /etc/apt/sources.list.d/hello.list file://$TMP/site/deb/hello.list" "$i"
    grep -q 'sudo apt install hello-keyring hello hello-doc libhello1' "$i"
    grep -q "curl -fsSL file://$TMP/site/hello.asc | gpg --show-keys" "$i"
    refute grep -q 'install -d' "$i"
    refute grep -q '/etc/apt/keyrings' "$i"
    gzip -cd "$s/deb/dists/stable/main/binary-amd64/Packages.gz" | grep -qx 'Package: hello-keyring'
    # The last manifest line, in the shape the format gives it; the .deb holds the pin.
    [ "$(tail -n 1 "$s/pkg-pages.tsv")" = "$(printf 'keyring\t-\t%s\tdeb/pool/main/h/hello-keyring/%s' "$(sha "$kr")" "${kr##*/}")" ]
    dpkg-deb --fsys-tarfile "$kr" | tar -xOf - ./usr/share/keyrings/hello-keyring.asc | cmp - "$K/a/pin.asc"
    # Not asked for: the old key path, and no keyring package.
    rm -rf "$TMP/site"
    build_signed --tag v1.2.3
    assert_status 0
    [ ! -e "$TMP/site/deb/pool/main/h/hello-keyring" ]
    grep -q 'signed-by=/etc/apt/keyrings/hello.asc' "$TMP/site/deb/hello.list"
    grep -q 'sudo install -d -m 0755 /etc/apt/keyrings' "$TMP/site/index.html"
}

@test "keyring package: an unsigned site or one without .deb files gets a notice, not a failure" {
    need_both
    need gpgv rpmsign rpmkeys
    pkgs deb
    build --tag v1.2.3 --keyring-package true
    assert_status 0
    assert_output_contains "unsigned"
    [ ! -e "$TMP/site/deb/pool/main/h/hello-keyring" ]
    rm -rf "$TMP/site" "$TMP/pkgs"
    pkgs rpm
    build_signed --keyring-package true
    assert_status 0
    assert_output_contains "for APT"
    [ ! -e "$TMP/site/deb" ]
}

@test "keyring package: a history copy of the same version is kept instead of the fresh build" {
    need_deb
    need gpgv dpkg-deb
    pkgs deb
    build_signed --tag v1.2.3 --keyring-package true
    assert_status 0
    fresh="$(find "$TMP/site/deb/pool/main/h/hello-keyring" -name 'hello-keyring_*_all.deb')"
    # The live site's copy, other bytes (an extra file), the same version.
    dpkg-deb -R "$fresh" "$TMP/kr"
    printf 'x\n' > "$TMP/kr/usr/share/keyrings/extra"
    dpkg-deb --root-owner-group -Zgzip --build "$TMP/kr" "$TMP/pkgs/${fresh##*/}" > /dev/null
    kept="$(sha "$TMP/pkgs/${fresh##*/}")"
    [ "$kept" != "$(sha "$fresh")" ]
    printf -- '-\t%s\t%s\tsite\n' "$kept" "${fresh##*/}" > "$TMP/h.map"
    rm -rf "$TMP/site"
    build_signed --tag v1.2.4 --history-map "$TMP/h.map" --keyring-package true
    assert_status 0
    assert_output_contains "keeping the earlier hello-keyring"
    [ "$(sha "$TMP/site/deb/pool/main/h/hello-keyring/${fresh##*/}")" = "$kept" ]
    [ "$(grep -c $'^keyring\t' "$TMP/site/pkg-pages.tsv")" -eq 1 ]
    # Without --keyring-package the old copy is dropped, with a notice.
    rm -rf "$TMP/site"
    build_signed --tag v1.2.4 --history-map "$TMP/h.map"
    assert_status 0
    [ ! -e "$TMP/site/deb/pool/main/h/hello-keyring" ]
}

@test "a tampered manifest, a missing listing or a changed package fails site-check" {
    need_deb
    need gpgv
    pkgs deb
    build_signed --tag v1.2.3
    assert_status 0
    s="$TMP/site"
    check --public-key "$K/a/pin.asc"
    assert_status 0
    cp "$s/pkg-pages.tsv" "$TMP/tsv"
    # A line changed after signing.
    sed -i 's/^release\tv1.2.3\t[0-9a-f]\{4\}/release\tv1.2.3\tffff/' "$s/pkg-pages.tsv"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    cp "$TMP/tsv" "$s/pkg-pages.tsv"
    # The signature gone.
    mv "$s/pkg-pages.tsv.asc" "$TMP/tsv.asc"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    mv "$TMP/tsv.asc" "$s/pkg-pages.tsv.asc"
    # A package that no longer matches its line, and one the manifest doesn't list.
    p="$s/deb/pool/main/h/hello/hello_1.2.3-1_amd64.deb"
    cp "$p" "$TMP/orig.deb"
    printf 'x' >> "$p"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    assert_output_contains "does not match the SHA-256"
    cp "$TMP/orig.deb" "$p"
    cp "$p" "$s/deb/pool/main/h/hello/extra_1.0_all.deb"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    assert_output_contains "is not listed"
    rm "$s/deb/pool/main/h/hello/extra_1.0_all.deb"
    check --public-key "$K/a/pin.asc"
    assert_status 0
    # Against no pin, a signed site's manifest is wrong: its header names the key.
    check
    assert_status 1
    assert_output_contains "header"
}

@test "an unsigned site's manifest is checked too: the header, the lines and the files" {
    need_deb
    pkgs deb
    build --tag v1.2.3
    assert_status 0
    m="$TMP/site/pkg-pages.tsv"
    check
    assert_status 0
    cp "$m" "$TMP/tsv"
    sed -i 's/^release\tv1.2.3\t[0-9a-f]\{4\}/release\tv1.2.3\tffff/' "$m"
    check
    assert_status 1
    cp "$TMP/tsv" "$m"
    sed -i 's/^#pkg-pages-manifest\t1\thello/#pkg-pages-manifest\t1\tother/' "$m"
    check
    assert_status 1
    assert_output_contains "header"
    cp "$TMP/tsv" "$m"
    printf 'release\tv1\tnothex\tdeb/pool/x.deb\n' >> "$m"
    check
    assert_status 1
    assert_output_contains "bad SHA-256"
    cp "$TMP/tsv" "$m"
    printf 'release\tv1\t%s\tdeb/pool/../x.deb\n' "$(printf x | sha256sum | cut -d' ' -f1)" >> "$m"
    check
    assert_status 1
    assert_output_contains "bad path"
    cp "$TMP/tsv" "$m"
    sed -n '1,2p' "$TMP/tsv" > "$m"
    check
    assert_status 1
    assert_output_contains "not listed"
}

@test "the stages work alone: site-build holds no key, site-seal signs, site-check passes" {
    need_deb
    need gpgv
    pkgs deb
    run "$LIB/site-build.sh" --packages "$TMP/pkgs" --out "$TMP/site" --base-url "file://$TMP/site" \
        --version 1.2.3 --name hello --tag v1.2.3 --public-key "$K/a/pin.asc"
    assert_status 0
    [ "$(output_value signed)" = true ]
    [ "$(output_value to-sign)" = "$TMP/site.to-sign" ]
    [ "$(cat "$TMP/site.to-sign")" = $'deb/dists/stable/Release\npkg-pages.tsv' ]
    [ ! -e "$TMP/site/deb/dists/stable/InRelease" ]
    # The directory listing already names the signatures that are still to come.
    grep -q 'href="InRelease"' "$TMP/site/deb/dists/stable/index.html"
    grep -q 'href="Release.gpg"' "$TMP/site/deb/dists/stable/index.html"
    check --public-key "$K/a/pin.asc"
    assert_status 1
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/site-seal.sh" --site "$TMP/site" --to-sign "$TMP/site.to-sign" --public-key "$K/a/pin.asc" --import-key true
    assert_status 0
    check --public-key "$K/a/pin.asc"
    assert_status 0
    [ -s "$TMP/site/deb/dists/stable/InRelease" ]
}

@test "site-build refuses an unsigned .rpm when the pin exists, and a key that is not alone in the keyring dir" {
    need_rpm
    need gpg rpmkeys
    pkgs rpm
    run "$LIB/site-build.sh" --packages "$TMP/pkgs" --out "$TMP/site" --base-url "file://$TMP/site" \
        --version 1.2.3 --name hello --public-key "$K/a/pin.asc"
    assert_status 1
    assert_output_contains "is not signed by public-key"
    [ ! -e "$TMP/site" ]
    run "$LIB/site-build.sh" --packages "$TMP/pkgs" --out "$TMP/site" --base-url "file://$TMP/site" \
        --version 1.2.3 --name hello --keyring "$TMP"
    assert_status 1
    assert_output_contains "--keyring needs --public-key"
}

@test "site-build wants exactly one <name>-keyring_<version>_all.deb in the keyring directory" {
    need_deb
    need gpg dpkg-deb
    pkgs deb
    GITHUB_OUTPUT='' "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name hello --out "$TMP/kr" 2> /dev/null
    sb() { run "$LIB/site-build.sh" --packages "$TMP/pkgs" --out "$TMP/site" --base-url "file://$TMP/site" \
        --version 1.2.3 --name hello --public-key "$K/a/pin.asc" --keyring "$TMP/kr"; }
    sb
    assert_status 0
    rm -rf "$TMP/site" "$TMP/site.to-sign"
    printf 'junk\n' > "$TMP/kr/junk.txt"
    sb
    assert_status 1
    assert_output_contains "exactly one file"
    rm "$TMP/kr/junk.txt"
    mv "$TMP/kr"/*.deb "$TMP/kr/other_1.0_all.deb"
    sb
    assert_status 1
    assert_output_contains "not hello-keyring_<version>_all.deb"
}

# --- The key dnf imports ---------------------------------------------------------------------

# rot_keys: once per file, two keys that need the dnf key to differ from the pin:
#   r  subkey 1 revoked, subkey 2 added: pin-rotated.asc, and ci2.asc (subkey 2 alone)
#   x  a signing subkey that expired (made in a faked 2020), then a valid one: pin.asc, ci.asc
rot_keys() {
    need gpg
    [ ! -d "$K/x" ] || return 0
    g() { home="$1"; shift; gpg --homedir "$home" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"; }
    "$FIXTURES" key "$K/r" "project r"
    fpr="$(cat "$K/r/fpr")"
    sleep 1
    printf 'key 1\nrevkey\ny\n0\n\ny\nsave\n' |
        gpg --homedir "$K/r/home" --batch --pinentry-mode loopback --passphrase '' \
            --command-fd 0 --status-fd 2 --edit-key "$fpr" 2> /dev/null
    g "$K/r/home" --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    sub2="$(g "$K/r/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" && $2 != "r" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g "$K/r/home" --armor --export "$fpr" > "$K/r/pin-rotated.asc"
    g "$K/r/home" --armor --export-secret-subkeys "$sub2!" > "$K/r/ci2.asc"
    printf '%s\n' "$sub2" > "$K/r/sub2"

    mkdir -p "$K/x/home" && chmod 700 "$K/x/home"
    old='--faked-system-time=20200101T000000!'
    g "$K/x/home" "$old" --quick-gen-key 'project x <x@example.invalid>' rsa2048 cert never 2> /dev/null
    fpr="$(g "$K/x/home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g "$K/x/home" "$old" --quick-add-key "$fpr" rsa2048 sign 1d 2> /dev/null
    g "$K/x/home" --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    sub2="$(g "$K/x/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "fpr" { f = $10 } END { print f }')"
    g "$K/x/home" --armor --export "$fpr" > "$K/x/pin.asc"
    g "$K/x/home" --armor --export-secret-subkeys "$sub2!" > "$K/x/ci.asc"
    printf '%s\n' "$sub2" > "$K/x/sub2"
}

# build_keyed PIN CI [OPTION]...: build_signed with another key.
build_keyed() {
    pin="$1" ci="$2"
    shift 2
    if [ -d "$TMP/gnupg" ]; then
        gpgconf --homedir "$TMP/gnupg" --kill all > /dev/null 2>&1 || true
        rm -rf "$TMP/gnupg"
    fi
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$ci")"
    export REPO_SIGNING_KEY
    build --public-key "$pin" --import-key true "$@"
}

# colons FILE: the --with-colons listing of a public key file.
colons() { gpg --batch --with-colons --show-keys "$1" 2> /dev/null; }

@test "dnf key: a revoked subkey is left out, the current one is in, and everything verifies against it alone" {
    need_rpm
    need gpgv rpmsign rpmkeys
    rot_keys
    pkgs rpm
    build_keyed "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    s="$TMP/site"
    key="$s/rpm/RPM-GPG-KEY-hello"
    # The pin is published whole, for APT and for revocations; the dnf key only without revoked subkeys.
    cmp "$s/hello.asc" "$K/r/pin-rotated.asc"
    [ "$(colons "$K/r/pin-rotated.asc" | grep -c '^sub:r')" -eq 1 ]
    refute grep -q '^sub:r' <<< "$(colons "$key")"
    [ "$(colons "$key" | grep -c '^pub:')" -eq 1 ]
    [ "$(colons "$key" | grep -c '^sub:')" -eq 1 ]
    gpg --batch --with-colons --with-subkey-fingerprints --show-keys "$key" | grep -q "$(cat "$K/r/sub2")"
    grep -qx "gpgkey=file://$TMP/site/rpm/RPM-GPG-KEY-hello" "$s/rpm/hello.repo"
    # Every .rpm and repomd.xml.asc, against that file alone.
    "$LIB/linux-signing.sh" --pin "$key" check-rpm "$s"/rpm/*/*.rpm
    gpg --batch --dearmor < "$key" > "$TMP/key.gpg"
    gpgv --keyring "$TMP/key.gpg" "$s/rpm/x86_64/repodata/repomd.xml.asc" "$s/rpm/x86_64/repodata/repomd.xml"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 0
}

@test "dnf key: an expired subkey is dropped" {
    need_rpm
    need gpgv rpmsign rpmkeys
    rot_keys
    pkgs rpm
    build_keyed "$K/x/pin.asc" "$K/x/ci.asc"
    assert_status 0
    key="$TMP/site/rpm/RPM-GPG-KEY-hello"
    [ "$(colons "$K/x/pin.asc" | grep -c '^sub:e')" -eq 1 ]
    refute grep -q '^sub:e' <<< "$(colons "$key")"
    [ "$(colons "$key" | grep -c '^sub:')" -eq 1 ]
    gpg --batch --with-colons --with-subkey-fingerprints --show-keys "$key" | grep -q "$(cat "$K/x/sub2")"
}

@test "dnf key: the same pin gives a byte-identical file, and an unsigned site has none" {
    need_rpm
    need gpgv rpmsign rpmkeys
    rot_keys
    pkgs rpm
    build_keyed "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    cp "$TMP/site/rpm/RPM-GPG-KEY-hello" "$TMP/key1"
    rm -rf "$TMP/site"
    build_keyed "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    cmp "$TMP/key1" "$TMP/site/rpm/RPM-GPG-KEY-hello"
    rm -rf "$TMP/site"
    unset GNUPGHOME REPO_SIGNING_KEY
    build
    assert_status 0
    [ ! -e "$TMP/site/rpm/RPM-GPG-KEY-hello" ]
    refute grep -q '^gpgkey=' "$TMP/site/rpm/hello.repo"
}

@test "dnf key: a tampered key file, the whole pin in its place, or another gpgkey line fails site-check" {
    need_rpm
    need gpgv rpmsign rpmkeys
    rot_keys
    pkgs rpm
    build_keyed "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    s="$TMP/site"
    key="$s/rpm/RPM-GPG-KEY-hello"
    cp "$key" "$TMP/key"
    # The whole pin, revoked subkey and all: what rpm 4.16 can't import.
    cp "$K/r/pin-rotated.asc" "$key"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 1
    assert_output_contains "RPM-GPG-KEY-hello"
    # Another key's file.
    cp "$K/b/pin.asc" "$key"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 1
    # A byte added, and the file gone.
    cp "$TMP/key" "$key"
    printf '\n' >> "$key"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 1
    rm "$key"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 1
    cp "$TMP/key" "$key"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 0
    # The .repo pointing at the whole pin instead.
    sed -i "s|^gpgkey=.*|gpgkey=file://$TMP/site/hello.asc|" "$s/rpm/hello.repo"
    check --public-key "$K/r/pin-rotated.asc"
    assert_status 1
    assert_output_contains "gpgkey="
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

@test "signed build: no tool but the import sees the key in its environment" {
    need_both
    need gpgv rpmsign rpmkeys
    pkgs deb rpm
    mkdir -p "$TMP/wrap"
    for t in dpkg-deb apt-ftparchive createrepo_c; do
        printf '#!/bin/sh\nenv >> "%s"\nexec "%s" "$@"\n' "$TMP/tools.env" "$(command -v "$t")" > "$TMP/wrap/$t"
        chmod +x "$TMP/wrap/$t"
    done
    PATH="$TMP/wrap:$PATH" build_signed
    assert_status 0
    [ -s "$TMP/tools.env" ]
    refute grep -q '^REPO_SIGNING_KEY=' "$TMP/tools.env"
}

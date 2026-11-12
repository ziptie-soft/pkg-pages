#!/usr/bin/env bats
# lib/package-rust.sh on the fixture crate tests/fixtures/hello-rust. The builds need cargo,
# cargo-deb and cargo-generate-rpm (any version: the tests pass the installed ones and never
# install anything); the CI `package-rust` job runs the action itself. Validation runs anywhere.

load helpers

setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    export GITHUB_OUTPUT="$TMP/github_output"
    : > "$GITHUB_OUTPUT"
    cp -R "$ROOT/tests/fixtures/hello-rust" "$TMP/crate"
    rm -rf "$TMP/crate/target"
    cd "$TMP/crate" || return 1
}

teardown() {
    cd /
    rm -rf "$TMP"
}

need_cargo_tools() {
    need cargo cargo-deb cargo-generate-rpm
    DEB_V="$(cargo-deb --version | awk '{ print $NF }')"
    RPM_V="$(cargo-generate-rpm --version | awk '{ print $NF }')"
}

pkg() {
    run "$LIB/package-rust.sh" --install-tools false \
        --cargo-deb-version "$DEB_V" --cargo-generate-rpm-version "$RPM_V" "$@"
}

@test "builds a .deb and an .rpm with the crate version and reports them" {
    need_cargo_tools
    pkg
    assert_status 0
    [ "$(output_value version)" = 0.3.1 ]
    deb="$(output_value deb)"
    rpm="$(output_value rpm)"
    [ -f "$deb" ] && [ -f "$rpm" ]
    case "$deb" in dist/pkg-pages-hello_0.3.1*.deb) ;; *) false ;; esac
    case "$rpm" in dist/pkg-pages-hello-0.3.1-*.rpm) ;; *) false ;; esac
    [ -n "$(output_value deb-arch)" ]
    [ -n "$(output_value rpm-arch)" ]
}

@test "the packages hold the binary" {
    need_cargo_tools
    need rpm
    pkg --formats rpm
    assert_status 0
    rpm -qlp "$(output_value rpm)" | grep -qx /usr/bin/pkg-pages-hello
}

@test "a version override reaches both packages; '-' becomes '~' in the .rpm" {
    need_cargo_tools
    need rpm
    pkg --version 0.4.0-rc.1 --out out
    assert_status 0
    [ "$(output_value version)" = 0.4.0-rc.1 ]
    [ "$(rpm -qp --qf '%{VERSION}' "$(output_value rpm)")" = '0.4.0~rc.1' ]
    case "$(output_value deb)" in out/pkg-pages-hello_0.4.0-rc.1_*.deb) ;; *) false ;; esac
}

@test "formats deb builds only the .deb" {
    need_cargo_tools
    pkg --formats deb
    assert_status 0
    [ -n "$(output_value deb)" ]
    [ -z "$(output_value rpm)" ]
}

@test "build false packages what is already built, and fails when nothing is" {
    need_cargo_tools
    pkg --build false --formats rpm
    assert_status 1
    cargo build --release --locked --quiet
    pkg --build false --formats rpm
    assert_status 0
}

@test "a tool of another version is refused unless install-tools is on" {
    need cargo
    run "$LIB/package-rust.sh" --install-tools false --cargo-deb-version 0.0.1 --formats deb --build false
    assert_status 1
    assert_output_contains "want 0.0.1"
}

@test "input validation" {
    v() { run "$LIB/package-rust.sh" --install-tools false "$@"; assert_status 1; }
    v --formats zip
    v --formats ''
    v --out /tmp/dist
    v --out ../dist
    v --version '1.0 beta'
    v --package 'a;b'
    v --target 'x86_64 --evil'
    v --build maybe
    v --cargo-deb-version latest
    v --unknown 1
}

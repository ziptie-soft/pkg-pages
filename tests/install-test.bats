#!/usr/bin/env bats
# lib/install-test.sh: what runs inside the install-test container. The installs need root and a
# throwaway system (tests/container.sh); the argument checks run anywhere.

load helpers

setup_file() {
    keys
    if command -v dpkg-deb > /dev/null; then "$FIXTURES" deb "$BATS_FILE_TMPDIR/deb" pptest 1.0.0 all; fi
    if command -v rpmbuild > /dev/null; then "$FIXTURES" rpm "$BATS_FILE_TMPDIR/rpm" pptest 1.0.0 noarch; fi
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

@test "refuses mixed .deb and .rpm, other files and missing files" {
    touch "$TMP/a.deb" "$TMP/b.rpm" "$TMP/c.tar.gz"
    run "$LIB/install-test.sh" "$TMP/a.deb" "$TMP/b.rpm"
    assert_status 1
    assert_output_contains "separate tests"
    run "$LIB/install-test.sh" "$TMP/c.tar.gz"
    assert_status 1
    run "$LIB/install-test.sh" "$TMP/missing.deb"
    assert_status 1
    run "$LIB/install-test.sh"
    assert_status 1
}

@test "installs a .deb with apt-get and runs the smoke command" {
    need_system
    need apt-get dpkg-deb
    PKG_PAGES_SMOKE='test -f /usr/share/pptest/1.0.0; echo smoke-ran' \
        run "$LIB/install-test.sh" --pin "$TMP/absent.asc" "$BATS_FILE_TMPDIR"/deb/*.deb
    assert_status 0
    assert_output_contains smoke-ran
    apt-get remove -y -qq pptest > /dev/null
}

@test "installs only the packages for the container's architecture" {
    need_system
    need apt-get dpkg-deb
    native="$(dpkg --print-architecture)"
    other=arm64
    [ "$native" != arm64 ] || other=amd64
    "$FIXTURES" deb "$TMP/d" ppnative 1.0.0 "$native"
    "$FIXTURES" deb "$TMP/d" ppnative 1.0.0 "$other"
    PKG_PAGES_SMOKE='test -f /usr/share/ppnative/1.0.0' run "$LIB/install-test.sh" "$TMP"/d/*.deb
    assert_status 0
    assert_output_contains "skipping ppnative_1.0.0_$other.deb"
    apt-get remove -y -qq ppnative > /dev/null
    run "$LIB/install-test.sh" "$TMP/d/ppnative_1.0.0_$other.deb"
    assert_status 1
    assert_output_contains "none of the packages is for $native"
}

@test "a failing smoke command fails the test" {
    need_system
    need apt-get dpkg-deb
    PKG_PAGES_SMOKE='false' run "$LIB/install-test.sh" "$BATS_FILE_TMPDIR"/deb/*.deb
    assert_status 1
    apt-get remove -y -qq pptest > /dev/null
}

@test ".rpm on an apt system is refused" {
    need_system
    need apt-get
    command -v dnf > /dev/null && skip "this image has dnf"
    touch "$TMP/x.rpm"
    run "$LIB/install-test.sh" "$TMP/x.rpm"
    assert_status 1
    assert_output_contains "need an image with dnf"
}

@test "installs a signed .rpm with dnf after checking it against the pin" {
    need_system
    need dnf rpmbuild rpmsign
    mkdir -p "$TMP/rpm"
    cp "$BATS_FILE_TMPDIR"/rpm/*.rpm "$TMP/rpm/"
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpm/*.rpm 2> /dev/null
    PKG_PAGES_SMOKE='test -f /usr/share/pptest/1.0.0' run "$LIB/install-test.sh" --pin "$K/a/pin.asc" "$TMP"/rpm/*.rpm
    assert_status 0
    dnf remove -y -q pptest
}

@test "an unsigned .rpm fails when the pin exists, and installs with a notice when it doesn't" {
    need_system
    need dnf rpmbuild
    run "$LIB/install-test.sh" --pin "$K/a/pin.asc" "$BATS_FILE_TMPDIR"/rpm/*.rpm
    assert_status 1
    assert_output_contains "is not signed"
    run "$LIB/install-test.sh" --pin "$TMP/absent.asc" "$BATS_FILE_TMPDIR"/rpm/*.rpm
    assert_status 0
    assert_output_contains "not checked"
    dnf remove -y -q pptest
}

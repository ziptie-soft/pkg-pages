#!/usr/bin/env bats
# lib/build-keyring.sh: the <name>-keyring .deb built from the pin; tests/container.sh runs this
# with dpkg-deb available.

load helpers

setup_file() {
    keys
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

# two_subkey_pin FILE: a copy of key a's certificate with a second signing subkey, as a rotation
# standby. Waits a little first, so that the new signature has a later creation time.
two_subkey_pin() {
    cp -r "$K/a/home" "$TMP/two"
    chmod 700 "$TMP/two"
    sleep 2
    gpg --homedir "$TMP/two" --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-add-key "$(cat "$K/a/fpr")" rsa2048 sign 3y 2> /dev/null
    gpg --homedir "$TMP/two" --armor --export "$(cat "$K/a/fpr")" > "$1"
    gpg --homedir "$TMP/two" --batch --quiet --kill all 2> /dev/null || true
}

@test "the version grows when a subkey is added, and is the same twice for one pin" {
    need dpkg-deb
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o1"
    assert_status 0
    v1="$(output_value version)"
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o2"
    assert_status 0
    [ "$(output_value version)" = "$v1" ]
    case "$v1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) printf 'bad version: %s\n' "$v1" >&2; return 1 ;;
    esac
    two_subkey_pin "$TMP/two.asc"
    run "$LIB/build-keyring.sh" --pin "$TMP/two.asc" --name site --out "$TMP/o3"
    assert_status 0
    v2="$(output_value version)"
    [ "$v2" \> "$v1" ]
}

@test "the .deb is byte-identical over two builds" {
    need dpkg-deb
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o1"
    assert_status 0
    sleep 2
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o2"
    assert_status 0
    f="$(basename "$(output_value deb)")"
    [ -f "$TMP/o1/$f" ]
    [ "$(sha "$TMP/o1/$f")" = "$(sha "$TMP/o2/$f")" ]
}

@test "the .deb holds the pin byte-identically, with the control fields" {
    need dpkg-deb
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o"
    assert_status 0
    deb="$(output_value deb)"
    v="$(output_value version)"
    [ "$(basename "$deb")" = "site-keyring_${v}_all.deb" ]
    mkdir "$TMP/x"
    dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$TMP/x"
    cmp "$K/a/pin.asc" "$TMP/x/usr/share/keyrings/site-keyring.asc"
    run dpkg-deb --field "$deb" Package Version Architecture Multi-Arch Section Maintainer
    assert_output_contains "Package: site-keyring"
    assert_output_contains "Version: $v"
    assert_output_contains "Architecture: all"
    assert_output_contains "Multi-Arch: foreign"
    assert_output_contains "Section: misc"
    assert_output_contains "Maintainer: pkg-pages <noreply@pkg-pages.invalid>"
}

@test "--out contains exactly the .deb named from the package version" {
    need dpkg-deb
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o"
    assert_status 0
    v="$(output_value version)"
    [ "$(basename "$(output_value deb)")" = "site-keyring_${v}_all.deb" ]
    [ "$(find "$TMP/o" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
    [ "$(find "$TMP/o" -mindepth 1 -maxdepth 1 -type f -printf '%f')" = "site-keyring_${v}_all.deb" ]
}

@test "a notice appears for a pin with one signing subkey, and not for two" {
    need dpkg-deb
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o1"
    assert_status 0
    assert_output_contains "fewer than two usable signing subkeys"
    two_subkey_pin "$TMP/two.asc"
    run "$LIB/build-keyring.sh" --pin "$TMP/two.asc" --name site --out "$TMP/o2"
    assert_status 0
    refute grep -q 'fewer than two' <<< "$output"
}

@test "refuses a bad name, the removed --formats option and a missing pin" {
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name 'Bad Name' --out "$TMP/o"
    assert_status 1
    assert_output_contains "name must match"
    run "$LIB/build-keyring.sh" --pin "$K/a/pin.asc" --name site --out "$TMP/o" --formats deb
    assert_status 1
    assert_output_contains "usage"
    run "$LIB/build-keyring.sh" --pin "$TMP/absent.asc" --name site --out "$TMP/o"
    assert_status 1
    assert_output_contains "does not exist"
    run "$LIB/build-keyring.sh" --name site --out "$TMP/o"
    assert_status 1
    assert_output_contains "usage"
    [ ! -e "$TMP/o" ]
}

@test "refuses a pin that holds secret key material" {
    run "$LIB/build-keyring.sh" --pin "$K/a/ci.asc" --name site --out "$TMP/o"
    assert_status 1
    assert_output_contains "secret key material"
}

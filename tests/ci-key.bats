#!/usr/bin/env bats
# tools/ci-key: exporting a CI signing subkey from a passphrase-protected offline key. Needs gpg.

load helpers

setup_file() {
    need gpg
    H="$BATS_FILE_TMPDIR/maint"
    mkdir -m 700 "$H"
    g() { gpg --homedir "$H" --batch --quiet --pinentry-mode loopback --passphrase 'correct horse' "$@"; }
    g --quick-gen-key 'maintainer <m@example.invalid>' rsa2048 cert never 2> /dev/null
    FPR="$(g --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g --quick-add-key "$FPR" rsa2048 sign 3y 2> /dev/null
    SUB="$(g --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g --armor --export "$FPR" > "$BATS_FILE_TMPDIR/pin.asc"
    export H FPR SUB
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

@test "exports the subkey alone, without a passphrase, and the import accepts it" {
    echo 'correct horse' | "$ROOT/tools/ci-key" --homedir "$H" "$SUB" > "$TMP/ci.asc" 2> /dev/null
    grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$TMP/ci.asc"
    # The primary is a stub (sec#) in the export: only the subkey's secret is there.
    mkdir -m 700 "$TMP/check"
    gpg --homedir "$TMP/check" --batch --quiet --import "$TMP/ci.asc"
    gpg --homedir "$TMP/check" --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" { exit $15 != "#" }'
    # And it signs without a passphrase, checked against the pin.
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$TMP/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$BATS_FILE_TMPDIR/pin.asc" import
    assert_status 0
}

@test "the maintainer's key keeps its passphrase" {
    echo 'correct horse' | "$ROOT/tools/ci-key" --homedir "$H" "$SUB" > /dev/null 2>&1
    run sh -c "echo probe | gpg --homedir '$H' --batch --pinentry-mode loopback --passphrase '' --local-user '$SUB!' --sign"
    [ "$status" -ne 0 ]
}

@test "a wrong passphrase fails without printing a key" {
    run sh -c "echo wrong | '$ROOT/tools/ci-key' --homedir '$H' '$SUB'"
    assert_status 1
    refute grep -q 'PRIVATE KEY' <<< "$output"
}

@test "refuses the primary's fingerprint, unknown keys and short IDs" {
    run sh -c "echo 'correct horse' | '$ROOT/tools/ci-key' --homedir '$H' '$FPR'"
    assert_status 1
    assert_output_contains "not a secret signing subkey"
    run "$ROOT/tools/ci-key" --homedir "$H" "$(printf '%040d' 0)"
    assert_status 1
    run "$ROOT/tools/ci-key" --homedir "$H" "${SUB#????????????????????????}"
    assert_status 1
    assert_output_contains "full fingerprint"
    run "$ROOT/tools/ci-key" --homedir "$H" 'not-hex'
    assert_status 1
    run "$ROOT/tools/ci-key"
    assert_status 1
}

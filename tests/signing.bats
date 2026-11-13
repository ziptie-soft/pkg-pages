#!/usr/bin/env bats
# lib/linux-signing.sh and lib/signing.sh: the fail-closed import (every row of the matrix in
# docs/signing.md), signing and checking .rpm files, rotation and revocation.
# Needs gpg; the .rpm tests also need rpmbuild, rpmsign and rpmkeys (tests/container.sh fedora).

load helpers

# The keys are generated once for the file (RSA generation is the slow part):
#   a, b        two projects' keys (helpers.bash keys)
#   r           a key whose first subkey gets revoked and replaced: rotation and revocation
#   v           a key revoked as a whole (the pin carries the revocation certificate)
#   w           a key with a newer signing subkey in the pin, the old one not revoked
#   x           a key with an expired subkey, and a subkey added after the pin was exported
#   p           a key whose subkey is passphrase-protected
setup_file() {
    keys
    g() { home="$1"; shift; gpg --homedir "$home" --batch --quiet --pinentry-mode loopback "$@"; }

    # r: revoke subkey 1 (the one in r/ci.asc), add subkey 2, export both pins.
    "$FIXTURES" key "$K/r" "project r"
    fpr="$(cat "$K/r/fpr")"
    printf 'key 1\nrevkey\ny\n0\n\ny\nsave\n' |
        gpg --homedir "$K/r/home" --batch --pinentry-mode loopback --passphrase '' \
            --command-fd 0 --status-fd 2 --edit-key "$fpr" 2> /dev/null
    g "$K/r/home" --passphrase '' --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    sub2="$(g "$K/r/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" && $2 != "r" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g "$K/r/home" --armor --export "$fpr" > "$K/r/pin-rotated.asc"
    g "$K/r/home" --passphrase '' --armor --export-secret-subkeys "$sub2!" > "$K/r/ci2.asc"

    # v: the whole key revoked, with the certificate gpg wrote when it made the key.
    "$FIXTURES" key "$K/v" "project v"
    fpr="$(cat "$K/v/fpr")"
    sed 's/^:-----BEGIN/-----BEGIN/' "$K/v/home/openpgp-revocs.d/$fpr.rev" | g "$K/v/home" --import 2> /dev/null
    g "$K/v/home" --armor --export "$fpr" > "$K/v/pin-revoked.asc"

    # w: rotation step 2: a newer signing subkey in the pin, the old one not revoked, CI still on the old.
    "$FIXTURES" key "$K/w" "project w"
    fpr="$(cat "$K/w/fpr")"
    sleep 1 # a later creation time, so the new subkey is the one gpg would prefer
    g "$K/w/home" --passphrase '' --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    g "$K/w/home" --armor --export "$fpr" > "$K/w/pin-both.asc"

    # x: made in 2020 (a faked clock: gpg won't date a subkey before its primary) with a signing
    # subkey valid for one day, so expired now. Then a subkey added after the pin was exported.
    mkdir -p "$K/x/home" && chmod 700 "$K/x/home"
    old='--faked-system-time=20200101T000000!'
    g "$K/x/home" --passphrase '' "$old" --quick-gen-key 'project x <x@example.invalid>' rsa2048 cert never 2> /dev/null
    fpr="$(g "$K/x/home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g "$K/x/home" --passphrase '' "$old" --quick-add-key "$fpr" rsa2048 sign 1d 2> /dev/null
    expired="$(g "$K/x/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g "$K/x/home" --armor --export "$fpr" > "$K/x/pin.asc"
    g "$K/x/home" --passphrase '' --armor --export-secret-subkeys "$expired!" > "$K/x/expired.asc"
    g "$K/x/home" --passphrase '' --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    unlisted="$(g "$K/x/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "fpr" { print $10 }' | tail -n 1)"
    g "$K/x/home" --passphrase '' --armor --export-secret-subkeys "$unlisted!" > "$K/x/unlisted.asc"

    # p: the subkey keeps its passphrase.
    mkdir -p "$K/p/home" && chmod 700 "$K/p/home"
    g "$K/p/home" --passphrase pw --quick-gen-key 'project p <p@example.invalid>' rsa2048 cert never 2> /dev/null
    fpr="$(g "$K/p/home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g "$K/p/home" --passphrase pw --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    sub="$(g "$K/p/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g "$K/p/home" --armor --export "$fpr" > "$K/p/pin.asc"
    g "$K/p/home" --passphrase pw --armor --export-secret-subkeys "$sub!" > "$K/p/ci.asc"

    # Test packages, when rpmbuild is there.
    if command -v rpmbuild > /dev/null; then
        "$FIXTURES" rpm "$BATS_FILE_TMPDIR/rpms" hello 1.0.0 noarch
        "$FIXTURES" rpm "$BATS_FILE_TMPDIR/rpms" hello-extra 1.0.0 noarch
    fi
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

# import PIN KEYFILE: run `linux-signing.sh import` with KEYFILE's contents as the secret (KEYFILE
# may be empty for "no secret") in a fresh GNUPGHOME.
import() {
    gnupg_home
    if [ -n "$2" ]; then REPO_SIGNING_KEY="$(cat "$2")"; else REPO_SIGNING_KEY=; fi
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$1" import
}

# rpms: copies of the test packages in $TMP/rpms.
rpms() {
    need rpmbuild rpmsign rpmkeys
    mkdir -p "$TMP/rpms"
    cp "$BATS_FILE_TMPDIR"/rpms/*.rpm "$TMP/rpms/"
}

# --- The fail-closed matrix ------------------------------------------------------------------

@test "no pin and no key: unsigned, with a notice, signed=false" {
    import "$TMP/absent.asc" ""
    assert_status 0
    assert_output_contains "unsigned"
    [ "$(output_value signed)" = false ]
    grep -qx PKG_PAGES_SIGNED=false "$GITHUB_ENV"
}

@test "the notice is a GitHub annotation in Actions" {
    GITHUB_ACTIONS=true import "$TMP/absent.asc" ""
    assert_status 0
    assert_output_contains "::notice::"
}

@test "no pin but a key: fails, asking to commit the public key" {
    import "$TMP/absent.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "commit the public key"
    [ -z "$(output_value signed)" ]
}

@test "a pin but no key: fails" {
    import "$K/a/pin.asc" ""
    assert_status 1
    assert_output_contains "signing-key is empty"
}

@test "a pin and its subkey: signed, with the primary fingerprint" {
    import "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 0
    [ "$(output_value signed)" = true ]
    [ "$(output_value fingerprint)" = "$(cat "$K/a/fpr")" ]
    grep -qx PKG_PAGES_SIGNED=true "$GITHUB_ENV"
    grep -qx "PKG_PAGES_FINGERPRINT=$(cat "$K/a/fpr")" "$GITHUB_ENV"
}

@test "the import puts nothing on stdout, so the key can't end up in a log by accident" {
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" import > "$TMP/stdout" 2> /dev/null
    [ ! -s "$TMP/stdout" ]
}

@test "another project's subkey: fails" {
    import "$K/a/pin.asc" "$K/b/ci.asc"
    assert_status 1
    assert_output_contains "but public-key"
}

@test "a subkey added after the pin was exported: fails until the new pin is committed" {
    import "$K/x/pin.asc" "$K/x/unlisted.asc"
    assert_status 1
    assert_output_contains "is not in public-key"
}

@test "an expired subkey: fails on the probe signature" {
    import "$K/x/pin.asc" "$K/x/expired.asc"
    assert_status 1
    assert_output_contains "can't sign"
}

@test "a revoked subkey: fails once the pin carries the revocation" {
    import "$K/r/pin-rotated.asc" "$K/r/ci.asc"
    assert_status 1
    assert_output_contains "can't sign"
}

@test "a revoked primary: fails once the pin carries the revocation" {
    import "$K/v/pin-revoked.asc" "$K/v/ci.asc"
    assert_status 1
    assert_output_contains "can't sign"
}

@test "rotation: the new subkey signs with the new pin" {
    import "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    [ "$(output_value signed)" = true ]
}

@test "rotation in the wrong order: the new subkey with the old pin fails" {
    import "$K/r/pin.asc" "$K/r/ci2.asc"
    assert_status 1
    assert_output_contains "is not in public-key"
}

@test "a passphrase-protected subkey: fails" {
    import "$K/p/pin.asc" "$K/p/ci.asc"
    assert_status 1
    assert_output_contains "can't sign"
}

@test "the primary's secret in CI: fails" {
    gpg --homedir "$K/a/home" --batch --pinentry-mode loopback --passphrase '' --armor \
        --export-secret-keys "$(cat "$K/a/fpr")" > "$TMP/full.asc"
    import "$K/a/pin.asc" "$TMP/full.asc"
    assert_status 1
    assert_output_contains "primary key's secret"
}

@test "two secret keys: fails" {
    cat "$K/a/ci.asc" "$K/b/ci.asc" > "$TMP/two.asc"
    import "$K/a/pin.asc" "$TMP/two.asc"
    assert_status 1
    assert_output_contains "2 secret keys"
}

@test "a secret that is not a key: fails" {
    printf 'not a key\n' > "$TMP/junk.asc"
    import "$K/a/pin.asc" "$TMP/junk.asc"
    assert_status 1
}

@test "a pin with two keys: fails" {
    cat "$K/a/pin.asc" "$K/b/pin.asc" > "$TMP/two-pins.asc"
    import "$TMP/two-pins.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "exactly one key"
}

@test "a pin that holds secret key material: fails" {
    import "$K/a/ci.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "secret key material"
}

@test "GNUPGHOME must be set, exist and be empty" {
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    unset GNUPGHOME
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" import
    assert_status 1
    export GNUPGHOME="$TMP/nope"
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" import
    assert_status 1
    gnupg_home
    touch "$GNUPGHOME/x"
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" import
    assert_status 1
    assert_output_contains "not empty"
}

@test "the pin defaults to PKG_PAGES_PIN" {
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY PKG_PAGES_PIN="$K/a/pin.asc"
    run "$LIB/linux-signing.sh" import
    assert_status 0
    [ "$(output_value signed)" = true ]
}

@test "usage errors" {
    run "$LIB/linux-signing.sh"
    assert_status 1
    run "$LIB/linux-signing.sh" frobnicate
    assert_status 1
    run "$LIB/linux-signing.sh" check-rpm
    assert_status 1
    run "$LIB/linux-signing.sh" check-rpm "$TMP/missing.rpm"
    assert_status 1
    touch "$TMP/x.deb"
    run "$LIB/linux-signing.sh" check-rpm "$TMP/x.deb"
    assert_status 1
}

# --- sign-rpm and check-rpm ------------------------------------------------------------------

@test "sign-rpm signs in place and check-rpm accepts the result" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    [ "$(output_value signed)" = true ]
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    [ "$(output_value checked)" = true ]
}

@test "rotation step 2: while the pin lists both subkeys, the old one keeps signing" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/w/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$K/w/pin-both.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    "$LIB/linux-signing.sh" --pin "$K/w/pin-both.asc" check-rpm "$TMP"/rpms/*.rpm
}

@test "sign-rpm leaves already-signed files byte-identical" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm 2> /dev/null
    before="$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")"
    rm -rf "$GNUPGHOME"
    gnupg_home
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    assert_output_contains "already signed"
    [ "$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")" = "$before" ]
}

@test "sign-rpm replaces another key's signature" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/b/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/b/pin.asc" sign-rpm "$TMP"/rpms/*.rpm 2> /dev/null
    rm -rf "$GNUPGHOME"
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 0
}

@test "sign-rpm without pin and key leaves the files unsigned" {
    rpms
    gnupg_home
    before="$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")"
    run "$LIB/linux-signing.sh" --pin "$TMP/absent.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    [ "$(output_value signed)" = false ]
    [ "$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")" = "$before" ]
}

@test "sign-rpm fails closed like import" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/b/ci.asc")"
    export REPO_SIGNING_KEY
    before="$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")"
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 1
    [ "$(sha "$TMP/rpms/hello-1.0.0-1.noarch.rpm")" = "$before" ]
}

@test "check-rpm rejects an unsigned package" {
    rpms
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 1
    assert_output_contains "is not signed by public-key"
}

@test "check-rpm rejects a package signed by another key" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/b/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/b/pin.asc" sign-rpm "$TMP"/rpms/*.rpm 2> /dev/null
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 1
}

@test "check-rpm rejects a package signed by a subkey the pin has since revoked" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/r/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/r/pin.asc" sign-rpm "$TMP"/rpms/*.rpm 2> /dev/null
    run "$LIB/linux-signing.sh" --pin "$K/r/pin.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    run "$LIB/linux-signing.sh" --pin "$K/r/pin-rotated.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 1
}

@test "check-rpm without a pin: passes with --allow-unsigned, fails without" {
    rpms
    run "$LIB/linux-signing.sh" --pin "$TMP/absent.asc" check-rpm --allow-unsigned "$TMP"/rpms/*.rpm
    assert_status 0
    [ "$(output_value checked)" = false ]
    run "$LIB/linux-signing.sh" --pin "$TMP/absent.asc" check-rpm "$TMP"/rpms/*.rpm
    assert_status 1
}

@test "check-rpm rejects a tampered package" {
    rpms
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm 2> /dev/null
    f="$TMP/rpms/hello-1.0.0-1.noarch.rpm"
    # Flip one byte near the end, in the payload.
    size="$(wc -c < "$f")"
    printf '\377' | dd of="$f" bs=1 seek="$((size - 20))" conv=notrunc 2> /dev/null
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$f"
    assert_status 1
}

@test "sign-rpm: rpmsign and rpmkeys run without the key in their environment" {
    rpms
    mkdir -p "$TMP/wrap"
    for t in rpmsign rpmkeys; do
        printf '#!/bin/sh\nenv >> "%s"\nexec "%s" "$@"\n' "$TMP/tools.env" "$(command -v "$t")" > "$TMP/wrap/$t"
        chmod +x "$TMP/wrap/$t"
    done
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$K/a/ci.asc")"
    export REPO_SIGNING_KEY
    PATH="$TMP/wrap:$PATH" run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-rpm "$TMP"/rpms/*.rpm
    assert_status 0
    [ -s "$TMP/tools.env" ]
    refute grep -q '^REPO_SIGNING_KEY=' "$TMP/tools.env"
}

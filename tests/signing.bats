#!/usr/bin/env bats
# lib/linux-signing.sh and lib/signing.sh: the fail-closed import (every row of the matrix in
# docs/signing.md), signing and checking .rpm files, rotation and revocation.
# Needs gpg; the .rpm tests also need rpmbuild, rpmsign and rpmkeys (tests/container.sh fedora).
# sign-history, which keeps earlier releases' .rpm files signed by the current subkey, is covered
# at the end.

load helpers

# The keys are generated once for the file (RSA generation is the slow part):
#   a, b        two projects' keys (helpers.bash keys)
#   r           a key whose first subkey gets revoked and replaced: rotation and revocation
#   v           a key revoked as a whole (the pin carries the revocation certificate)
#   w           a key with a newer signing subkey in the pin, the old one not revoked (w/sub2 is the
#               newer one; w/ci2.asc and w/ci-both.asc are secrets for the newer and for both)
#   x           a key with an expired subkey, and a subkey added after the pin was exported
#   p           a key whose subkey is passphrase-protected
setup_file() {
    keys
    g() { home="$1"; shift; gpg --homedir "$home" --batch --quiet --pinentry-mode loopback "$@"; }
    # sig NAME HOME SUBKEY [GPG ARGS]: a detached signature of $K/data.txt by exactly SUBKEY, in
    # $K/NAME.asc (made before a revocation, or at a faked time, for the gpg_verify tests).
    printf 'hello world\n' > "$K/data.txt"
    sig() {
        n="$1" home="$2" sub="$3"
        shift 3
        g "$home" --passphrase '' "$@" --local-user "$sub!" --armor --detach-sign --output "$K/$n.asc" "$K/data.txt"
    }
    sig valid "$K/a/home" "$(cat "$K/a/sub")"
    sig other "$K/b/home" "$(cat "$K/b/sub")"

    # r: revoke subkey 1 (the one in r/ci.asc), add subkey 2, export both pins.
    "$FIXTURES" key "$K/r" "project r"
    fpr="$(cat "$K/r/fpr")"
    sig revsub "$K/r/home" "$(cat "$K/r/sub")"
    sleep 1
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
    sig revprimary "$K/v/home" "$(cat "$K/v/sub")"
    sleep 1
    sed 's/^:-----BEGIN/-----BEGIN/' "$K/v/home/openpgp-revocs.d/$fpr.rev" | g "$K/v/home" --import 2> /dev/null
    g "$K/v/home" --armor --export "$fpr" > "$K/v/pin-revoked.asc"

    # w: rotation step 2: a newer signing subkey in the pin, the old one not revoked, CI still on the old.
    "$FIXTURES" key "$K/w" "project w"
    fpr="$(cat "$K/w/fpr")"
    sleep 1 # a later creation time, so the new subkey is the one gpg would prefer
    g "$K/w/home" --passphrase '' --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    g "$K/w/home" --armor --export "$fpr" > "$K/w/pin-both.asc"
    sub1="$(cat "$K/w/sub")"
    g "$K/w/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; s = 0 }' |
        grep -vxF "$sub1" > "$K/w/sub2"
    sub2="$(cat "$K/w/sub2")"
    # gpg exports every subkey whatever "SUB!" says, so the newer subkey's secret alone comes from
    # a copy of the home that has lost the older one's.
    g "$K/w/home" --passphrase '' --armor --export-secret-subkeys "$fpr" > "$K/w/ci-both.asc"
    g "$K/w/home" --passphrase '' --armor --export-filter "drop-subkey=fpr = $sub1" \
        --export-secret-subkeys "$fpr" > "$K/w/ci2.asc"
    g "$K/w/home" --armor --export-options export-minimal --export-filter "drop-subkey=fpr = $sub1" \
        --export "$fpr" > "$K/w/pin-sub2.asc"

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
    sig expsubkey "$K/x/home" "$expired" --faked-system-time=20200101T120000!
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

    # s: a signing subkey that expires in 30 days, for the expiry warning.
    mkdir -p "$K/s/home" && chmod 700 "$K/s/home"
    g "$K/s/home" --passphrase '' --quick-gen-key 'project s <s@example.invalid>' rsa2048 cert never 2> /dev/null
    fpr="$(g "$K/s/home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    g "$K/s/home" --passphrase '' --quick-add-key "$fpr" rsa2048 sign 30d 2> /dev/null
    sub="$(g "$K/s/home" --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    g "$K/s/home" --armor --export "$fpr" > "$K/s/pin.asc"
    g "$K/s/home" --passphrase '' --armor --export-secret-subkeys "$sub!" > "$K/s/ci.asc"

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

# --- The expiry warning ------------------------------------------------------------------------

@test "import warns when the signing subkey expires within 90 days" {
    import "$K/s/pin.asc" "$K/s/ci.asc"
    assert_status 0
    assert_output_contains "warning:"
    assert_output_contains "expires in"
}

@test "import does not warn about a subkey that expires in three years" {
    import "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 0
    refute grep -q "expires in" <<< "$output"
}

# --- gpg_verify -------------------------------------------------------------------------------

# verify [--allow-expired] PIN SIG [DATA]: run gpg_verify in sh.
verify() {
    run sh -c ". '$LIB/common.sh'; . '$LIB/signing.sh'; gpg_verify \"\$@\"" sh "$@"
}

@test "gpg_verify accepts a valid signature, detached" {
    verify "$K/a/pin.asc" "$K/valid.asc" "$K/data.txt"
    assert_status 0
}

@test "gpg_verify accepts a valid clearsigned file" {
    gnupg_home
    gpg --batch --quiet --import "$K/a/ci.asc" 2> /dev/null
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' --local-user "$(cat "$K/a/sub")!" \
        --clearsign --output "$TMP/clear.asc" "$K/data.txt"
    unset GNUPGHOME
    verify "$K/a/pin.asc" "$TMP/clear.asc"
    assert_status 0
}

@test "gpg_verify refuses a subkey revoked after it signed" {
    verify "$K/r/pin-rotated.asc" "$K/revsub.asc" "$K/data.txt"
    assert_status 1
    assert_output_contains "REVKEYSIG"
}

@test "gpg_verify refuses a signature by a revoked primary" {
    verify "$K/v/pin-revoked.asc" "$K/revprimary.asc" "$K/data.txt"
    assert_status 1
}

@test "gpg_verify refuses an expired subkey, and --allow-expired passes it with a warning" {
    verify "$K/x/pin.asc" "$K/expsubkey.asc" "$K/data.txt"
    assert_status 1
    assert_output_contains "expired subkey"
    verify --allow-expired "$K/x/pin.asc" "$K/expsubkey.asc" "$K/data.txt"
    assert_status 0
    assert_output_contains "warning:"
    assert_output_contains "expired subkey"
}

@test "gpg_verify never lets --allow-expired accept a revoked subkey" {
    verify --allow-expired "$K/r/pin-rotated.asc" "$K/revsub.asc" "$K/data.txt"
    assert_status 1
}

@test "gpg_verify refuses another key's signature" {
    verify "$K/a/pin.asc" "$K/other.asc" "$K/data.txt"
    assert_status 1
}

@test "gpg_verify refuses tampered data" {
    cp "$K/data.txt" "$TMP/data.txt"
    echo tamper >> "$TMP/data.txt"
    verify "$K/a/pin.asc" "$K/valid.asc" "$TMP/data.txt"
    assert_status 1
    assert_output_contains "does not verify"
}

# --- sign-history ------------------------------------------------------------------------------

# hist: two unsigned history packages, $TMP/hist/v1/... and $TMP/hist/v2/....
H1=v1/hello-1.0.0-1.noarch.rpm
H2=v2/hello-extra-1.0.0-1.noarch.rpm
hist() {
    rpms
    mkdir -p "$TMP/hist/v1" "$TMP/hist/v2"
    cp "$TMP/rpms/hello-1.0.0-1.noarch.rpm" "$TMP/hist/v1/"
    cp "$TMP/rpms/hello-extra-1.0.0-1.noarch.rpm" "$TMP/hist/v2/"
}

# sign_as PIN KEYFILE REL...: sign $TMP/hist/REL... with the key, in a GNUPGHOME of its own.
sign_as() {
    _pin="$1" _key="$2"
    shift 2
    gnupg_home
    for _rel in "$@"; do set -- "$@" "$TMP/hist/$_rel"; shift; done
    REPO_SIGNING_KEY="$(cat "$_key")" "$LIB/linux-signing.sh" --pin "$_pin" sign-rpm "$@" 2> /dev/null
    kill_agents "$GNUPGHOME"
    rm -rf "$GNUPGHOME"
}

# write_map SOURCE1 SOURCE2: $TMP/map for the two packages as they are now.
write_map() {
    printf 'v1\t%s\t%s\t%s\nv2\t%s\t%s\t%s\n' \
        "$(sha "$TMP/hist/$H1")" "$H1" "$1" "$(sha "$TMP/hist/$H2")" "$H2" "$2" > "$TMP/map"
}

# map_sha REL: the SHA-256 the map holds for REL.
map_sha() {
    awk -F'\t' -v p="$1" '$3 == p { print $2 }' "$TMP/map"
}

# history_run PIN KEYFILE [ARGS...]: sign-history over the map and $TMP/hist.
history_run() {
    _pin="$1" _key="$2"
    shift 2
    rm -rf "$TMP/gnupg"
    gnupg_home
    REPO_SIGNING_KEY="$(cat "$_key")"
    export REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$_pin" sign-history --map "$TMP/map" "$@" "$TMP/hist"
}

@test "sign-history leaves files that the current subkey signed byte-identical, and the map too" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    write_map site release
    cp "$TMP/map" "$TMP/map.before"
    before1="$(sha "$TMP/hist/$H1")"
    before2="$(sha "$TMP/hist/$H2")"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 0
    [ "$(output_value signed)" = true ]
    assert_output_contains "signed by the current subkey"
    [ "$(sha "$TMP/hist/$H1")" = "$before1" ]
    [ "$(sha "$TMP/hist/$H2")" = "$before2" ]
    cmp "$TMP/map" "$TMP/map.before"
}

@test "sign-history signs a site file again after the subkey rotated, and updates the map" {
    hist
    sign_as "$K/r/pin.asc" "$K/r/ci.asc" "$H1"
    sign_as "$K/r/pin-rotated.asc" "$K/r/ci2.asc" "$H2"
    write_map site site
    old1="$(sha "$TMP/hist/$H1")"
    old2="$(sha "$TMP/hist/$H2")"
    # Before: the rotated pin refuses H1, which the revoked subkey signed.
    run "$LIB/linux-signing.sh" --pin "$K/r/pin-rotated.asc" check-rpm "$TMP/hist/$H1"
    assert_status 1
    history_run "$K/r/pin-rotated.asc" "$K/r/ci2.asc"
    assert_status 0
    assert_output_contains "$H1"
    assert_output_contains "signing it again"
    "$LIB/linux-signing.sh" --pin "$K/r/pin-rotated.asc" check-rpm "$TMP/hist/$H1" "$TMP/hist/$H2"
    [ "$(sha "$TMP/hist/$H1")" != "$old1" ]
    [ "$(sha "$TMP/hist/$H2")" = "$old2" ]
    [ "$(map_sha "$H1")" = "$(sha "$TMP/hist/$H1")" ]
    [ "$(map_sha "$H2")" = "$old2" ]
    # The map keeps its shape: four fields a line, the tags and the sources as they were.
    [ "$(awk -F'\t' 'NF == 4' "$TMP/map" | wc -l)" -eq 2 ]
    [ "$(cut -f1,3,4 "$TMP/map" | tr '\t' ' ' | tr '\n' ';')" = "v1 $H1 site;v2 $H2 site;" ]
}

@test "sign-history signs a release file again when another subkey of the pin signed it" {
    hist
    sign_as "$K/w/pin-both.asc" "$K/w/ci.asc" "$H1"
    sign_as "$K/w/pin-both.asc" "$K/w/ci2.asc" "$H2"
    write_map release release
    old1="$(sha "$TMP/hist/$H1")"
    old2="$(sha "$TMP/hist/$H2")"
    # Both verify against the whole pin, but only H2 against the newer subkey alone.
    run "$LIB/linux-signing.sh" --pin "$K/w/pin-sub2.asc" check-rpm "$TMP/hist/$H1"
    assert_status 1
    history_run "$K/w/pin-both.asc" "$K/w/ci2.asc"
    assert_status 0
    refute grep -q "nothing proves" <<< "$output"
    "$LIB/linux-signing.sh" --pin "$K/w/pin-sub2.asc" check-rpm "$TMP/hist/$H1" "$TMP/hist/$H2"
    [ "$(sha "$TMP/hist/$H1")" != "$old1" ]
    [ "$(sha "$TMP/hist/$H2")" = "$old2" ]
    [ "$(map_sha "$H1")" = "$(sha "$TMP/hist/$H1")" ]
}

@test "sign-history holding two subkeys: a file that either signed stays as it is" {
    hist
    sign_as "$K/w/pin-both.asc" "$K/w/ci.asc" "$H1"
    sign_as "$K/w/pin-both.asc" "$K/w/ci2.asc" "$H2"
    write_map release release
    old1="$(sha "$TMP/hist/$H1")"
    old2="$(sha "$TMP/hist/$H2")"
    history_run "$K/w/pin-both.asc" "$K/w/ci-both.asc"
    assert_status 0
    [ "$(sha "$TMP/hist/$H1")" = "$old1" ]
    [ "$(sha "$TMP/hist/$H2")" = "$old2" ]
}

@test "sign-history refuses an unsigned release file, and changes nothing" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H2"
    write_map release release
    cp "$TMP/map" "$TMP/map.before"
    old1="$(sha "$TMP/hist/$H1")"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "nothing proves its bytes"
    assert_output_contains "resign-history"
    [ "$(sha "$TMP/hist/$H1")" = "$old1" ]
    cmp "$TMP/map" "$TMP/map.before"
    history_run "$K/a/pin.asc" "$K/a/ci.asc" --resign-unproven false
    assert_status 1
}

@test "sign-history refuses a release file that another project's key signed" {
    hist
    sign_as "$K/b/pin.asc" "$K/b/ci.asc" "$H1"
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H2"
    write_map release release
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "nothing proves its bytes"
}

@test "sign-history --resign-unproven true signs it anyway, with a warning, and updates the map" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H2"
    write_map release release
    old1="$(sha "$TMP/hist/$H1")"
    old2="$(sha "$TMP/hist/$H2")"
    history_run "$K/a/pin.asc" "$K/a/ci.asc" --resign-unproven true
    assert_status 0
    assert_output_contains "warning:"
    assert_output_contains "$H1"
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP/hist/$H1" "$TMP/hist/$H2"
    [ "$(sha "$TMP/hist/$H1")" != "$old1" ]
    [ "$(map_sha "$H1")" = "$(sha "$TMP/hist/$H1")" ]
    [ "$(sha "$TMP/hist/$H2")" = "$old2" ]
    [ "$(map_sha "$H2")" = "$old2" ]
}

@test "sign-history trusts a site file whoever signed it, because the manifest proves its bytes" {
    hist
    sign_as "$K/b/pin.asc" "$K/b/ci.asc" "$H1"
    write_map site site
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 0
    refute grep -q "nothing proves" <<< "$output"
    "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" check-rpm "$TMP/hist/$H1" "$TMP/hist/$H2"
}

@test "sign-history refuses a file that is not the bytes the map names" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    write_map site site
    printf 'x' >> "$TMP/hist/$H1"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "does not match the SHA-256"
}

@test "sign-history refuses an .rpm that the map does not list" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    write_map site site
    mkdir -p "$TMP/hist/v3"
    cp "$TMP/hist/$H1" "$TMP/hist/v3/other-1.0.0-1.noarch.rpm"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "not in $TMP/map"
}

@test "sign-history refuses a missing file and a symbolic link" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    write_map site site
    mv "$TMP/hist/$H1" "$TMP/moved.rpm"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "is missing"
    ln -s "$TMP/moved.rpm" "$TMP/hist/$H1"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "is missing, or is not a regular file"
}

@test "sign-history ignores map lines that are not .rpm files" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    write_map site site
    printf 'v1\t%s\tdeb/pool/h/hello_1.0.0_all.deb\tsite\n' "$(printf x | sha256sum | cut -d' ' -f1)" >> "$TMP/map"
    cp "$TMP/map" "$TMP/map.before"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 0
    cmp "$TMP/map" "$TMP/map.before"
}

@test "sign-history refuses a malformed map" {
    hist
    sign_as "$K/a/pin.asc" "$K/a/ci.asc" "$H1" "$H2"
    good="$(sha "$TMP/hist/$H1")"
    for line in \
        "v1	abc	$H1	site" \
        "v1	$good	../$H1	site" \
        "v1	$good	/$H1	site" \
        "v1	$good	$H1	mirror" \
        "v1	$good	$H1" \
        "	$good	$H1	site"; do
        printf '%s\n' "$line" > "$TMP/map"
        history_run "$K/a/pin.asc" "$K/a/ci.asc"
        assert_status 1
        assert_output_contains "history map"
    done
    printf 'v1\t%s\t%s\tsite\nv1\t%s\t%s\tsite\n' "$good" "$H1" "$good" "$H1" > "$TMP/map"
    history_run "$K/a/pin.asc" "$K/a/ci.asc"
    assert_status 1
    assert_output_contains "listed twice"
}

@test "sign-history without pin and key changes nothing" {
    mkdir -p "$TMP/hist/v1"
    printf 'not signed\n' > "$TMP/hist/v1/x-1.0.0-1.noarch.rpm"
    printf 'v1\t%s\tv1/x-1.0.0-1.noarch.rpm\tsite\n' "$(sha "$TMP/hist/v1/x-1.0.0-1.noarch.rpm")" > "$TMP/map"
    cp "$TMP/map" "$TMP/map.before"
    gnupg_home
    run "$LIB/linux-signing.sh" --pin "$TMP/absent.asc" sign-history --map "$TMP/map" "$TMP/hist"
    assert_status 0
    [ "$(output_value signed)" = false ]
    assert_output_contains "unsigned"
    cmp "$TMP/map" "$TMP/map.before"
}

@test "sign-history fails closed like import, and changes nothing" {
    mkdir -p "$TMP/hist/v1"
    printf 'x\n' > "$TMP/hist/v1/x-1.0.0-1.noarch.rpm"
    printf 'v1\t%s\tv1/x-1.0.0-1.noarch.rpm\tsite\n' "$(sha "$TMP/hist/v1/x-1.0.0-1.noarch.rpm")" > "$TMP/map"
    cp "$TMP/map" "$TMP/map.before"
    history_run "$K/a/pin.asc" "$K/b/ci.asc"
    assert_status 1
    assert_output_contains "but public-key"
    cmp "$TMP/map" "$TMP/map.before"
    rm -rf "$GNUPGHOME"
    gnupg_home
    unset REPO_SIGNING_KEY
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map" "$TMP/hist"
    assert_status 1
    assert_output_contains "signing-key is empty"
}

@test "sign-history usage errors" {
    mkdir -p "$TMP/hist"
    : > "$TMP/map"
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history "$TMP/hist"
    assert_status 1
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map"
    assert_status 1
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map" "$TMP/hist" "$TMP/hist"
    assert_status 1
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map" --frob x "$TMP/hist"
    assert_status 1
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map" --resign-unproven yes "$TMP/hist"
    assert_status 1
    assert_output_contains "must be 'true' or 'false'"
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/nope" "$TMP/hist"
    assert_status 1
    run "$LIB/linux-signing.sh" --pin "$K/a/pin.asc" sign-history --map "$TMP/map" "$TMP/nope"
    assert_status 1
}

# The read-only container has no writable home and no GNUPGHOME (check-rpm, check-site): the helpers
# that only read the pin must not need either. HOME under a regular file can't be created, even by root.
@test "the pin helpers work with no GNUPGHOME and a home that can't be created" {
    need gpg gpgv
    : > "$TMP/notdir"
    run env -u GNUPGHOME HOME="$TMP/notdir/home" sh -c ". '$LIB/common.sh'; . '$LIB/signing.sh'
        pin_fpr '$K/a/pin.asc'; pin_subkeys '$K/a/pin.asc'
        pin_rpm_key '$K/a/pin.asc' '$TMP/key.asc'
        gpg_verify '$K/a/pin.asc' '$K/valid.asc' '$K/data.txt'"
    assert_status 0
    assert_output_contains "$(cat "$K/a/fpr")"
    assert_output_contains "$(cat "$K/a/sub")"
    [ -s "$TMP/key.asc" ]
    [ ! -e "$TMP/notdir/home" ]
}

# shellcheck shell=sh
# OpenPGP signing for packages and repositories, held to a committed public key (the pin).
# Source it after common.sh. Ported from SkeLLLa/cainary's packaging/ci/linux-signing.sh; the CLI
# is lib/linux-signing.sh, and docs/signing.md explains the key model.
#
# The pin is an armored public certificate: one primary key (kept offline by the maintainer), its
# subkeys and their revocations. CI gets one secret signing subkey of it. Signing fails closed:
# once a pin exists, every run must be signed by a subkey it lists.
#
# All gpg calls use GNUPGHOME, which the caller points at a fresh, private directory that is
# removed after the step (lib/run.sh does that).

# pin_fpr PIN: print the primary key fingerprint of PIN. Fails unless PIN holds exactly one public
# key and no secret key material.
pin_fpr() {
    [ -f "$1" ] || die "public-key $1 does not exist"
    _colons="$(gpg --batch --with-colons --show-keys "$1" 2> /dev/null)" ||
        die "public-key $1 is not an OpenPGP certificate"
    if printf '%s\n' "$_colons" | grep -q '^sec:'; then
        die "public-key $1 holds secret key material; commit only the public key"
    fi
    _n="$(printf '%s\n' "$_colons" | grep -c '^pub:' || true)"
    [ "$_n" -eq 1 ] || die "public-key $1 must hold exactly one key, not $_n"
    printf '%s\n' "$_colons" | awk -F: '$1 == "fpr" { print $10; exit }'
}

# pin_subkeys PIN: print the fingerprints of every subkey PIN lists, one per line.
pin_subkeys() {
    gpg --batch --with-colons --show-keys "$1" |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; s = 0 }'
}

# secret_fpr: print the primary fingerprint of the only secret key in GNUPGHOME, or nothing when
# there is none. Fails when there is more than one.
secret_fpr() {
    _colons="$(gpg --batch --with-colons --list-secret-keys 2> /dev/null || true)"
    _n="$(printf '%s\n' "$_colons" | grep -c '^sec:' || true)"
    case "$_n" in
        0) return 0 ;;
        1) ;;
        *) die "gpg holds $_n secret keys; the signing key must be the only one" ;;
    esac
    printf '%s\n' "$_colons" | awk -F: '$1 == "fpr" { print $10; exit }'
}

# secret_subkeys: print the fingerprints of the secret subkeys in GNUPGHOME, one per line.
secret_subkeys() {
    gpg --batch --with-colons --with-subkey-fingerprints --list-secret-keys |
        awk -F: '$1 == "ssb" { s = 1; next } $1 == "fpr" && s { print $10; s = 0 }'
}

# signing_import PIN: import the secret subkey from REPO_SIGNING_KEY into GNUPGHOME, which must be
# an existing, empty directory, after checking it against PIN. Then import PIN itself, so a
# subkey that PIN revokes can't sign. Prints the primary fingerprint when signed, nothing when
# unsigned. The fail-closed matrix (docs/signing.md):
#
#   no PIN, no key        unsigned, with a notice
#   no PIN, key           error: commit the public key first
#   PIN, no key           error: the secret is not set, or not passed to the action
#   PIN, key              signed, if the key is a subkey PIN lists, without the primary's
#                         secret, without a passphrase, not expired and not revoked
signing_import() {
    _pin="$1"
    [ -n "${GNUPGHOME:-}" ] && [ -d "$GNUPGHOME" ] || die "GNUPGHOME must name an existing directory"
    [ -z "$(ls -A "$GNUPGHOME")" ] || die "GNUPGHOME $GNUPGHOME is not empty"
    if [ ! -f "$_pin" ]; then
        [ -z "${REPO_SIGNING_KEY:-}" ] ||
            die "signing-key is set but public-key $_pin does not exist; commit the public key first"
        notice "public-key $_pin is not committed: the packages and repositories are unsigned"
        return 0
    fi
    [ -n "${REPO_SIGNING_KEY:-}" ] ||
        die "public-key $_pin is committed but signing-key is empty; set the secret in the signing environment and pass it to the action"
    _pinned="$(pin_fpr "$_pin")"

    printf '%s\n' "$REPO_SIGNING_KEY" | gpg --batch --quiet --import 2> /dev/null ||
        die "signing-key is not an armored OpenPGP secret key"
    _fpr="$(secret_fpr)"
    [ -n "$_fpr" ] || die "signing-key holds no secret key"
    [ "$_fpr" = "$_pinned" ] || die "signing-key belongs to key $_fpr, but public-key $_pin pins $_pinned"
    # A primary whose secret is present shows as sec with no '#' (stub) or '>' (card) in field 15.
    if gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" && $15 !~ /^[#>]/ { found = 1 } END { exit !found }'; then
        die "signing-key holds the primary key's secret; give CI only a signing subkey (tools/ci-key)"
    fi
    _subs="$(secret_subkeys)"
    [ -n "$_subs" ] || die "signing-key holds no secret subkey"
    _listed="$(pin_subkeys "$_pin")"
    for _sub in $_subs; do
        printf '%s\n' "$_listed" | grep -qxF "$_sub" ||
            die "signing subkey $_sub is not in public-key $_pin; commit the exported public key first"
    done

    # The committed certificate carries every subkey and revocation; it is what gets published.
    gpg --batch --quiet --import "$_pin" 2> /dev/null || die "importing public-key $_pin failed"
    # A probe signature with each subkey ('!' forces exactly that one): fails on a passphrase, an
    # expired or a revoked subkey, before anything is signed with it.
    for _sub in $_subs; do
        echo probe | gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
            --local-user "$_sub!" --sign > /dev/null 2>&1 ||
            die "signing subkey $_sub can't sign: passphrase-protected, expired, revoked or not a signing key"
    done
    log "imported signing subkey $(printf '%s' "$_subs" | tr '\n' ' ') of $_fpr"
    printf '%s\n' "$_fpr"
}

# rpm_verifies PIN FILE DB: true when FILE carries a valid signature by PIN. DB is an rpm database
# directory that already holds PIN (rpm_db_with_pin). The signature level makes an unsigned
# package fail instead of passing on its digests alone.
rpm_verifies() {
    rpmkeys --dbpath "$3" --define '_pkgverify_level signature' --checksig "$2" > /dev/null 2>&1
}

# rpm_db_with_pin PIN VAR: create a temporary rpm database holding only PIN, path in VAR.
rpm_db_with_pin() {
    make_tmpdir "$2"
    _rdb=''
    eval "_rdb=\$$2"
    rpmkeys --dbpath "$_rdb" --import "$1" || die "rpmkeys could not import public-key $1"
}

# check_rpm PIN FILE...: fail unless every FILE has a valid signature by PIN, as dnf checks with
# gpgcheck=1. Needs only rpmkeys, no secret.
check_rpm() {
    _pin="$1"
    shift
    require_tools rpmkeys
    [ -f "$_pin" ] || die "public-key $_pin does not exist"
    _db=''
    rpm_db_with_pin "$_pin" _db
    for _f in "$@"; do
        rpm_verifies "$_pin" "$_f" "$_db" || die "$_f is not signed by public-key $_pin"
    done
    log "checked $# .rpm signature(s) against $_pin"
}

# sign_rpm PIN FILE...: sign each FILE in place with the key in GNUPGHOME (signing_import first),
# then check_rpm them. A file that already verifies against PIN is left byte-identical; any other
# signature (an older or a foreign key) is replaced.
sign_rpm() {
    _pin="$1"
    shift
    require_tools rpmsign rpmkeys gpg
    _fpr="$(secret_fpr)"
    [ -n "$_fpr" ] || die "no signing key is imported"
    _sdb=''
    rpm_db_with_pin "$_pin" _sdb
    _gpg="$(command -v gpg)"
    for _f in "$@"; do
        if rpm_verifies "$_pin" "$_f" "$_sdb"; then
            log "$_f is already signed"
            continue
        fi
        # rpm 6 refuses to add a second signature by another key ("already contains a legacy
        # signature"), so drop whatever is there first; harmless on an unsigned file.
        rpmsign --delsign "$_f" > /dev/null 2>&1 || true
        # __gpg: Debian's rpm looks for gpg2, which trixie doesn't ship.
        rpmsign --define "__gpg $_gpg" --define "_gpg_name $_fpr" \
            --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback" \
            --addsign "$_f" > /dev/null || die "rpmsign failed on $_f"
        log "signed $_f"
    done
    check_rpm "$_pin" "$@"
}

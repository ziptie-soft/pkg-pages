#!/bin/sh
# Sign and check .rpm files against a committed public key (the pin). The functions live in
# signing.sh; this is their command line, used by the sign-rpm and check-rpm actions and handy
# on a developer's machine.
#
# Usage:
#   linux-signing.sh [--pin FILE] import
#       Import REPO_SIGNING_KEY (an armored secret subkey without a passphrase) into GNUPGHOME,
#       an existing empty directory, after checking it against the pin. Fails closed; see the
#       matrix in signing.sh and docs/signing.md. Prints nothing on stdout.
#   linux-signing.sh [--pin FILE] sign-rpm FILE...
#       Import as above, then sign each .rpm in place and check it. With no pin and no key, the
#       files are left unsigned (a notice, not an error).
#   linux-signing.sh [--pin FILE] check-rpm [--allow-unsigned] FILE...
#       Fail unless each .rpm is signed by the pin. With --allow-unsigned, a missing pin passes
#       with a notice. Needs no secret.
#
# The pin defaults to $PKG_PAGES_PIN, then packaging/signing/repo.asc.
#
# Outputs, when run in GitHub Actions (GITHUB_OUTPUT and GITHUB_ENV are set):
#   import, sign-rpm   signed=true|false, fingerprint=<primary fpr>; and in GITHUB_ENV
#                      PKG_PAGES_SIGNED and PKG_PAGES_FINGERPRINT
#   check-rpm          checked=true|false
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

usage() {
    die "usage: $0 [--pin FILE] import | sign-rpm FILE... | check-rpm [--allow-unsigned] FILE..."
}

pin="${PKG_PAGES_PIN:-packaging/signing/repo.asc}"
if [ "${1:-}" = --pin ]; then
    [ "$#" -ge 2 ] || usage
    pin="$2"
    shift 2
fi
[ "$#" -ge 1 ] || usage
cmd="$1"
shift

# Outputs of an import: signed and fingerprint, as step outputs and in GITHUB_ENV.
report_import() {
    if [ -n "$1" ]; then
        set_output signed true
        set_output fingerprint "$1"
        set_env PKG_PAGES_SIGNED true
        set_env PKG_PAGES_FINGERPRINT "$1"
    else
        set_output signed false
        set_output fingerprint ''
        set_env PKG_PAGES_SIGNED false
    fi
}

need_files() {
    [ "$#" -ge 1 ] || die "$cmd needs at least one .rpm file"
    for f in "$@"; do
        [ -f "$f" ] || die "$f is not a file"
        case "$f" in *.rpm) ;; *) die "$f is not an .rpm file" ;; esac
    done
}

case "$cmd" in
    import)
        [ "$#" -eq 0 ] || usage
        require_tools gpg
        fpr="$(signing_import "$pin")"
        report_import "$fpr"
        ;;
    sign-rpm)
        need_files "$@"
        require_tools gpg
        fpr="$(signing_import "$pin")"
        report_import "$fpr"
        if [ -n "$fpr" ]; then
            sign_rpm "$pin" "$@"
        fi
        ;;
    check-rpm)
        allow_unsigned=false
        if [ "${1:-}" = --allow-unsigned ]; then
            allow_unsigned=true
            shift
        fi
        need_files "$@"
        if [ ! -f "$pin" ]; then
            [ "$allow_unsigned" = true ] || die "public-key $pin does not exist, and unsigned packages are not allowed"
            notice "public-key $pin is not committed: the signatures of $# .rpm file(s) were not checked"
            set_output checked false
            exit 0
        fi
        check_rpm "$pin" "$@"
        set_output checked true
        ;;
    *) usage ;;
esac

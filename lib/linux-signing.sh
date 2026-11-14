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
#   linux-signing.sh [--pin FILE] sign-history --map MAP [--resign-unproven true|false] DIR
#       Import as above, then make the earlier releases' .rpm files in DIR follow the current
#       subkey (docs/signing.md, "Rotation"). MAP lists them, one line per file, tab-separated:
#       <tag> <sha256> <path relative to DIR> <site|release>. Every .rpm that a held subkey did
#       not sign is signed again in place when its bytes are proven: "site" files were checked
#       against the live site's signed manifest, and "release" files must verify against the
#       pin. A "release" file that doesn't is unproven: an error, or with --resign-unproven true
#       (the default is false) signed again with a warning. Files a held subkey signed stay
#       byte-identical. MAP is rewritten with the new SHA-256 values. Every .rpm under DIR must
#       be in MAP, and every file must match its SHA-256 in MAP. With no pin and no key, nothing
#       is changed (a notice, not an error).
#   linux-signing.sh [--pin FILE] check-rpm [--allow-unsigned] FILE...
#       Fail unless each .rpm is signed by the pin. With --allow-unsigned, a missing pin passes
#       with a notice. Needs no secret.
#
# The pin defaults to $PKG_PAGES_PIN, then packaging/signing/repo.asc.
#
# Outputs, when run in GitHub Actions (GITHUB_OUTPUT and GITHUB_ENV are set):
#   import, sign-rpm,
#   sign-history       signed=true|false, fingerprint=<primary fpr>; and in GITHUB_ENV
#                      PKG_PAGES_SIGNED and PKG_PAGES_FINGERPRINT
#   check-rpm          checked=true|false
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"
# The key is for signing_import alone, which reads the shell variable: no tool this script runs,
# the package readers included, gets it in its environment.
signing_key="${REPO_SIGNING_KEY-}"
unset REPO_SIGNING_KEY

usage() {
    die "usage: $0 [--pin FILE] import | sign-rpm FILE... | sign-history --map MAP [--resign-unproven true|false] DIR | check-rpm [--allow-unsigned] FILE..."
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

# held_subkey_pin VAR: store in VAR the path of a minimal public key: the primary and the subkeys
# whose secret GNUPGHOME holds, and nothing else. A signature verifies against it only when a held
# subkey made it. Call it after signing_import, directly (not in $(...)): make_tmpdir has to run
# in this shell for the file to be removed at exit.
held_subkey_pin() {
    _held_var="$1"
    _held_dir=''
    make_tmpdir _held_dir
    # ssb records whose secret is there. Not secret_subkeys: once the pin is imported, gpg also lists
    # each of its other subkeys here, as stubs with '#' in field 15.
    _held_subs="$(gpg --batch --with-colons --with-subkey-fingerprints --list-secret-keys |
        awk -F: '$1 == "ssb" { s = ($15 != "#"); next } $1 == "fpr" && s { print $10; s = 0 } $1 == "fpr" { s = 0 }')"
    [ -n "$_held_subs" ] || die "no signing subkey is imported"
    # Drop every subkey but the held ones. A "<subkey>!" key spec doesn't do it: gpg still exports
    # every subkey of the key in some homes.
    _held_expr=''
    for _held_s in $_held_subs; do
        _held_expr="${_held_expr:+$_held_expr && }fpr <> $_held_s"
    done
    gpg --batch --armor --export-options export-minimal --export-filter "drop-subkey=$_held_expr" \
        --export "$(secret_fpr)" > "$_held_dir/held.asc" ||
        die "exporting the signing subkey's public key failed"
    [ -s "$_held_dir/held.asc" ] || die "exporting the signing subkey's public key gave nothing"
    eval "$_held_var=\$_held_dir/held.asc"
}

# check_map_line TAG SUM PATH SOURCE: one line of the history map, strictly.
check_map_line() {
    [ -n "$1" ] || die "history map: a line has no tag"
    case "$2" in
        *[!0-9a-f]*) die "history map: '$2' is not a SHA-256 (line for $3)" ;;
    esac
    [ "${#2}" -eq 64 ] || die "history map: '$2' is not a SHA-256 (line for $3)"
    check_relpath "history map path" "$3"
    case "$3" in
        *"	"*) die "history map: path '$3' holds a tab" ;;
    esac
    case "$4" in
        site | release) ;;
        *) die "history map: the source of $3 must be 'site' or 'release', not '$4'" ;;
    esac
}

# sign_history PIN MAP DIR RESIGN_UNPROVEN: the sign-history command (the header explains it).
# The key is imported already.
sign_history() {
    sh_pin="$1" sh_map="$2" sh_dir="${3%/}" sh_unproven="$4"
    tab="$(printf '\t')"
    require_tools rpmsign rpmkeys gpg sha256sum find
    sh_work=''
    make_tmpdir sh_work
    sh_held=''
    held_subkey_pin sh_held
    sh_db_held='' sh_db_pin=''
    rpm_db_with_pin "$sh_held" sh_db_held
    rpm_db_with_pin "$sh_pin" sh_db_pin
    : > "$sh_work/mapped"
    : > "$sh_work/resign"
    sh_current=0
    while IFS="$tab" read -r sh_tag sh_sum sh_path sh_source || [ -n "$sh_tag" ]; do
        check_map_line "$sh_tag" "$sh_sum" "$sh_path" "$sh_source"
        case "$sh_path" in *.rpm) ;; *) continue ;; esac
        grep -qxF -- "$sh_path" "$sh_work/mapped" && die "history map: $sh_path is listed twice"
        printf '%s\n' "$sh_path" >> "$sh_work/mapped"
        sh_file="$sh_dir/$sh_path"
        if [ -L "$sh_file" ] || [ ! -f "$sh_file" ]; then
            die "history file $sh_path ($sh_tag) is missing, or is not a regular file"
        fi
        # The map vouches for the bytes only while they are the bytes it names.
        [ "$(sha256sum < "$sh_file" | cut -d' ' -f1)" = "$sh_sum" ] ||
            die "history file $sh_path ($sh_tag) does not match the SHA-256 in $sh_map"
        if rpm_verifies "$sh_held" "$sh_file" "$sh_db_held"; then
            sh_current=$((sh_current + 1))
            continue
        fi
        if [ "$sh_source" = site ]; then
            log "$sh_path ($sh_tag): listed in the live site's signed manifest, signing it again with the current subkey"
        elif rpm_verifies "$sh_pin" "$sh_file" "$sh_db_pin"; then
            log "$sh_path ($sh_tag): signed by a subkey of $sh_pin, signing it again with the current subkey"
        elif [ "$sh_unproven" = true ]; then
            warning "$sh_path ($sh_tag) is not signed by $sh_pin, so nothing proves its bytes: signing it anyway (resign-history)"
        else
            die "$sh_path ($sh_tag) is not signed by $sh_pin, so nothing proves its bytes. Check where it came from, then run once with resign-history: true (docs/upgrading.md)"
        fi
        printf '%s\n' "$sh_path" >> "$sh_work/resign"
    done < "$sh_map"

    find "$sh_dir" \( -type f -o -type l \) -name '*.rpm' > "$sh_work/found"
    sed "s|^|$sh_dir/|" "$sh_work/mapped" > "$sh_work/mapped-full"
    sh_extra="$(grep -vxFf "$sh_work/mapped-full" "$sh_work/found" || true)"
    [ -z "$sh_extra" ] || die "history files that are not in $sh_map: $(printf '%s' "$sh_extra" | tr '\n' ' ')"

    if [ ! -s "$sh_work/resign" ]; then
        log "all $sh_current history .rpm file(s) are signed by the current subkey"
        return 0
    fi
    set --
    while IFS= read -r sh_path; do
        set -- "$@" "$sh_dir/$sh_path"
    done < "$sh_work/resign"
    # Against the held subkeys alone, so a file that another listed subkey signed is signed again.
    sign_rpm "$sh_held" "$@"

    : > "$sh_work/map"
    while IFS="$tab" read -r sh_tag sh_sum sh_path sh_source || [ -n "$sh_tag" ]; do
        if grep -qxF -- "$sh_path" "$sh_work/resign"; then
            sh_sum="$(sha256sum < "$sh_dir/$sh_path" | cut -d' ' -f1)"
        fi
        printf '%s\t%s\t%s\t%s\n' "$sh_tag" "$sh_sum" "$sh_path" "$sh_source" >> "$sh_work/map"
    done < "$sh_map"
    cat "$sh_work/map" > "$sh_map"
    log "signed $# history .rpm file(s) again with the current subkey; $sh_current already were"
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
        fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
        report_import "$fpr"
        ;;
    sign-rpm)
        need_files "$@"
        require_tools gpg
        fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
        report_import "$fpr"
        if [ -n "$fpr" ]; then
            sign_rpm "$pin" "$@"
        fi
        ;;
    sign-history)
        sh_mapfile='' sh_resign=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --map)
                    [ "$#" -ge 2 ] || usage
                    sh_mapfile="$2"
                    shift 2
                    ;;
                --resign-unproven)
                    [ "$#" -ge 2 ] || usage
                    sh_resign="$2"
                    shift 2
                    ;;
                -*) usage ;;
                *) break ;;
            esac
        done
        [ -n "$sh_mapfile" ] && [ "$#" -eq 1 ] || usage
        check_bool --resign-unproven "$sh_resign"
        [ -f "$sh_mapfile" ] || die "history map $sh_mapfile is not a file"
        [ -d "$1" ] || die "$1 is not a directory"
        require_tools gpg
        fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
        report_import "$fpr"
        if [ -n "$fpr" ]; then
            sign_history "$pin" "$sh_mapfile" "$1" "$sh_resign"
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

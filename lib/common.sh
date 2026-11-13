# shellcheck shell=sh
# Helpers shared by the scripts in lib/. Source it, don't run it:
#
#   . "$(dirname "$0")/common.sh"
#
# Everything here is POSIX sh, so it works in dash (Debian, Ubuntu) and bash (Fedora, runners).
# Function names are prefixed with nothing and kept few; the scripts that source this file must
# not define functions with the same names.

# die MESSAGE...: print a GitHub error annotation (plain text outside Actions) and exit 1.
die() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error::%s\n' "$*" >&2
    else
        printf 'error: %s\n' "$*" >&2
    fi
    exit 1
}

# notice MESSAGE...: an annotation for a deliberate, non-failing outcome (an unsigned run).
notice() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::notice::%s\n' "$*" >&2
    else
        printf 'notice: %s\n' "$*" >&2
    fi
}

# warning MESSAGE...: an annotation for something that works but needs the caller's attention.
warning() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::warning::%s\n' "$*" >&2
    else
        printf 'warning: %s\n' "$*" >&2
    fi
}

# log MESSAGE...: progress, on stderr so that stdout stays usable for data.
log() {
    printf '%s\n' "$*" >&2
}

# set_output NAME VALUE: a step output, when GITHUB_OUTPUT is set. VALUE is one line.
set_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

# set_env NAME VALUE: an environment variable for the later steps of the job (GITHUB_ENV).
set_env() {
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
    fi
}

# require_tools TOOL...: fail naming every tool that is not on PATH.
require_tools() {
    missing=
    for tool in "$@"; do
        command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] || die "missing tools:$missing"
}

# check_bool LABEL VALUE: VALUE must be the string true or false.
check_bool() {
    case "$2" in
        true | false) ;;
        *) die "$1 must be 'true' or 'false', not '$2'" ;;
    esac
}

# check_name LABEL VALUE: a Debian-style name, safe in file names, URLs and HTML.
check_name() {
    case "$2" in
        '' | [!a-z0-9]* | *[!a-z0-9.+-]*) die "$1 must match [a-z0-9][a-z0-9.+-]*, not '$2'" ;;
    esac
}

# check_url LABEL VALUE: https:// or file:/// only, on one line, and only URL characters: no
# quotes, spaces, <>, backslashes, or $ (which dnf would expand). Callers HTML-escape it; a URL
# that shell commands contain must also pass check_base_url.
check_url() {
    case "$2" in
        https://?* | file:///*) ;;
        *) die "$1 must start with https:// or file:///, not '$2'" ;;
    esac
    case "$2" in
        *"
"*) die "$1 must be a single line" ;;
    esac
    printf '%s\n' "$2" | grep -Eq '^[A-Za-z0-9._~:/?#@!&()*+,;=%-]+$' ||
        die "$1 contains characters that are not allowed in a URL: '$2'"
}

# check_base_url LABEL VALUE: check_url, and only characters that need no quoting in a POSIX
# or fish command line, a .list or a .repo file: letters, digits and . _ ~ : / % + @ = , -
check_base_url() {
    check_url "$1" "$2"
    printf '%s\n' "$2" | LC_ALL=C grep -Eq '^[A-Za-z0-9._~:/%+@=,-]+$' ||
        die "$1 may only hold letters, digits and . _ ~ : / % + @ = , - (the install commands use it unquoted), not '$2'"
}

# check_relpath LABEL VALUE: a path relative to the working directory, without .. segments.
# Callers' inputs are paths inside their checkout; nothing may escape it.
check_relpath() {
    case "$2" in
        '') die "$1 is empty" ;;
        /*) die "$1 must be a relative path, not '$2'" ;;
        .. | ../* | */.. | */../*) die "$1 must not contain '..': '$2'" ;;
    esac
    case "$2" in
        *"
"*) die "$1 must be a single line" ;;
    esac
}

# check_word LABEL VALUE: an APT suite, component or architecture token.
check_word() {
    case "$2" in
        '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) die "$1 must match [A-Za-z0-9][A-Za-z0-9._-]*, not '$2'" ;;
    esac
}

# html_escape: stdin to stdout, with & < > " ' escaped for HTML text and attribute values.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# make_tmpdir VAR: create a private temporary directory, store its path in VAR, and remove it when
# the script exits (on success, on die and on a signal). Use this rather than a trap of your own:
# a second `trap ... EXIT` would replace the first.
_cleanup_paths=
make_tmpdir() {
    _dir="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages.XXXXXX")" || die "mktemp failed"
    _cleanup_paths="$_cleanup_paths
$_dir"
    eval "$1=\$_dir"
}
_cleanup() {
    printf '%s\n' "$_cleanup_paths" | while IFS= read -r p; do
        [ -z "$p" ] || rm -rf "$p"
    done
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Shared setup for the bats tests: `load helpers` at the top of each file.
#
# Tests that need a tool the machine lacks skip themselves (`need TOOL...`), so `mise run test`
# passes on any machine and runs what it can; `tests/container.sh debian|fedora|ubuntu` runs the
# rest in the images.env containers. Tests that change the system (apt/dnf installs) also need
# PKG_PAGES_TEST_SYSTEM=1 and root (`need_system`), which only the containers set.

# shellcheck disable=SC2034,SC2154 # used by the .bats files; output and status come from bats `run`
ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LIB="$ROOT/lib"
FIXTURES="$ROOT/tests/fixtures.sh"

setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    # Fresh, empty files for the step outputs, like a runner provides.
    export GITHUB_OUTPUT="$TMP/github_output" GITHUB_ENV="$TMP/github_env"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_ENV"
    unset GITHUB_ACTIONS REPO_SIGNING_KEY GNUPGHOME PKG_PAGES_PIN
}

teardown() {
    kill_agents "$TMP"
    rm -rf "$TMP"
}

# kill_agents DIR: stop the gpg-agents of every GnuPG home under DIR, so none outlives the test.
kill_agents() {
    [ -d "$1" ] || return 0
    find "$1" -name 'pubring.kbx' 2> /dev/null | while IFS= read -r f; do
        gpgconf --homedir "$(dirname "$f")" --kill all > /dev/null 2>&1 || true
    done
}

# need TOOL...: skip the test unless every TOOL is on PATH.
need() {
    for t in "$@"; do
        command -v "$t" > /dev/null 2>&1 || skip "$t is not installed (tests/container.sh runs this)"
    done
}

# need_system: skip unless the test may install packages (root, in a throwaway container).
need_system() {
    [ "${PKG_PAGES_TEST_SYSTEM:-}" = 1 ] && [ "$(id -u)" -eq 0 ] ||
        skip "changes the system; runs in tests/container.sh"
}

# keys: generate the throwaway keys once per test file, into $BATS_FILE_TMPDIR/keys:
#   a/  the project's key (pin.asc, ci.asc, home/, fpr, sub)
#   b/  another project's key
# Call from setup_file. Each test copies what it needs; nobody changes these.
keys() {
    need gpg
    K="$BATS_FILE_TMPDIR/keys"
    if [ ! -d "$K/a" ]; then
        "$FIXTURES" key "$K/a" "project a"
        "$FIXTURES" key "$K/b" "project b"
    fi
    export K
}

# gnupg_home: a fresh, empty GNUPGHOME for the test, as run.sh --gnupg provides.
gnupg_home() {
    export GNUPGHOME="$TMP/gnupg"
    mkdir -m 700 "$GNUPGHOME"
}

# sha FILE: the SHA-256 of FILE.
sha() {
    sha256sum "$1" | cut -d' ' -f1
}

# output_value NAME: the last value written for NAME to GITHUB_OUTPUT.
output_value() {
    sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1
}

# assert_output_contains TEXT: $output (from `run`) contains TEXT.
assert_output_contains() {
    case "$output" in
        *"$1"*) ;;
        *)
            printf 'expected output to contain: %s\nactual output:\n%s\n' "$1" "$output" >&2
            return 1
            ;;
    esac
}

# refute CMD...: fail when CMD succeeds. Use it instead of `! CMD`: bats (set -e) never fails a
# test on a negated command, so `! grep -q x file` would pass whatever the file holds.
refute() {
    if "$@"; then
        printf 'expected this to fail: %s\n' "$*" >&2
        return 1
    fi
}

# assert_status N: $status (from `run`) is N, printing the output when it isn't.
assert_status() {
    if [ "$status" -ne "$1" ]; then
        printf 'expected status %s, got %s; output:\n%s\n' "$1" "$status" "$output" >&2
        return 1
    fi
}

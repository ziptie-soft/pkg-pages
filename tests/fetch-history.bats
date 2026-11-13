#!/usr/bin/env bats
# lib/fetch-history.sh against a fake `gh` that serves releases from files, so no network or
# token is needed. Runs anywhere.

load helpers

# The fake gh reads $FAKE_GH/releases ("TAG PRERELEASE" lines, newest first) and
# $FAKE_GH/assets/TAG (asset names), logs every call to $FAKE_GH/calls, and fails a download
# when $FAKE_GH/fail-download exists.
setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    export GITHUB_OUTPUT="$TMP/github_output"
    : > "$GITHUB_OUTPUT"
    export FAKE_GH="$TMP/gh" GITHUB_REPOSITORY=owner/repo
    mkdir -p "$FAKE_GH/assets" "$TMP/bin"
    cat > "$TMP/bin/gh" << 'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_GH/calls"
[ "$1" = release ] || exit 2
cmd="$2"; shift 2
case "$cmd" in
    list)
        limit=30 pre=yes
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --limit) limit="$2"; shift ;;
                --exclude-pre-releases) pre=no ;;
            esac
            shift
        done
        while read -r tag p; do
            [ "$pre" = yes ] || [ "$p" = 0 ] || continue
            echo "$tag"
        done < "$FAKE_GH/releases" | head -n "$limit"
        ;;
    view)
        [ -f "$FAKE_GH/assets/$1" ] || { echo "release not found" >&2; exit 1; }
        cat "$FAKE_GH/assets/$1"
        ;;
    download)
        tag="$1"; shift
        [ ! -e "$FAKE_GH/fail-download" ] || exit 1
        dir=. pats=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --dir) dir="$2"; shift ;;
                --pattern) pats="$pats $2"; shift ;;
            esac
            shift
        done
        set -f
        while read -r a; do
            for p in $pats; do
                case "$a" in $p) echo "$tag" > "$dir/$a"; break ;; esac
            done
        done < "$FAKE_GH/assets/$tag"
        ;;
esac
EOF
    chmod +x "$TMP/bin/gh"
    export PATH="$TMP/bin:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

release() { # release TAG PRERELEASE ASSET...
    tag="$1" pre="$2"
    shift 2
    echo "$tag $pre" >> "$FAKE_GH/releases"
    mkdir -p "$(dirname "$FAKE_GH/assets/$tag")"
    : > "$FAKE_GH/assets/$tag"
    for a in "$@"; do echo "$a" >> "$FAKE_GH/assets/$tag"; done
}

fetch() {
    run "$LIB/fetch-history.sh" --dir "$TMP/assets" "$@"
}

@test "fetches the newest releases, skipping the current tag" {
    release v1.3.0 0 hello_1.3.0_amd64.deb hello-1.3.0-1.x86_64.rpm
    release v1.2.0 0 hello_1.2.0_amd64.deb hello-1.2.0-1.x86_64.rpm SHA256SUMS
    release v1.1.0 0 hello_1.1.0_amd64.deb
    release v1.0.0 0 hello_1.0.0_amd64.deb
    fetch --keep 2 --exclude-tag v1.3.0
    assert_status 0
    [ "$(output_value tags)" = "v1.2.0 v1.1.0" ]
    [ -f "$TMP/assets/hello_1.2.0_amd64.deb" ]
    [ -f "$TMP/assets/hello-1.2.0-1.x86_64.rpm" ]
    [ -f "$TMP/assets/hello_1.1.0_amd64.deb" ]
    [ ! -e "$TMP/assets/SHA256SUMS" ]
    [ ! -e "$TMP/assets/hello_1.3.0_amd64.deb" ]
    [ ! -e "$TMP/assets/hello_1.0.0_amd64.deb" ]
}

@test "skips pre-releases unless asked, and never lists drafts" {
    release v2.0.0-rc.1 1 hello_2.0.0~rc.1_amd64.deb
    release v1.0.0 0 hello_1.0.0_amd64.deb
    fetch
    assert_status 0
    [ "$(output_value tags)" = v1.0.0 ]
    grep -q -- '--exclude-drafts' "$FAKE_GH/calls"
    grep -q -- '--exclude-pre-releases' "$FAKE_GH/calls"
    rm -rf "$TMP/assets"
    : > "$GITHUB_OUTPUT"
    fetch --include-prereleases true
    assert_status 0
    [ "$(output_value tags)" = "v2.0.0-rc.1 v1.0.0" ]
}

@test "a release without matching assets is skipped with a notice" {
    release v1.1.0 0 source.tar.gz
    release v1.0.0 0 hello_1.0.0_amd64.deb
    fetch
    assert_status 0
    assert_output_contains "v1.1.0 has no assets matching"
    [ "$(output_value tags)" = v1.0.0 ]
}

@test "only the patterns that match are passed to gh release download" {
    release v1.0.0 0 hello_1.0.0_amd64.deb
    fetch
    assert_status 0
    grep -q 'release download v1.0.0 .* --pattern \*.deb$' "$FAKE_GH/calls"
}

@test "custom patterns, newline-separated" {
    release v1.0.0 0 hello_1.0.0_amd64.deb hello-1.0.0-1.x86_64.rpm other_1.0.0_amd64.deb
    fetch --patterns 'hello_*.deb
hello-*.rpm'
    assert_status 0
    [ -f "$TMP/assets/hello_1.0.0_amd64.deb" ]
    [ -f "$TMP/assets/hello-1.0.0-1.x86_64.rpm" ]
    [ ! -e "$TMP/assets/other_1.0.0_amd64.deb" ]
}

@test "patterns are not expanded against files in the working directory" {
    release v1.0.0 0 hello_1.0.0_amd64.deb
    cd "$TMP"
    touch local.deb
    fetch
    assert_status 0
    grep -q -- '--pattern \*.deb' "$FAKE_GH/calls"
    refute grep -q 'local.deb' "$FAKE_GH/calls"
}

@test "keep 0 fetches nothing and does not call gh" {
    release v1.0.0 0 hello_1.0.0_amd64.deb
    fetch --keep 0
    assert_status 0
    [ ! -e "$FAKE_GH/calls" ]
    [ -d "$TMP/assets" ]
    [ -z "$(output_value tags)" ]
}

@test "existing files in the directory are kept" {
    release v1.0.0 0 hello_1.0.0_amd64.deb
    mkdir -p "$TMP/assets"
    echo mine > "$TMP/assets/current.deb"
    fetch
    assert_status 0
    [ "$(cat "$TMP/assets/current.deb")" = mine ]
}

@test "a failed download is an error, not a shorter history" {
    release v1.0.0 0 hello_1.0.0_amd64.deb
    touch "$FAKE_GH/fail-download"
    fetch
    assert_status 1
    assert_output_contains "downloading the assets of v1.0.0 failed"
}

@test "a failed release list is an error" {
    rm -f "$FAKE_GH/releases"
    printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"
    fetch
    assert_status 1
}

@test "input validation" {
    fetch --keep -1;            assert_status 1
    fetch --keep lots;          assert_status 1
    fetch --keep 101;           assert_status 1
    fetch --include-prereleases yes; assert_status 1
    fetch --repository 'not a repo'; assert_status 1
    fetch --patterns '../*.deb'; assert_status 1
    run "$LIB/fetch-history.sh"; assert_status 1
}

@test "two releases with an asset of the same name: both are kept" {
    release v2.0.0 0 tool_amd64.deb
    release v1.0.0 0 tool_amd64.deb
    fetch
    assert_status 0
    [ "$(cat "$TMP/assets/tool_amd64.deb")" = v2.0.0 ]
    [ "$(cat "$TMP/assets/v1.0.0_tool_amd64.deb")" = v1.0.0 ]
}

@test "an asset identical to an existing file is skipped" {
    mkdir "$TMP/assets"
    echo v1.0.0 > "$TMP/assets/a.deb"
    release v1.0.0 0 a.deb
    fetch
    assert_status 0
    [ "$(cat "$TMP/assets/a.deb")" = v1.0.0 ]
    [ ! -e "$TMP/assets/v1.0.0_a.deb" ]
}

@test "an existing file is never replaced" {
    mkdir "$TMP/assets"
    echo mine > "$TMP/assets/a.deb"
    release v1.0.0 0 a.deb
    fetch
    assert_status 0
    [ "$(cat "$TMP/assets/a.deb")" = mine ]
    [ "$(cat "$TMP/assets/v1.0.0_a.deb")" = v1.0.0 ]
}

@test "a tag's characters become _ in the stored name" {
    release rel/2 0 t.deb
    release rel/1 0 t.deb
    fetch
    assert_status 0
    [ "$(cat "$TMP/assets/t.deb")" = rel/2 ]
    [ "$(cat "$TMP/assets/rel_1_t.deb")" = rel/1 ]
}

@test "no place left for a differing asset is an error" {
    mkdir "$TMP/assets"
    echo mine > "$TMP/assets/a.deb"
    echo other > "$TMP/assets/v1.0.0_a.deb"
    release v1.0.0 0 a.deb
    fetch
    assert_status 1
    [[ "$output" == *"differs from both"* ]]
}

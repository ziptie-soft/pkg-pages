#!/usr/bin/env bats
# lib/fetch-history.sh against a fake `gh` that serves releases from files, and, for site mode,
# a fake `curl` that serves a fixture site from a directory (plus real curl on file:// URLs), so
# no network or token is needed. The release tests run anywhere; the site tests need gpg and gpgv
# (tests/container.sh runs them).

load helpers

Z=0000000000000000000000000000000000000000000000000000000000000000

# The fixture site for the site tests, written by hand in the manifest format of docs/design.md
# (not by pages-repo.sh), once for the file. Package files hold their own path as text. Keys:
#   a  the project's key (helpers.bash keys): signs the site
#   b  another project's key
#   r  a key whose signing subkey is revoked after it signed the manifest
#   x  a key whose signing subkey expired after it signed a site (a faked clock)
# No gpg: nothing is generated, and the site tests skip themselves.
setup_file() {
    command -v gpg > /dev/null || return 0
    keys
    S="$BATS_FILE_TMPDIR/site"
    for p in $(site_paths); do
        mkdir -p "$S/$(dirname "$p")"
        # The two noarch copies of one package hold the same bytes.
        case "$p" in rpm/*/hello-doc-*) printf 'doc\n' > "$S/$p" ;; *) printf '%s\n' "$p" > "$S/$p" ;; esac
    done
    site_rows | manifest "$S" hello "$(cat "$K/a/fpr")"
    sign_manifest "$S" "$K/a/home" "$(cat "$K/a/sub")"
    export S

    # r: the manifest signed by subkey 1, which is then revoked; subkey 2 replaces it.
    "$FIXTURES" key "$K/r" "project r"
    fpr="$(cat "$K/r/fpr")"
    cp "$S/pkg-pages.tsv" "$K/r/pkg-pages.tsv"
    sign_manifest "$K/r" "$K/r/home" "$(cat "$K/r/sub")"
    sleep 1
    printf 'key 1\nrevkey\ny\n0\n\ny\nsave\n' |
        gpg --homedir "$K/r/home" --batch --pinentry-mode loopback --passphrase '' \
            --command-fd 0 --status-fd 2 --edit-key "$fpr" 2> /dev/null
    gpg --homedir "$K/r/home" --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-add-key "$fpr" rsa2048 sign 3y 2> /dev/null
    gpg --homedir "$K/r/home" --batch --quiet --armor --export "$fpr" > "$K/r/pin-rotated.asc"

    # x: made in 2020 with a signing subkey valid for one day, and a site signed that day.
    mkdir -p "$K/x/home" && chmod 700 "$K/x/home"
    gx() { gpg --homedir "$K/x/home" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"; }
    gx --faked-system-time=20200101T000000! --quick-gen-key 'project x <x@example.invalid>' rsa2048 cert never 2> /dev/null
    fpr="$(gx --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    gx --faked-system-time=20200101T000000! --quick-add-key "$fpr" rsa2048 sign 1d 2> /dev/null
    sub="$(gx --with-colons --with-subkey-fingerprints --list-keys |
        awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')"
    gx --armor --export "$fpr" > "$K/x/pin.asc"
    cp -a "$S" "$K/x/site"
    site_rows | manifest "$K/x/site" hello "$fpr"
    sign_manifest "$K/x/site" "$K/x/home" "$sub" --faked-system-time=20200101T120000!
}

teardown_file() {
    kill_agents "$BATS_FILE_TMPDIR"
}

# site_paths: the package paths of the fixture site, one per line, sorted within a release.
site_paths() {
    site_rows | while read -r _ _ path; do echo "$path"; done
}

# site_rows: "KIND TAG PATH" rows of the fixture manifest, in the order the build writes them.
site_rows() {
    cat << 'EOF'
release v1.3.0 deb/pool/h/hello/hello_1.3.0_amd64.deb
release v1.2.0 deb/pool/h/hello/hello_1.2.0_amd64.deb
release v1.2.0 rpm/aarch64/hello-doc-1.2.0-1.noarch.rpm
release v1.2.0 rpm/x86_64/hello-1.2.0-1.x86_64.rpm
release v1.2.0 rpm/x86_64/hello-doc-1.2.0-1.noarch.rpm
release v1.1.0 deb/pool/h/hello/hello_1.1.0_amd64.deb
release v1.0.0 deb/pool/h/hello/hello_1.0.0_amd64.deb
keyring - deb/pool/h/hello-keyring/hello-keyring_20240101.000000_all.deb
keyring - deb/pool/h/hello-keyring/hello-keyring_20250101.000000_all.deb
EOF
}

# manifest DIR NAME FPR: write DIR/pkg-pages.tsv from "KIND TAG PATH" rows on stdin, with the
# SHA-256 of DIR/PATH, and a header naming the key FPR.
manifest() {
    {
        printf '#pkg-pages-manifest\t1\t%s\t%s\n' "$2" "$3"
        while read -r kind tag path; do
            printf '%s\t%s\t%s\t%s\n' "$kind" "$tag" "$(sha256sum "$1/$path" | cut -d' ' -f1)" "$path"
        done
    } > "$1/pkg-pages.tsv"
}

# sign_manifest DIR HOME SUBKEY [GPG ARGS]: DIR/pkg-pages.tsv.asc, detached and armored, made by
# exactly that subkey.
sign_manifest() {
    _d="$1" _h="$2" _s="$3"
    shift 3
    rm -f "$_d/pkg-pages.tsv.asc"
    gpg --homedir "$_h" --batch --quiet --pinentry-mode loopback --passphrase '' "$@" \
        --local-user "$_s!" --armor --detach-sign --output "$_d/pkg-pages.tsv.asc" "$_d/pkg-pages.tsv"
}

# site_tools: skip the test unless the site tests can run.
site_tools() {
    need gpg gpgv sha256sum awk
    [ -d "${S:-}" ] || skip "no fixture site"
}

# mysite: this test's copy of the fixture site, served by the fake curl.
mysite() {
    site_tools
    cp -a "$S" "$FAKE_SITE"
}

# sfetch ARGS...: site mode against the fake site, pinned to key a, into $TMP/history. With no
# --tags, the fake gh decides (see release).
sfetch() {
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --public-key "$K/a/pin.asc" "$@"
}

# rawsite ROW...: replace the manifest with the header and the given tab-separated rows (as
# printf formats), signed by key a.
rawsite() {
    {
        printf '#pkg-pages-manifest\t1\thello\t%s\n' "$(cat "$K/a/fpr")"
        for r in "$@"; do printf '%b\n' "$r"; done
    } > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
}

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
    # The fake curl maps https://pages.test/PATH to $FAKE_SITE/PATH, logs its arguments to
    # $FAKE_SITE_LOG, answers a missing file with HTTP 404 (exit 22, as --fail does), and fails
    # with exit 56 for the one PATH in $FAKE_CURL_FAIL.
    export FAKE_SITE="$TMP/site" FAKE_SITE_LOG="$TMP/curl-calls"
    cat > "$TMP/bin/curl" << 'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_SITE_LOG"
out='' wo='' url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift ;;
        --write-out) wo="$2"; shift ;;
        --proto | --proto-redir | --max-redirs | --max-filesize | --retry) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
case "$url" in https://pages.test/*) ;; *) echo "fake curl: unexpected URL $url" >&2; exit 2 ;; esac
rel="${url#https://pages.test/}"
if [ "$rel" = "${FAKE_CURL_FAIL:-}" ]; then
    [ -z "$wo" ] || printf 000
    echo "curl: (56) Recv failure" >&2
    exit 56
fi
if [ -f "$FAKE_SITE/$rel" ]; then
    cp "$FAKE_SITE/$rel" "$out"
    [ -z "$wo" ] || printf 200
    exit 0
fi
[ -z "$wo" ] || printf 404
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
    chmod +x "$TMP/bin/curl"
    export PATH="$TMP/bin:$PATH"
    unset GITHUB_ACTIONS
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

# --- releases mode: --map and --tags ----------------------------------------------------------

@test "releases --map: one release line per file, with its SHA-256 and the path stored" {
    release v2.0.0 0 a.deb
    release v1.0.0 0 a.deb b.rpm
    fetch --map "$TMP/out/map"
    assert_status 0
    [ "$(output_value map)" = "$TMP/out/map" ]
    # v1.0.0's a.deb differs from v2.0.0's, so it is stored under the tag's name.
    printf 'v2.0.0\t%s\ta.deb\trelease\nv1.0.0\t%s\tb.rpm\trelease\nv1.0.0\t%s\tv1.0.0_a.deb\trelease\n' \
        "$(printf 'v2.0.0\n' | sha256sum | cut -d' ' -f1)" \
        "$(printf 'v1.0.0\n' | sha256sum | cut -d' ' -f1)" \
        "$(printf 'v1.0.0\n' | sha256sum | cut -d' ' -f1)" > "$TMP/expected"
    cmp "$TMP/out/map" "$TMP/expected"
}

@test "releases --map: a skipped identical asset is recorded, and the map is rewritten" {
    mkdir "$TMP/assets"
    echo v1.0.0 > "$TMP/assets/a.deb"
    release v1.0.0 0 a.deb
    mkdir "$TMP/out"
    echo stale > "$TMP/out/map"
    fetch --map "$TMP/out/map"
    assert_status 0
    [ "$(wc -l < "$TMP/out/map")" -eq 1 ]
    grep -q "^v1.0.0	.*	a.deb	release$" "$TMP/out/map"
    # keep 0: the map is created, and empty
    fetch --keep 0 --map "$TMP/out/map"
    assert_status 0
    [ -f "$TMP/out/map" ] && [ ! -s "$TMP/out/map" ]
}

@test "releases without --map: no map is written and no output named map" {
    release v1.0.0 0 a.deb
    fetch
    assert_status 0
    [ -z "$(output_value map)" ]
}

@test "releases --tags: gh is not asked for the list, and keep and exclude-tag don't apply" {
    release v3.0.0 0 a.deb
    release v2.0.0 0 b.deb
    release v1.0.0 0 c.deb
    fetch --tags "v1.0.0 v3.0.0 v1.0.0" --keep 1 --exclude-tag v3.0.0
    assert_status 0
    refute grep -q 'release list' "$FAKE_GH/calls"
    [ "$(output_value tags)" = "v1.0.0 v3.0.0" ]
    [ -f "$TMP/assets/a.deb" ] && [ -f "$TMP/assets/c.deb" ] && [ ! -e "$TMP/assets/b.deb" ]
}

@test "releases --tags: keep 0 still fetches nothing" {
    release v1.0.0 0 a.deb
    fetch --tags v1.0.0 --keep 0
    assert_status 0
    [ ! -e "$FAKE_GH/calls" ]
}

@test "--tags must be plain tags" {
    fetch --tags '-x';     assert_status 1
    fetch --tags 'a;b';    assert_status 1
    fetch --tags '$(id)';  assert_status 1
    fetch --from nowhere;  assert_status 1
}

# --- site mode ------------------------------------------------------------------------------------

@test "site: fetches the selected tags and the newest keyring package, and writes the map" {
    mysite
    sfetch --tags "v1.2.0 v1.1.0" --map "$TMP/map"
    assert_status 0
    [ "$(output_value tags)" = "v1.2.0 v1.1.0" ]
    [ "$(output_value map)" = "$TMP/map" ]
    for p in deb/pool/h/hello/hello_1.2.0_amd64.deb rpm/aarch64/hello-doc-1.2.0-1.noarch.rpm \
        rpm/x86_64/hello-1.2.0-1.x86_64.rpm rpm/x86_64/hello-doc-1.2.0-1.noarch.rpm \
        deb/pool/h/hello/hello_1.1.0_amd64.deb \
        deb/pool/h/hello-keyring/hello-keyring_20250101.000000_all.deb; do
        cmp "$TMP/history/$p" "$S/$p"
    done
    [ ! -e "$TMP/history/deb/pool/h/hello/hello_1.3.0_amd64.deb" ]
    [ ! -e "$TMP/history/deb/pool/h/hello/hello_1.0.0_amd64.deb" ]
    [ ! -e "$TMP/history/deb/pool/h/hello-keyring/hello-keyring_20240101.000000_all.deb" ]
    # The map: the tags in the order given, each tag's files in manifest order, the keyring last.
    : > "$TMP/expected"
    while read -r tag p; do
        printf '%s\t%s\t%s\tsite\n' "$tag" "$(sha "$S/$p")" "$p" >> "$TMP/expected"
    done << 'EOF'
v1.2.0 deb/pool/h/hello/hello_1.2.0_amd64.deb
v1.2.0 rpm/aarch64/hello-doc-1.2.0-1.noarch.rpm
v1.2.0 rpm/x86_64/hello-1.2.0-1.x86_64.rpm
v1.2.0 rpm/x86_64/hello-doc-1.2.0-1.noarch.rpm
v1.1.0 deb/pool/h/hello/hello_1.1.0_amd64.deb
- deb/pool/h/hello-keyring/hello-keyring_20250101.000000_all.deb
EOF
    cmp "$TMP/map" "$TMP/expected"
}

@test "site: fetches verified Debian and RPM paths with pre-release tildes" {
    mysite
    tag='v1.2.3~rc1-1'
    deb_path='deb/pool/main/h/hello/hello_1.2.3~rc1-1_amd64.deb'
    rpm_path='rpm/x86_64/hello-1.2.3~rc1-1.x86_64.rpm'
    mkdir -p "$FAKE_SITE/$(dirname "$deb_path")" "$FAKE_SITE/$(dirname "$rpm_path")"
    printf 'debian pre-release package\n' > "$FAKE_SITE/$deb_path"
    printf 'rpm pre-release package\n' > "$FAKE_SITE/$rpm_path"
    rawsite \
        "release\t$tag\t$(sha "$FAKE_SITE/$deb_path")\t$deb_path" \
        "release\t$tag\t$(sha "$FAKE_SITE/$rpm_path")\t$rpm_path"

    sfetch --tags "$tag" --map "$TMP/map"
    assert_status 0
    [ "$(output_value tags)" = "$tag" ]
    cmp "$TMP/history/$deb_path" "$FAKE_SITE/$deb_path"
    cmp "$TMP/history/$rpm_path" "$FAKE_SITE/$rpm_path"
    printf '%s\t%s\t%s\tsite\n%s\t%s\t%s\tsite\n' \
        "$tag" "$(sha "$FAKE_SITE/$deb_path")" "$deb_path" \
        "$tag" "$(sha "$FAKE_SITE/$rpm_path")" "$rpm_path" > "$TMP/expected-map"
    cmp "$TMP/map" "$TMP/expected-map"
}

@test "site: without --map nothing but the files is written" {
    mysite
    sfetch --tags v1.1.0
    assert_status 0
    [ -z "$(output_value map)" ]
    [ "$(find "$TMP/history" -type f | wc -l)" -eq 2 ]
}

@test "site: curl gets the documented flags, the file URL path and no gh" {
    mysite
    sfetch --tags v1.1.0
    assert_status 0
    grep -q -- '--fail ' "$FAKE_SITE_LOG"
    grep -q -- '--proto =https,file --proto-redir =https' "$FAKE_SITE_LOG"
    grep -q -- '--max-filesize 100M --retry 3' "$FAKE_SITE_LOG"
    grep -q 'https://pages.test/pkg-pages.tsv$' "$FAKE_SITE_LOG"
    grep -q 'https://pages.test/pkg-pages.tsv.asc$' "$FAKE_SITE_LOG"
    grep -q 'https://pages.test/deb/pool/h/hello/hello_1.1.0_amd64.deb$' "$FAKE_SITE_LOG"
    [ ! -e "$FAKE_GH/calls" ]
}

@test "site: each SHA-256 is downloaded once, and copied to every path" {
    mysite
    sfetch --tags v1.2.0
    assert_status 0
    # The two noarch copies share their bytes: one download.
    [ "$(grep -c 'hello-doc-1.2.0-1.noarch.rpm$' "$FAKE_SITE_LOG")" -eq 1 ]
    cmp "$TMP/history/rpm/aarch64/hello-doc-1.2.0-1.noarch.rpm" "$TMP/history/rpm/x86_64/hello-doc-1.2.0-1.noarch.rpm"
}

@test "site: the tags come from the GitHub release list, without the current one" {
    mysite
    release v1.3.0 0 x.deb
    release v1.2.0 0 x.deb
    release v1.1.0 0 x.deb
    release v1.0.0 0 x.deb
    sfetch --keep 2 --exclude-tag v1.3.0
    assert_status 0
    [ "$(output_value tags)" = "v1.2.0 v1.1.0" ]
    grep -q 'release list' "$FAKE_GH/calls"
    [ ! -e "$TMP/history/deb/pool/h/hello/hello_1.3.0_amd64.deb" ]
}

@test "site: --keep 0 fetches nothing, and uses no network" {
    mysite
    sfetch --tags v1.1.0 --keep 0
    assert_status 0
    [ ! -e "$FAKE_SITE_LOG" ]
    [ -d "$TMP/history" ]
    [ -z "$(output_value tags)" ]
}

@test "site: a tag the manifest lacks is skipped with a notice" {
    mysite
    sfetch --tags "v9.9.9 v1.1.0"
    assert_status 0
    assert_output_contains "release v9.9.9 has no packages"
    [ "$(output_value tags)" = v1.1.0 ]
}

@test "site: no manifest on the site is an error that names the bootstrap" {
    mysite
    rm "$FAKE_SITE/pkg-pages.tsv" "$FAKE_SITE/pkg-pages.tsv.asc"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "the site has no pkg-pages.tsv: run once with history-from: releases"
}

@test "site: a failing download is an error, not a missing manifest" {
    mysite
    FAKE_CURL_FAIL=pkg-pages.tsv sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "downloading https://pages.test/pkg-pages.tsv failed (curl exit 56"
    refute grep -q 'has no pkg-pages.tsv' <<< "$output"
}

@test "site: the manifest is verified against the pin" {
    mysite
    # tampered after signing
    printf 'release\tv0.0.1\t%s\tdeb/pool/h/hello/hello_0.0.1_amd64.deb\n' "$Z" >> "$FAKE_SITE/pkg-pages.tsv"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "does not verify"
    # signed by another project's key
    cp "$S/pkg-pages.tsv" "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/b/home" "$(cat "$K/b/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "does not verify"
    [ ! -e "$TMP/history" ] || [ -z "$(find "$TMP/history" -type f)" ]
}

@test "site: a revoked signing subkey fails, and the error points to the bootstrap" {
    mysite
    cp "$K/r/pkg-pages.tsv.asc" "$FAKE_SITE/pkg-pages.tsv.asc"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --public-key "$K/r/pin-rotated.asc" --tags v1.1.0
    assert_status 1
    assert_output_contains "REVKEYSIG"
    assert_output_contains "history-from: releases and resign-history: true"
}

@test "site: an expired signing subkey is accepted, with a warning" {
    site_tools
    cp -a "$K/x/site" "$FAKE_SITE"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --public-key "$K/x/pin.asc" --tags v1.1.0
    assert_status 0
    assert_output_contains "expired subkey"
    cmp "$TMP/history/deb/pool/h/hello/hello_1.1.0_amd64.deb" "$S/deb/pool/h/hello/hello_1.1.0_amd64.deb"
}

@test "site: the header's name and fingerprint must match" {
    mysite
    fpr="$(cat "$K/a/fpr")"
    sed "1s/	hello	/	other	/" "$S/pkg-pages.tsv" > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains 'the manifest is for "other", not "hello"'
    sed "1s/	$fpr\$/	-/" "$S/pkg-pages.tsv" > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains 'names the key "-"'
    sed "1s/	1	/	2	/" "$S/pkg-pages.tsv" > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "not a pkg-pages manifest of version 1"
}

@test "site: a manifest of another key's fingerprint fails even when validly signed by the pin's key" {
    mysite
    sed "1s/	[0-9A-F]*\$/	$(cat "$K/b/fpr")/" "$S/pkg-pages.tsv" > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "the manifest names the key"
}

@test "site: every line must follow the manifest format and the path rule" {
    mysite
    bad=(
        "release\tv1\t$Z\tdeb/pool/../x.deb"
        "release\tv1\t$Z\tdeb/pool/a/../b.deb"
        "release\tv1\t$Z\tdeb/pool/./x.deb"
        "release\tv1\t$Z\t/deb/pool/x.deb"
        "release\tv1\t$Z\tdeb/x.deb"
        "release\tv1\t$Z\tdeb/pool/x.rpm"
        "release\tv1\t$Z\tdeb/pool/x y.deb"
        "release\tv1\t$Z\tdeb/pool//x.deb"
        "release\tv1\t$Z\tdeb/pool/.deb"
        "release\tv1\t$Z\trpm/x86_64/sub/x.rpm"
        "release\tv1\t$Z\trpm/x86_64/x.deb"
        "release\tv1\t$Z\trpm/../x.rpm"
        "release\tv1\tABC\tdeb/pool/x.deb"
        "release\tv1\t${Z%0}G\tdeb/pool/x.deb"
        "release\tv1\t${Z/0/A}\tdeb/pool/x.deb"
        "other\tv1\t$Z\tdeb/pool/x.deb"
        "release\t-\t$Z\tdeb/pool/x.deb"
        "release\tv 1\t$Z\tdeb/pool/x.deb"
        "keyring\tv1\t$Z\tdeb/pool/hello-keyring_20250101.000000_all.deb"
        "keyring\t-\t$Z\tdeb/pool/other_20250101.000000_all.deb"
        "keyring\t-\t$Z\tdeb/pool/hello-keyring_2025.1_all.deb"
        "keyring\t-\t$Z\trpm/x86_64/hello-keyring_20250101.000000_all.rpm"
        "release\tv1\t$Z"
        "release\tv1\t$Z\tdeb/pool/x.deb\textra"
        ""
        "release\tv1\t$Z\tdeb/pool/x.deb\nrelease\tv2\t$Z\tdeb/pool/x.deb"
    )
    for row in "${bad[@]}"; do
        rawsite "release\tv1.1.0\t$Z\tdeb/pool/ok.deb" "$row"
        sfetch --tags v1.1.0
        if [ "$status" -ne 1 ]; then
            printf 'accepted: %s\n%s\n' "$row" "$output" >&2
            return 1
        fi
        case "$output" in
            *"the manifest of https://pages.test is not valid: manifest line"*) ;;
            *) printf 'wrong error for: %s\n%s\n' "$row" "$output" >&2; return 1 ;;
        esac
    done
}

@test "site: the whole manifest is checked, not only the selected tags" {
    mysite
    rawsite "release\tv1.1.0\t$Z\tdeb/pool/ok.deb" "release\tv9\t$Z\tdeb/pool/../evil.deb"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "is not valid"
}

@test "site: an empty manifest, or one with only a header, is checked too" {
    mysite
    : > "$FAKE_SITE/pkg-pages.tsv"
    sign_manifest "$FAKE_SITE" "$K/a/home" "$(cat "$K/a/sub")"
    sfetch --tags v1.1.0
    assert_status 1
    rawsite
    sfetch --tags v1.1.0
    assert_status 0
    [ -z "$(output_value tags)" ]
}

@test "site: a download with other bytes than the manifest says is an error" {
    mysite
    printf 'evil\n' > "$FAKE_SITE/deb/pool/h/hello/hello_1.1.0_amd64.deb"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "has the SHA-256"
    [ ! -e "$TMP/history/deb/pool/h/hello/hello_1.1.0_amd64.deb" ]
}

@test "site: a package the site lacks is an error" {
    mysite
    rm "$FAKE_SITE/deb/pool/h/hello/hello_1.1.0_amd64.deb"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "is in the manifest but the site does not have it"
}

@test "site: a pin without a signature, and a signature without a pin, are errors" {
    mysite
    rm "$FAKE_SITE/pkg-pages.tsv.asc"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "the site has no pkg-pages.tsv.asc"
    cp "$S/pkg-pages.tsv.asc" "$FAKE_SITE/pkg-pages.tsv.asc"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --public-key "$TMP/absent.asc" --tags v1.1.0
    assert_status 1
    assert_output_contains "is signed, but public-key"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --tags v1.1.0
    assert_status 1
    assert_output_contains "is signed, but public-key"
}

@test "site: no pin and an unsigned site: fetched, unverified, with a notice" {
    mysite
    rm "$FAKE_SITE/pkg-pages.tsv.asc"
    sed '1s/	[0-9A-F]*$/	-/' "$S/pkg-pages.tsv" > "$FAKE_SITE/pkg-pages.tsv"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test \
        --name hello --public-key "$TMP/absent.asc" --tags v1.1.0
    assert_status 0
    assert_output_contains "is not verified"
    [ -f "$TMP/history/deb/pool/h/hello/hello_1.1.0_amd64.deb" ]
    # such a manifest names no key
    run "$LIB/fetch-history.sh" --dir "$TMP/history2" --from site --url https://pages.test \
        --name hello --tags v1.1.0
    assert_status 0
    cp "$S/pkg-pages.tsv" "$FAKE_SITE/pkg-pages.tsv"
    run "$LIB/fetch-history.sh" --dir "$TMP/history3" --from site --url https://pages.test \
        --name hello --tags v1.1.0
    assert_status 1
    assert_output_contains "the manifest names the key"
}

@test "site: a file already in the directory must hold the same bytes" {
    mysite
    p=deb/pool/h/hello/hello_1.1.0_amd64.deb
    mkdir -p "$TMP/history/$(dirname "$p")"
    cp "$S/$p" "$TMP/history/$p"
    sfetch --tags v1.1.0 --map "$TMP/map"
    assert_status 0
    grep -q "	$p	site$" "$TMP/map"
    echo mine > "$TMP/history/$p"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "exists and differs"
}

@test "site: a symbolic link at the destination is refused" {
    mysite
    p=deb/pool/h/hello/hello_1.1.0_amd64.deb
    mkdir -p "$TMP/history/$(dirname "$p")"
    cp "$S/$p" "$TMP/target"
    ln -s "$TMP/target" "$TMP/history/$p"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "symbolic link"
}

@test "site: a directory in the way that links outside is refused" {
    mysite
    mkdir -p "$TMP/history" "$TMP/outside"
    ln -s "$TMP/outside" "$TMP/history/deb"
    sfetch --tags v1.1.0
    assert_status 1
    assert_output_contains "outside"
    [ -z "$(find "$TMP/outside" -type f)" ]
}

@test "site: input validation" {
    mysite
    sfetch --url http://pages.test --tags v1.1.0;       assert_status 1
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --name hello --tags v1.1.0
    assert_status 1
    assert_output_contains "--url is required"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url https://pages.test --tags v1.1.0
    assert_status 1
    assert_output_contains "--name is required"
    sfetch --name 'Bad Name' --tags v1.1.0;             assert_status 1
    # without --tags, the repository is needed for the release list
    GITHUB_REPOSITORY='' run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site \
        --url https://pages.test --name hello
    assert_status 1
    assert_output_contains "repository must be owner/repo"
    # with --tags, it is not
    GITHUB_REPOSITORY='' sfetch --tags v1.1.0
    assert_status 0
}

@test "site: real curl on a file:// URL, including a missing manifest" {
    site_tools
    # Not the fake curl: the real one, with the documented flags. (--tags: no gh needed.)
    PATH="${PATH#"$TMP/bin:"}"
    need curl
    cp -a "$S" "$TMP/filesite"
    run "$LIB/fetch-history.sh" --dir "$TMP/history" --from site --url "file://$TMP/filesite/" \
        --name hello --public-key "$K/a/pin.asc" --tags "v1.2.0 v1.1.0" --map "$TMP/map"
    assert_status 0
    [ "$(output_value tags)" = "v1.2.0 v1.1.0" ]
    cmp "$TMP/history/rpm/x86_64/hello-1.2.0-1.x86_64.rpm" "$S/rpm/x86_64/hello-1.2.0-1.x86_64.rpm"
    [ "$(wc -l < "$TMP/map")" -eq 6 ]
    rm "$TMP/filesite/pkg-pages.tsv"
    run "$LIB/fetch-history.sh" --dir "$TMP/history2" --from site --url "file://$TMP/filesite" \
        --name hello --public-key "$K/a/pin.asc" --tags v1.1.0
    assert_status 1
    assert_output_contains "the site has no pkg-pages.tsv"
}

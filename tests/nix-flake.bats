#!/usr/bin/env bats
# lib/nix-flake.sh: validate archives and build the deterministic, hash-pinned flake tarball.

load helpers

setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    export TMP GITHUB_OUTPUT="$TMP/github_output" GITHUB_ENV="$TMP/github_env"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_ENV"
    unset GITHUB_ACTIONS REPO_SIGNING_KEY GNUPGHOME PKG_PAGES_PIN
    mkdir -p "$TMP/archive/hello-1.2.3/bin"
    printf '#!/bin/sh\necho hi\n' > "$TMP/archive/hello-1.2.3/bin/hello"
    chmod +x "$TMP/archive/hello-1.2.3/bin/hello"
    tar -czf "$TMP/hello.tar.gz" -C "$TMP/archive" hello-1.2.3
}

teardown() {
    rm -rf "$TMP"
}

make_flake() {
    archive_list="$(printf 'x86_64-linux=%s\naarch64-linux=%s' "$TMP/hello.tar.gz" "$TMP/hello.tar.gz")"
    run "$LIB/nix-flake.sh" --out "$1" --name hello --version 1.2.3 \
        --url-base https://example.test/releases --binaries 'bin/hello' \
        --archives "$archive_list"
}

@test "flake pins the archive, names its main program, and has a deterministic tarball" {
    need tar gzip sha256sum awk sort
    make_flake "$TMP/out-a"
    assert_status 0
    make_flake "$TMP/out-b"
    assert_status 0
    grep -q 'url = "https://example.test/releases/hello.tar.gz"' "$TMP/out-a/flake.nix"
    grep -q "sha256 = \"$(sha "$TMP/hello.tar.gz")\"" "$TMP/out-a/flake.nix"
    grep -q 'x86_64-linux = { url = "https://example.test/releases/hello.tar.gz"' "$TMP/out-a/flake.nix"
    grep -q 'aarch64-linux = { url = "https://example.test/releases/hello.tar.gz"' "$TMP/out-a/flake.nix"
    grep -q 'meta.mainProgram = "hello"' "$TMP/out-a/flake.nix"
    [ "$(tar -tzf "$TMP/out-a/flake.tar.gz" | LC_ALL=C sort)" = "flake.lock
flake.nix" ]
    cmp -s "$TMP/out-a/flake.tar.gz" "$TMP/out-b/flake.tar.gz"
}

@test "mainProgram is the first binary, even with surrounding spaces; every option is required" {
    need tar gzip sha256sum
    run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
        --url-base https://example.test/releases --binaries '  bin/hello ' \
        --archives "x86_64-linux=$TMP/hello.tar.gz"
    assert_status 0
    grep -q 'meta.mainProgram = "hello"' "$TMP/out/flake.nix"
    run "$LIB/nix-flake.sh" --out "$TMP/out2" --name hello --version 1.2.3 \
        --url-base https://example.test/releases --binaries bin/hello
    [ "$status" -ne 0 ]
    assert_output_contains 'are all required'
}

@test "flake lock is pinned to the generator ref and has a narHash" {
    ref="$(sed -n 's/^nixpkgs_ref=//p' "$LIB/nix-flake.sh")"
    grep -q "\"ref\": \"$ref\"" "$LIB/nix/flake.lock"
    grep -Eq '"rev": "[0-9a-f]{40}"' "$LIB/nix/flake.lock"
    grep -Eq '"narHash": "sha256-[A-Za-z0-9+/=]+"' "$LIB/nix/flake.lock"
}

@test "flake rejects systems, duplicate systems, unsafe filenames, and missing files" {
    for archives in "unknown-linux=$TMP/hello.tar.gz" \
        "x86_64-linux=$TMP/hello.tar.gz
x86_64-linux=$TMP/hello.tar.gz" \
        "x86_64-linux=$TMP/bad name.tar.gz" \
        "x86_64-linux=$TMP/missing.tar.gz"; do
        run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
            --url-base https://example.test --binaries bin/hello --archives "$archives"
        assert_status 1
        rm -rf "$TMP/out"
    done
}

@test "flake rejects unsafe binaries, missing members, multiple roots, and unsafe URLs" {
    for binary in '../hello' 'bin/../hello' 'bin/hello world' '/bin/hello'; do
        run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
            --url-base https://example.test --binaries "$binary" \
            --archives "x86_64-linux=$TMP/hello.tar.gz"
        assert_status 1
        rm -rf "$TMP/out"
    done
    run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
        --url-base https://example.test --binaries bin/missing \
        --archives "x86_64-linux=$TMP/hello.tar.gz"
    assert_status 1
    mkdir -p "$TMP/archive/other/bin"
    tar -czf "$TMP/two.tar.gz" -C "$TMP/archive" hello-1.2.3 other
    run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
        --url-base https://example.test --binaries bin/hello \
        --archives "x86_64-linux=$TMP/two.tar.gz"
    assert_status 1
    run "$LIB/nix-flake.sh" --out "$TMP/out" --name hello --version 1.2.3 \
        --url-base 'https://example.test/"quote' --binaries bin/hello \
        --archives "x86_64-linux=$TMP/hello.tar.gz"
    assert_status 1
}

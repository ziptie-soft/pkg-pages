#!/usr/bin/env bats
# lib/run.sh: host and docker modes. docker mode is checked against a fake engine that records
# its arguments, so no container runs; tests/container.sh and CI run the real images.

load helpers

setup() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkg-pages-test.XXXXXX")"
    export GITHUB_OUTPUT="$TMP/github_output" GITHUB_ENV="$TMP/github_env"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_ENV"
    unset GITHUB_ACTIONS REPO_SIGNING_KEY GNUPGHOME
    mkdir -p "$TMP/bin" "$TMP/work"
    # The fake engine: one argument per line in docker.args, its environment in docker.env, and a
    # step output written through the mounted io directory, as a real container would.
    cat > "$TMP/bin/docker" << 'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_LOG/docker.args"
env > "$FAKE_LOG/docker.env"
prev=
for a in "$@"; do
    case "$prev:$a" in --volume:*:/pkg-pages-io)
        io="${a%:/pkg-pages-io}"
        stat -c %a "$io" "$io/output" "$io/env" > "$FAKE_LOG/io.modes"
        echo "from=container" >> "$io/output" ;;
    esac
    prev="$a"
done
exit "${FAKE_STATUS:-0}"
EOF
    chmod +x "$TMP/bin/docker"
    cp "$TMP/bin/docker" "$TMP/bin/podman"
    export FAKE_LOG="$TMP" PATH="$TMP/bin:$PATH" DOCKER=docker
    cd "$TMP/work" || return 1
}

teardown() {
    cd /
    rm -rf "$TMP"
}

args() { cat "$TMP/docker.args"; }

# has_args A B: the recorded docker arguments contain A immediately followed by B.
has_args() {
    awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit !found }' "$TMP/docker.args"
}

@test "host mode runs the command and passes its status" {
    run "$LIB/run.sh" host -- sh -c 'echo hi; exit 3'
    assert_status 3
    [ "$output" = hi ]
}

@test "host mode names missing tools before running anything" {
    run "$LIB/run.sh" host --tools "sh no-such-tool" -- touch "$TMP/ran"
    assert_status 1
    assert_output_contains "no-such-tool"
    [ ! -e "$TMP/ran" ]
}

@test "host mode --gnupg: a fresh private GNUPGHOME, removed afterwards, even on failure" {
    run "$LIB/run.sh" host --gnupg -- sh -c 'echo "$GNUPGHOME"; ls -A "$GNUPGHOME" | wc -l; stat -c %a "$GNUPGHOME"; exit 4'
    assert_status 4
    home="$(echo "$output" | sed -n 1p)"
    [ "$(echo "$output" | sed -n 2p | tr -d ' ')" = 0 ]
    [ "$(echo "$output" | sed -n 3p)" = 700 ]
    [ ! -e "$home" ]
}

@test "docker mode: images.env pins, workspace and lib mounts, outputs copied back" {
    run "$LIB/run.sh" docker --image debian -- echo hi
    assert_status 0
    has_args --volume "$TMP/work:$TMP/work"
    has_args --workdir "$TMP/work"
    has_args --volume "$LIB:$LIB:ro"
    has_args --volume "$ROOT/version.txt:$ROOT/version.txt:ro"
    image="$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")"
    has_args "$image" sh
    has_args sh "$LIB/in-container.sh"
    has_args "$LIB/in-container.sh" echo
    args | grep -qx -- --rm
    grep -qx from=container "$GITHUB_OUTPUT"
}

@test "docker mode: the io directory and files are private (700, 600)" {
    run "$LIB/run.sh" docker --image debian -- true
    assert_status 0
    [ "$(cat "$TMP/io.modes")" = "$(printf '700\n600\n600')" ]
}

@test "docker mode --read-only mounts the checkout read-only, and refuses --writes" {
    run "$LIB/run.sh" docker --image debian --read-only -- true
    assert_status 0
    has_args --volume "$TMP/work:$TMP/work:ro"
    run "$LIB/run.sh" docker --image debian --read-only --writes site -- true
    assert_status 1
}

@test "docker mode refuses a working directory with ':' in its path" {
    mkdir "$TMP/a:b"
    cd "$TMP/a:b"
    run "$LIB/run.sh" docker --image debian -- true
    assert_status 1
    assert_output_contains "contains ':'"
    [ ! -e "$TMP/docker.args" ]
}

@test "host mode --gnupg: an interrupted step stops gpg-agent too" {
    need gpg gpgconf gpg-connect-agent
    run "$LIB/run.sh" host --gnupg -- sh -c 'gpg-connect-agent "getinfo pid" /bye | sed -n "s/^D //p" > "$1"; kill -TERM "$PPID"' sh "$TMP/agent.pid"
    assert_status 143
    pid="$(cat "$TMP/agent.pid")"
    [ -n "$pid" ]
    for _ in $(seq 20); do
        kill -0 "$pid" 2> /dev/null || break
        sleep 0.1
    done
    refute kill -0 "$pid"
}

@test "docker mode resolves ubuntu and fedora too" {
    for d in ubuntu fedora; do
        run "$LIB/run.sh" docker --image "$d" -- true
        assert_status 0
        key="$(echo "$d" | tr a-z A-Z)_IMAGE"
        args | grep -qxF "$(sed -n "s/^$key=//p" "$ROOT/images.env")"
    done
}

@test "docker mode accepts a digest-pinned image and refuses anything else" {
    ref="registry.example/team/img:1.0@sha256:$(printf '%064d' 0)"
    run "$LIB/run.sh" docker --image "$ref" -- true
    assert_status 0
    args | grep -qxF "$ref"
    for bad in debian:trixie "img@sha256:abc" "img:1@sha256:$(printf '%064d' 0) --privileged" ''; do
        run "$LIB/run.sh" docker --image "$bad" -- true
        assert_status 1
    done
}

@test "docker mode passes secrets by name only, never their value" {
    export REPO_SIGNING_KEY='-----BEGIN PGP PRIVATE KEY BLOCK----- secret'
    run "$LIB/run.sh" docker --image debian --env REPO_SIGNING_KEY --gnupg -- true
    assert_status 0
    has_args --env REPO_SIGNING_KEY
    refute grep -q 'PRIVATE KEY' "$TMP/docker.args"
    grep -q '^REPO_SIGNING_KEY=-----BEGIN' "$TMP/docker.env"
}

@test "docker mode --gnupg: GNUPGHOME on a tmpfs" {
    run "$LIB/run.sh" docker --image debian --gnupg -- true
    assert_status 0
    has_args --tmpfs /pkg-pages-gnupg:rw,mode=0700
    has_args --env GNUPGHOME=/pkg-pages-gnupg
}

@test "docker mode without --gnupg has no GNUPGHOME" {
    run "$LIB/run.sh" docker --image debian -- true
    refute grep -q GNUPGHOME "$TMP/docker.args"
}

@test "docker: written paths are chowned back to the caller; podman: not, and no SELinux labels" {
    run "$LIB/run.sh" docker --image debian --writes site --writes dist/a.rpm -- true
    assert_status 0
    has_args --env "PKG_PAGES_OWNER=$(id -u):$(id -g)"
    # PKG_PAGES_WRITES is one multi-line argument; the log holds one line per line.
    has_args --env PKG_PAGES_WRITES=
    grep -qx site "$TMP/docker.args"
    grep -qx dist/a.rpm "$TMP/docker.args"
    DOCKER=podman run "$LIB/run.sh" docker --image debian --writes site -- true
    assert_status 0
    has_args --env PKG_PAGES_OWNER=
    has_args --security-opt label=disable
}

@test "docker mode forwards GITHUB_ACTIONS so errors become annotations" {
    GITHUB_ACTIONS=true run "$LIB/run.sh" docker --image debian -- true
    has_args --env GITHUB_ACTIONS
}

@test "docker mode passes the container's exit status" {
    FAKE_STATUS=7 run "$LIB/run.sh" docker --image debian -- true
    assert_status 7
}

@test "argument validation" {
    run "$LIB/run.sh" vm -- true;                          assert_status 1
    run "$LIB/run.sh" host;                                assert_status 1
    run "$LIB/run.sh" host --env 'A=B' -- true;            assert_status 1
    run "$LIB/run.sh" host --writes /etc -- true;          assert_status 1
    run "$LIB/run.sh" host --writes ../x -- true;          assert_status 1
    run "$LIB/run.sh" docker -- true;                      assert_status 1
    DOCKER=no-such-engine run "$LIB/run.sh" docker --image debian -- true
    assert_status 1
    assert_output_contains "runner-mode: host"
}

@test "in-container.sh: the package manager never sees the signing key; the command does" {
    mkdir -p "$TMP/fakebin"
    ln -s "$(command -v dirname)" "$TMP/fakebin/dirname"
    ln -s "$(command -v env)" "$TMP/fakebin/env"
    printf '#!/bin/sh\nenv >> "%s/apt.env"\n' "$TMP" > "$TMP/fakebin/apt-get"
    chmod +x "$TMP/fakebin/apt-get"
    run env PATH="$TMP/fakebin" REPO_SIGNING_KEY=k1 PKG_PAGES_TOOLS=gpg /bin/sh "$LIB/in-container.sh" env
    assert_status 0
    assert_output_contains "REPO_SIGNING_KEY=k1"
    grep -q '^DEBIAN_FRONTEND=noninteractive' "$TMP/apt.env"
    refute grep -q REPO_SIGNING_KEY "$TMP/apt.env"
    run env PATH="$TMP/fakebin" PKG_PAGES_TOOLS= /bin/sh "$LIB/in-container.sh" env
    assert_status 0
    refute grep -q '^REPO_SIGNING_KEY=' <<< "$output"
}

@test "in-container.sh installs only missing tools, runs the command, chowns written paths" {
    need_system
    # In a real container: as root, with a package manager.
    mkdir -p out
    PKG_PAGES_TOOLS="sh gpg" PKG_PAGES_OWNER=12345:12345 PKG_PAGES_WRITES="
out" run "$LIB/in-container.sh" sh -c 'touch out/f; exit 5'
    assert_status 5
    [ "$(stat -c %u out/f)" = 12345 ]
}

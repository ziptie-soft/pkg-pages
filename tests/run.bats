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
    # The fake engine logs each call in docker.calls. `image inspect` finds no tools image unless
    # FAKE_CACHED is set; `commit` exits FAKE_COMMIT. Phase 1 (--install-only) records its
    # arguments in install.args and exits FAKE_INSTALL (default 0: tools installed). The command's
    # run records one argument per line in docker.args, its environment in docker.env, and writes
    # a step output through the mounted io directory, as a real container would.
    cat > "$TMP/bin/docker" << 'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG/docker.calls"
case "$1" in
    image) [ -n "${FAKE_CACHED:-}" ]; exit ;;
    commit) exit "${FAKE_COMMIT:-0}" ;;
    rm) exit 0 ;;
esac
for a in "$@"; do
    [ "$a" = --install-only ] || continue
    printf '%s\n' "$@" > "$FAKE_LOG/install.args"
    [ -z "${FAKE_TERM:-}" ] || kill -TERM "$PPID"
    exit "${FAKE_INSTALL:-0}"
done
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

# has_args A B: the recorded docker arguments contain A immediately followed by B (ARGS: the
# file, default docker.args).
has_args() {
    awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit !found }' "$TMP/${ARGS:-docker.args}"
}

# tools_tag IMAGE "T...": the tag run.sh gives the tools image.
tools_tag() {
    echo "pkg-pages-tools:$(printf '%s\n%s\n' "$1" "$2" | sha256sum | cut -c1-12)"
}

# hardened: the recorded command carries the options of every run without --net.
hardened() {
    has_args --network none
    has_args --cap-drop ALL
    has_args --cap-add CHOWN
    has_args --cap-add DAC_OVERRIDE
    [ "$(grep -cx -- --cap-add "$TMP/docker.args")" = 2 ]
    has_args --security-opt no-new-privileges
    grep -qx -- --read-only "$TMP/docker.args"
    has_args --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777
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

@test "docker mode: the command runs offline, with CHOWN and DAC_OVERRIDE only, on a read-only root" {
    run "$LIB/run.sh" docker --image debian --writes site -- true
    assert_status 0
    hardened
    refute grep -qx FOWNER "$TMP/docker.args"
    # --read-only (the workspace) is a different thing: the volume gets :ro.
    run "$LIB/run.sh" docker --image debian --read-only -- true
    hardened
}

@test "docker mode --net keeps the network, the capabilities and a writable root" {
    run "$LIB/run.sh" docker --image debian --net -- true
    assert_status 0
    refute grep -qxE -- '--network|--cap-drop|--cap-add|--read-only|no-new-privileges' "$TMP/docker.args"
    refute grep -q '^/tmp:' "$TMP/docker.args"
    run "$LIB/run.sh" host --net -- true
    assert_status 0
}

@test "docker mode --tools: phase 1 installs them with lib/ only, and the command runs in the commit" {
    export REPO_SIGNING_KEY=secret
    run "$LIB/run.sh" docker --image debian --tools "rpmsign gpg gpg" --gnupg --env REPO_SIGNING_KEY \
        --writes site -- true
    assert_status 0
    image="$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")"
    tag="$(tools_tag "$image" "gpg rpmsign")"
    # Phase 1: a named container, lib/ read-only, the sorted tools; nothing else.
    sed -n 1p "$TMP/install.args" | grep -qx run
    name="$(ARGS=install.args; awk 'prev == "--name" { print } { prev = $0 }' "$TMP/install.args")"
    echo "$name" | grep -Eqx 'pkg-pages-install-[0-9a-f]{12}'
    ARGS=install.args has_args --volume "$LIB:$LIB:ro"
    ARGS=install.args has_args --env "PKG_PAGES_TOOLS=gpg rpmsign"
    ARGS=install.args has_args "$image" sh
    [ "$(tail -n 1 "$TMP/install.args")" = --install-only ]
    [ "$(grep -cx -- --env "$TMP/install.args")" = 1 ]
    [ "$(grep -cx -- --volume "$TMP/install.args")" = 1 ]
    refute grep -qE "$TMP/work|pkg-pages-io|REPO_SIGNING_KEY|GNUPGHOME|PKG_PAGES_OWNER|^--tmpfs|^--rm" "$TMP/install.args"
    # The commit, then the container's removal; the command runs in the tag, never pulled.
    grep -qx "image inspect $tag" "$TMP/docker.calls"
    grep -qx "commit $name $tag" "$TMP/docker.calls"
    grep -qx "rm -f $name" "$TMP/docker.calls"
    has_args "$tag" sh
    refute grep -qxF "$image" "$TMP/docker.args"
    args | grep -qx -- --pull=never
    has_args --env PKG_PAGES_TOOLS=
    hardened
}

@test "docker mode --tools: the tag depends on the image and the set of tools" {
    image="$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")"
    run "$LIB/run.sh" docker --image debian --tools "gpg tar" -- true
    has_args "$(tools_tag "$image" "gpg tar")" sh
    run "$LIB/run.sh" docker --image debian --tools "tar gpg tar" -- true
    has_args "$(tools_tag "$image" "gpg tar")" sh
    run "$LIB/run.sh" docker --image fedora --tools "gpg tar" -- true
    refute has_args "$(tools_tag "$image" "gpg tar")" sh
}

@test "docker mode --tools: an existing tools image skips phase 1" {
    FAKE_CACHED=1 run "$LIB/run.sh" docker --image debian --tools gpg -- true
    assert_status 0
    [ ! -e "$TMP/install.args" ]
    refute grep -qE '^(commit|rm) ' "$TMP/docker.calls"
    has_args "$(tools_tag "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" gpg)" sh
    args | grep -qx -- --pull=never
}

@test "docker mode --tools: nothing missing (exit 10) commits nothing; the command runs in the base image" {
    FAKE_INSTALL=10 run "$LIB/run.sh" docker --image debian --tools gpg -- true
    assert_status 0
    refute grep -q '^commit ' "$TMP/docker.calls"
    grep -q '^rm -f pkg-pages-install-' "$TMP/docker.calls"
    has_args "$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")" sh
    refute grep -qx -- --pull=never "$TMP/docker.args"
}

@test "docker mode --tools: a failed install or commit fails the step; the command never runs" {
    FAKE_INSTALL=100 run "$LIB/run.sh" docker --image debian --tools gpg -- true
    assert_status 1
    assert_output_contains "installing the tools (gpg) failed"
    refute grep -q '^commit ' "$TMP/docker.calls"
    grep -q '^rm -f pkg-pages-install-' "$TMP/docker.calls"
    [ ! -e "$TMP/docker.args" ]
    : > "$TMP/docker.calls"
    FAKE_COMMIT=1 run "$LIB/run.sh" docker --image debian --tools gpg -- true
    assert_status 1
    assert_output_contains "commit"
    grep -q '^rm -f pkg-pages-install-' "$TMP/docker.calls"
    [ ! -e "$TMP/docker.args" ]
}

@test "docker mode --tools: a TERM during phase 1 removes the install container and commits nothing" {
    FAKE_TERM=1 run "$LIB/run.sh" docker --image debian --tools gpg -- true
    assert_status 143
    name="$(awk 'prev == "--name" { print } { prev = $0 }' "$TMP/install.args")"
    [ -n "$name" ]
    grep -qx "rm -f $name" "$TMP/docker.calls"
    refute grep -q '^commit ' "$TMP/docker.calls"
    [ ! -e "$TMP/docker.args" ]
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
    # A stopped agent can stay a zombie: it was reparented to PID 1, which in a CI `container:` job
    # is `tail -f /dev/null` and never reaps it. A zombie holds no memory, so it counts as stopped.
    running() { [ -e "/proc/$1" ] && ! grep -q '^[0-9]* ([^)]*) Z' "/proc/$1/stat" 2> /dev/null; }
    for _ in $(seq 20); do
        running "$pid" || break
        sleep 0.1
    done
    refute running "$pid"
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
    DOCKER=podman run "$LIB/run.sh" docker --image debian --writes site --tools gpg -- true
    assert_status 0
    has_args --env PKG_PAGES_OWNER=
    has_args --security-opt label=disable
    ARGS=install.args has_args --security-opt label=disable
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

@test "in-container.sh --install-only: exit 10 when nothing is missing, else install and clean the caches" {
    mkdir -p "$TMP/fakebin"
    ln -s "$(command -v dirname)" "$TMP/fakebin/dirname"
    for t in apt-get rm; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/pm.log"\n' "$t" "$TMP" > "$TMP/fakebin/$t"
        chmod +x "$TMP/fakebin/$t"
    done
    run env PATH="$TMP/fakebin" PKG_PAGES_TOOLS=dirname /bin/sh "$LIB/in-container.sh" --install-only
    assert_status 10
    [ ! -e "$TMP/pm.log" ]
    run env PATH="$TMP/fakebin" PKG_PAGES_TOOLS="dirname gpg" /bin/sh "$LIB/in-container.sh" --install-only
    assert_status 0
    grep -q '^apt-get install .* gnupg$' "$TMP/pm.log"
    grep -qx 'apt-get clean' "$TMP/pm.log"
    grep -q '^rm -rf /var/lib/apt/lists/' "$TMP/pm.log"
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

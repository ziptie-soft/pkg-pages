#!/usr/bin/env bats
# The repository tooling in dev/: the pin gate and the self-reference check. Runs anywhere.

load helpers

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

pins() { run "$ROOT/dev/check-action-pins.sh" "$@"; }

# wf TEXT: write a workflow file with TEXT under a job's steps, print its path.
wf() {
    printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n%s\n' "$1" > "$TMP/w.yml"
    echo "$TMP/w.yml"
}

# --- check-action-pins.sh --------------------------------------------------------------------

@test "pins: the repository passes" {
    cd "$ROOT"
    pins .github/workflows/*.yml action.yml */action.yml
    assert_status 0
}

@test "pins: SHA refs, sub-path actions, reusable workflows, local paths and docker digests pass" {
    pins "$(wf "      - uses: actions/checkout@$SHA # v7
      - uses: github/codeql-action/init@$SHA
      - uses: 'owner/repo/.github/workflows/x.yml@$SHA'
      - uses: ./local
      - uses: ./
      - uses: docker://alpine@sha256:$(printf '%064d' 0)")"
    assert_status 0
}

@test "pins: tags, branches, short SHAs and unpinned docker refs fail" {
    for ref in actions/checkout@v7 actions/checkout@main "actions/checkout@${SHA%????}" \
        docker://alpine:3 "docker://alpine@sha256:abc" actions/checkout; do
        pins "$(wf "      - uses: $ref")"
        assert_status 1
    done
}

@test "pins: --warn reports unpinned refs but passes" {
    pins --warn "$(wf '      - uses: actions/checkout@v7')"
    assert_status 0
    assert_output_contains "::warning"
}

@test "pins: YAML that could hide a uses is a structure error, even with --warn" {
    for body in '      - &a { uses: actions/checkout@v7 }' \
        '      - run: |
          uses: actions/checkout@v7' \
        '      - { uses: actions/checkout@v7 }' \
        '      - uses: [actions/checkout@v7]' \
        '      - uses:' \
        '      - <<: *x'; do
        pins --warn "$(wf "$body")"
        assert_status 1
    done
}

@test "pins: a second YAML document is refused" {
    printf 'on: push\n---\njobs: {}\n' > "$TMP/w.yml"
    pins "$TMP/w.yml"
    assert_status 1
}

@test "pins: container images need a digest listed in images.env" {
    img="$(sed -n 's/^DEBIAN_IMAGE=//p' "$ROOT/images.env")"
    printf 'jobs:\n  a:\n    container: %s\n' "$img" > "$TMP/w.yml"
    pins "$TMP/w.yml"
    assert_status 0
    printf 'jobs:\n  a:\n    container: debian:trixie\n' > "$TMP/w.yml"
    pins "$TMP/w.yml"
    assert_status 1
    printf 'jobs:\n  a:\n    container: debian:trixie@sha256:%064d\n' 0 > "$TMP/w.yml"
    pins "$TMP/w.yml"
    assert_status 1
    assert_output_contains "not in images.env"
}

@test "pins: no files, or a missing file, is an error" {
    pins
    assert_status 2
    pins "$TMP/missing.yml"
    assert_status 1
}

@test "pins: commented-out uses lines and trailing comments are ignored" {
    pins "$(wf "      # - uses: actions/checkout@v7
      - uses: actions/checkout@$SHA # uses: x@main")"
    assert_status 0
}

@test "pins: the word uses anywhere but a plain key is refused (a line scanner fails closed)" {
    pins "$(wf "      - run: echo 'uses: actions/checkout@v7'")"
    assert_status 1
    assert_output_contains "plain"
}

# --- check-self-refs.sh ----------------------------------------------------------------------

@test "self-refs: the repository passes" {
    run "$ROOT/dev/check-self-refs.sh"
    assert_status 0
}

@test "self-refs: a local uses in shipped code fails, quoted or not" {
    for u in './sign-rpm' '"./sign-rpm"' "'./sign-rpm'"; do
        printf 'runs:\n  using: composite\n  steps:\n    - uses: %s\n' "$u" > "$TMP/action.yml"
        run "$ROOT/dev/check-self-refs.sh" "$TMP/action.yml"
        assert_status 1
    done
}

@test "self-refs: pinned self references pass" {
    printf 'runs:\n  using: composite\n  steps:\n    - uses: ziptie-soft/pkg-pages/sign-rpm@%s\n' "$SHA" > "$TMP/action.yml"
    run "$ROOT/dev/check-self-refs.sh" "$TMP/action.yml"
    assert_status 0
}

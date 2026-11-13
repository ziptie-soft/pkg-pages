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

# --- self-pin.sh -----------------------------------------------------------------------------

# selfpin_repo: a throwaway repository with an action, lib/ and a publish.yml pinned to its
# first commit W ($W); the script runs from its own copy there.
selfpin_repo() {
    need git
    R="$TMP/repo"
    mkdir -p "$R/dev" "$R/lib" "$R/sign-rpm" "$R/.github/workflows"
    cp "$ROOT/dev/self-pin.sh" "$R/dev/"
    cd "$R" || return 1
    git init -q
    git config user.email t@example.invalid
    git config user.name t
    echo 'runs: { using: composite, steps: [] }' > action.yml
    echo 'runs: { using: composite, steps: [] }' > sign-rpm/action.yml
    echo 'echo hi' > lib/x.sh
    echo 'X=1' > images.env
    echo 1.0.0 > version.txt
    printf 'jobs:\n  a:\n    steps:\n      - uses: ziptie-soft/pkg-pages/sign-rpm@%s # v0.0.0 pkg-pages self-pin\n      - uses: ziptie-soft/pkg-pages@%s # v0.0.0 pkg-pages self-pin\n        with:\n          footer-version: 0.0.0 # pkg-pages self-pin\n' \
        "$(printf '%040d' 0)" "$(printf '%040d' 0)" > .github/workflows/publish.yml
    git add -A
    git commit -qm 'feat: w'
    W="$(git rev-parse HEAD)"
}

@test "self-pin: rewrites every marked self reference" {
    selfpin_repo
    run dev/self-pin.sh "$W" 1.2.3
    assert_status 0
    [ "$(grep -c "@$W # v1.2.3 pkg-pages self-pin\$" .github/workflows/publish.yml)" -eq 2 ]
    grep -qx '          footer-version: 1.2.3 # pkg-pages self-pin' .github/workflows/publish.yml
}

@test "self-pin: refuses a short SHA, a bad version and an unmarked self reference" {
    selfpin_repo
    run dev/self-pin.sh abc123 1.2.3;  assert_status 1
    run dev/self-pin.sh "$W" v1.2;     assert_status 1
    echo "      - uses: ziptie-soft/pkg-pages/check-rpm@$W" >> .github/workflows/publish.yml
    run dev/self-pin.sh "$W" 1.2.3
    assert_status 1
    assert_output_contains "lack the"
}

@test "self-pin --check: passes when only publish.yml and docs changed since W" {
    selfpin_repo
    dev/self-pin.sh "$W" 1.0.0 > /dev/null
    echo docs > README.md
    git add -A
    git commit -qm 'chore(release): pin'
    run dev/self-pin.sh --check
    assert_status 0
    assert_output_contains "uses $W"
}

@test "self-pin --check: fails when lib/, an action or images.env changed since W" {
    for f in lib/x.sh sign-rpm/action.yml images.env; do
        rm -rf "$TMP/repo"
        selfpin_repo
        dev/self-pin.sh "$W" 1.0.0 > /dev/null
        echo changed >> "$f"
        git add -A
        git commit -qm 'fix: change'
        run dev/self-pin.sh --check
        assert_status 1
        assert_output_contains "the actions changed"
    done
}

@test "self-pin --check: fails unless the pins, footer-version and version.txt name one version" {
    # The release commit bumps version.txt; W's actions still hold the previous one.
    selfpin_repo
    dev/self-pin.sh "$W" 1.0.0 > /dev/null
    echo 1.0.1 > version.txt
    git add -A
    git commit -qm 'chore(release): 1.0.1'
    run dev/self-pin.sh --check
    assert_status 1
    assert_output_contains "several versions"
    dev/self-pin.sh "$W" 1.0.1 > /dev/null
    git commit -qam 'chore(release): pin'
    run dev/self-pin.sh --check
    assert_status 0
    sed -i '/footer-version/d' .github/workflows/publish.yml
    git commit -qam 'chore: no footer-version'
    run dev/self-pin.sh --check
    assert_status 1
    assert_output_contains "no 'footer-version"
}

@test "self-pin --check: fails on a new action added after W" {
    selfpin_repo
    dev/self-pin.sh "$W" 1.0.0 > /dev/null
    mkdir new-action
    echo 'runs: { using: composite, steps: [] }' > new-action/action.yml
    git add -A
    git commit -qm 'feat: new'
    run dev/self-pin.sh --check
    assert_status 1
}

@test "self-pin --check: fails on stale, mixed or unknown pins" {
    selfpin_repo
    git add -A
    run dev/self-pin.sh --check
    assert_status 1
    assert_output_contains "not in this repository"
    dev/self-pin.sh "$W" 1.0.0 > /dev/null
    sed -i "0,/@$W/s//@$(printf '%040d' 1)/" .github/workflows/publish.yml
    git add -A
    git commit -qm 'chore: mixed'
    run dev/self-pin.sh --check
    assert_status 1
    assert_output_contains "several commits"
}

@test "self-pin -C: the script from one checkout works on another (release.yml's trusted copy)" {
    selfpin_repo
    rm dev/self-pin.sh
    git commit -qam 'chore: no script on this branch'
    cd /
    run "$ROOT/dev/self-pin.sh" -C "$R" "$W" 1.0.0
    assert_status 0
    grep -q "@$W # v1.0.0 pkg-pages self-pin" "$R/.github/workflows/publish.yml"
    git -C "$R" commit -qam 'chore(release): pin'
    # dev/ is not shipped, so removing the script doesn't change what callers run.
    run "$ROOT/dev/self-pin.sh" -C "$R" --check HEAD
    assert_status 0
    run "$ROOT/dev/self-pin.sh" -C "$TMP/none" --check
    assert_status 1
}

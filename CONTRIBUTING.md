# Contributing

## Setup

```sh
mise trust
mise install
```

[mise](https://mise.jdx.dev) installs the pinned linters and bats (`mise.toml`). The actions
themselves need none of it. For the container tests you also need podman or docker.

## Commands

| Command | Runs |
|---|---|
| `mise run check` | everything CI's static job runs: jactionlint, the pin gate, the self-ref check, zizmor, shellcheck, rumdl, bats |
| `mise run test` | the bats tests that this machine can run; the rest skip with a reason |
| `mise run test:containers` | the whole bats suite as root in the Debian, Ubuntu and Fedora images |
| `tests/container.sh fedora tests/signing.bats` | one test file in one image |
| `mise run fmt` | format the Markdown |

Run `mise run check` and `mise run test:containers` before you open a pull request.

## Layout

```text
action.yml               build-repo, the root action (the only one the Marketplace lists)
sign-rpm/ check-rpm/     composite actions; each action.yml only maps inputs to env and
fetch-history/             calls lib/action.sh
install-test/
package-rust/
.github/workflows/
  publish.yml            the reusable workflow
  ci.yml                 lint, the bats suite in containers, every action end to end
  selftest.yml           publish.yml called as callers call it
  release.yml            release-please and the self-pin (docs/releasing.md)
lib/                     the POSIX sh scripts the actions run (lib/README.md)
tools/ci-key             a maintainer CLI, never run in CI
dev/                     repository tooling: pin gates, self-pin.sh and nix-lock.sh
tests/                   bats tests and their fixtures (tests/README.md)
images.env               the container images, pinned by digest
docs/                    design, contracts, signing, building, releasing
```

How a run flows: `action.yml` → `lib/action.sh <action>` (validates the inputs) → `lib/run.sh`
(runs on the runner, or in an `images.env` container) → the script that does the work
(`pages-repo.sh`, `linux-signing.sh`, ...). Each script starts with a comment that says what it
does, how to call it and what it outputs.

## Rules

These keep the actions safe for every caller. CI enforces most of them.

- **No `uses: ./…` in shipped code.** In a composite action or a called workflow it resolves in
  the caller's checkout. Reach files through `$GITHUB_ACTION_PATH`, and sibling actions as
  `ziptie-soft/pkg-pages/<action>@<sha> # vX.Y.Z pkg-pages self-pin`. Don't edit those pins by
  hand: `release.yml` moves them at each release ([docs/releasing.md](docs/releasing.md#the-self-pin)).
  A change to an action reaches `publish.yml` only with the next release.
- **Inputs are untrusted.** Never put `${{ inputs.* }}` in a `run:` block: pass inputs through
  `env:` as `INPUT_<NAME>`, and validate them in `lib/action.sh` or the script (paths relative and
  without `..`, URLs `https://` or `file:///`, names `[a-z0-9][a-z0-9.+-]*`).
- **The signing key** lives only in a fresh `GNUPGHOME` that goes away with the step (a tmpfs in
  docker mode). It reaches a container by variable name, never as an argument or a file in the
  workspace, and it is never printed. No job that holds it builds anything or holds the Pages
  token.
- **Fail closed.** No pin and no key is the only unsigned case. Every other mismatch is an error
  ([docs/signing.md](docs/signing.md#fail-closed-matrix)).
- **Pins.** Every `uses:` is pinned to a full commit SHA with a `# vX.Y.Z` comment, every image by
  digest in `images.env`. Every job sets minimal `permissions` and `timeout-minutes`.
- **Shell.** `lib/` scripts are POSIX sh, because they run in dash (Debian, Ubuntu) and bash
  (Fedora). Functions in sourced files use `_`-prefixed variables, so they don't clobber the
  caller's.
- **Tests never use real keys.** `tests/fixtures.sh` generates a throwaway key per test file.
- **Commands in docs** must work in fish as well as bash: no `$(…)`, no heredocs, no `export`,
  `gpg --homedir DIR` instead of `GNUPGHOME=`, placeholders like `<FPR>`.

## Commits and pull requests

Pull requests are rebased onto `master`, never squashed, so every commit lands as it is and
release-please builds the version and the changelog from each one. Every commit subject must
therefore be a [Conventional Commit](https://www.conventionalcommits.org):
`<type>(<scope>)!?: <description>`. Keep commits meaningful (fold "fix typo" commits into the
commit they fix with `git rebase -i`), and rebase instead of merging `master` in: the `Commits`
check fails on merge commits and on any non-conventional subject. The PR title is free text.

Callers pin versions, so a change to an input's name, default or behaviour is breaking (`feat!:`
or `fix!:`).

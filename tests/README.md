# tests

[bats](https://bats-core.readthedocs.io) tests for `lib/`, `dev/`, `tools/` and the
`action.yml` files.

| File | Covers |
|---|---|
| `common.bats` | input checks, HTML escaping, temp directories, version matching, pool paths |
| `signing.bats` | every row of the fail-closed matrix, rotation, revocation, expiry, signing and checking `.rpm` files |
| `pages-repo.bats` | the site layout, metadata handling, signing, the landing page, `extra-site`, installing from the site with apt and dnf, tampering |
| `nix-flake.bats` | archive validation, lock sanity, SHA-256 pins, and deterministic flake tarballs |
| `fetch-history.bats` | release selection and downloads, against a fake `gh` |
| `install-test.bats` | installs and smoke commands, signature checks before an `.rpm` install |
| `package-rust.bats` | building the fixture crate with cargo-deb and cargo-generate-rpm |
| `run.bats` | host and docker modes, against a fake engine: mounts, the tmpfs `GNUPGHOME`, secrets passed by name |
| `action.bats` | `lib/action.sh` defaults and validation; every input of every `action.yml` reaching its script |
| `ci-key.bats` | `tools/ci-key` |
| `dev.bats` | the pin gate and the self-ref check |

Nothing secret or binary is committed. `fixtures.sh` generates the keys and packages at run time,
and `fixtures/hello-rust` is a tiny crate.

Each test checks for the tools it needs and skips without them, so `mise run test` passes
anywhere. Tests that install packages also need root and `PKG_PAGES_TEST_SYSTEM=1`.
`container.sh` runs the whole suite that way in a throwaway container
(`mise run test:containers`), and so does CI's `container-tests` job.

Write `refute CMD` rather than `! CMD`. Under bats a negated command never fails a test.

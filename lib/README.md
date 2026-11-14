# lib

The POSIX sh scripts the actions run. The `action.yml` files reach them as
`$GITHUB_ACTION_PATH/../lib/…` (`$GITHUB_ACTION_PATH/lib/…` from the root action). They also run
unchanged on a developer's machine and in the `images.env` containers, which is how
`tests/` tests them. Each file starts with a comment covering its usage, inputs and outputs.

| Script | Does |
|---|---|
| `action.sh` | The run step of every action: reads `INPUT_*`, validates, fills in defaults, calls `run.sh` |
| `run.sh` | Runs a command on the runner (`host`) or in a pinned container (`docker`), with an optional private `GNUPGHOME` |
| `in-container.sh` | Entry point of those containers: installs the tools, runs the command, hands written files back to the runner user |
| `pages-repo.sh` | Builds the APT and DNF site from a directory of packages, signs it, and checks the result |
| `site-check.sh` | Checks a built site as a client sees it: the layout, every signature against the pin, and the manifest |
| `nix-flake.sh` | Builds an optional deterministic flake tarball for prebuilt archives, pinned by SHA-256 |
| `linux-signing.sh` | `import`, `sign-rpm` and `check-rpm` against the committed public key |
| `build-keyring.sh` | Builds the `<name>-keyring` `.deb` that carries the pin, with a version taken from the pin's newest signature |
| `fetch-history.sh` | Downloads earlier releases' packages with `gh` |
| `install-test.sh` | Installs packages in a clean distribution container and runs a smoke command |
| `package-rust.sh` | Builds a crate's `.deb` and `.rpm` with cargo-deb and cargo-generate-rpm |

Sourced by the scripts above, never run:

| File | Holds |
|---|---|
| `common.sh` | `die`, `notice`, step outputs, input checks, `html_escape`, `make_tmpdir` (cleaned up on exit) |
| `packages.sh` | `pkg_meta` (name, version and architecture from the package itself), version matching, the pool path |
| `signing.sh` | the fail-closed import, `sign_rpm`, `check_rpm` |

```text
action.yml ─► action.sh ─► run.sh ─┬─ host:   COMMAND
                                   └─ docker: docker run IMAGE in-container.sh COMMAND
COMMAND: pages-repo.sh | linux-signing.sh | install-test.sh
         (fetch-history.sh and package-rust.sh always run on the runner)
```

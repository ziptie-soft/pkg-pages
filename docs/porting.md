# Porting

Where pkg-pages' code comes from, what changed on the way, and how the existing projects move
onto it.

## Sources

Three projects run copies of the same pipeline. These are the commits that were ported; diff
against the current default branch before porting anything else, because the copies keep
changing.

| Project | Read at | Scripts | Release workflow jobs |
|---|---|---|---|
| [SkeLLLa/star-forge](https://github.com/SkeLLLa/star-forge) | `bee5c4a` | `packaging/ci/linux-signing.sh`, `pages-repo.sh`, `images.env`, `scripts/check-action-pins.sh` | `linux-assets`, `sign-linux`, `verify-linux`, `repo`, `pages` |
| [SkeLLLa/plasma-drop](https://github.com/SkeLLLa/plasma-drop) | `7b8f1bd` | `.ci/linux-signing.sh`, `pages-repo.sh`, `images.env`, `check-action-pins.sh` | `linux-assets`, `sign-linux`, `verify-linux`, `repo`, `verify-published`, `pages` |
| [SkeLLLa/cainary](https://github.com/SkeLLLa/cainary) | `1dd018c` | `packaging/ci/linux-signing.sh`, `pages-repo.sh`, `images.env` | `build-linux*`, `sign-linux`, `verify-linux`, `repo`, `pages` |

cainary was the first to sign (release run 40228270032), so its signing code is the reference.
star-forge's `pages-repo.sh` was the most complete builder.

## What became what

| Source | Now | What changed |
|---|---|---|
| `linux-signing.sh import`, `sign-rpm`, `check-rpm` | `lib/signing.sh`, `lib/linux-signing.sh` | The pin is a parameter (`--pin`, `PKG_PAGES_PIN`). It also refuses a pin with secret material, the primary's secret in CI and an expired or revoked subkey (each subkey gets its own probe signature). `sign-rpm` leaves files that verify untouched and replaces foreign signatures. Outputs go to `GITHUB_OUTPUT` and `PKG_PAGES_SIGNED`, which was `LINUX_SIGNED`. |
| `linux-signing.sh ci-key` | `tools/ci-key` | `--homedir`, and the subkey is checked before the passphrase prompt |
| `pages-repo.sh` | `lib/pages-repo.sh` | Rewritten; see below |
| `repo` job, "Fetch earlier releases' packages" | `lib/fetch-history.sh` | `keep`, `patterns`, `include-prereleases` and `repository` are inputs. A failed download is an error. |
| `repo` job, "Verify the repositories" | the self-check at the end of `pages-repo.sh` | Generic paths; signatures are verified against the pin with `gpgv` |
| `verify-linux` job | `install-test/`, `check-rpm/` | The smoke test is the caller's `smoke` |
| `linux-assets` job (cargo-deb, cargo-generate-rpm) | `package-rust/` | Version check from package metadata |
| `sign-linux`, `verify-linux`, `repo`, `pages` jobs | `publish.yml` | Packages picked out of the artifacts; artifacts passed by ID |
| plasma-drop `newer-release` check | `publish.yml` `skip-if-newer` | `sort -V` on the published tags |
| `check-action-pins.sh`, `images.env` | `dev/check-action-pins.sh`, `images.env` | Plus the check that every image is listed in `images.env` |

The `pages-repo.sh` rewrite reads each package's metadata instead of matching
`<name>_<ver>_<arch>.deb`, so cargo-deb's `-1` revision, nfpm file names, several packages per
repository, and `all`/`noarch` packages all work. Everything that was hard-coded is now an
input: the package name, the `-1` release, `amd64 arm64`/`x86_64 aarch64`, the pool letter (wrong
in some copies), Origin/Label/Description, the suite, the component, the landing page text and
the base URL.

Where the copies disagreed, pkg-pages took: directory listings (star-forge, plasma-drop), the
`Version: X(-N)?` match (cainary wanted an exact `X`), checking out the released tag in the sign
and repo jobs, 7-day artifacts, skip-if-newer, passing the site by artifact ID, and an optional
deploy-after-verify (all from plasma-drop).

## Migrating the existing projects

Each migration is one PR in that project. Users' `.list` and `.repo` files keep working: the
URLs, `stable main`, `<name>.asc`, `deb/<name>.list`, `rpm/<name>.repo` and the pool paths
(`pool/main/p/plasma-drop`, `pool/main/s/star-forge`) stay the same. Afterwards, delete the
project's copies of `linux-signing.sh` and `pages-repo.sh` (and the pin gate, if it adopts
`dev/check-action-pins.sh`), and keep its `repo.asc`.

### plasma-drop: the composite actions

Its order is checksums → publish → verify-published → pages (with the provenance badge), so the
site has to be built before the release goes public and deployed after. That needs its own job
layout:

- `sign-linux`: drop `container: fedora` and the install step. Run `sign-rpm` with
  `packages: dist/*/*.rpm` and `signing-key: ${{ secrets.REPO_SIGNING_KEY }}`, and condition the
  two re-uploads on `steps.<id>.outputs.signed == 'true'` (was `env.LINUX_SIGNED`).
- `verify-linux`: drop `container: ${{ matrix.image }}`. One `install-test` step per matrix row,
  with `distro` (`fedora`, `debian`, `ubuntu`) and `smoke: plasma-drop --version && plasma-drop
  print-example-config > /dev/null && test -f /usr/lib/systemd/user/plasma-drop.service`. The
  signature check is part of `install-test`.
- `repo`: drop the container, the install step and the two scripts. Use `fetch-history` with
  `dir: assets` and `exclude-tag: ${{ needs.release.outputs.tag_name }}`, then `build-repo` with
  `packages: assets`, `version`, `deb-architectures: amd64 arm64`, `rpm-architectures: x86_64
  aarch64`, `base-url: ${{ vars.PAGES_BASE_URL }}`, `description`, `artifact-name: pages-site`
  and `retention-days: 30`. `site-id` is `steps.<id>.outputs.artifact-id`.
- `pages`: unchanged.

### star-forge: `publish.yml`

One call replaces `sign-linux`, `verify-linux`, `repo` and `pages`. Pass `ref:` the released
tag, `deb-artifacts: release-linux-deb-*`, `rpm-artifacts: release-linux-rpm-*`, both
architecture lists, `install-tests` with its five rows (aarch64 included), and its smoke test:
`test -f /usr/lib/systemd/user/star-forge.service && STAR_FORGE_CONFIG=/dev/null
XDG_RUNTIME_DIR=/tmp stfg smoke; stfgd stop || true`.

`checksums` and `publish-assets` then need the call and download `signed-rpm-artifact-id`
instead of `release-linux-rpm-*`. To keep "release assets first, repositories second", call it
with `deploy: false` and keep a short `pages` job after `publish-assets` that deploys
`site-artifact-id`.

### cainary

Either path works. Its Linux artifacts also hold the tarballs, which `publish.yml` skips. With
the composite actions, copy only `*.deb` and `*.rpm` into the `build-repo` directory. Its
checkout is `base_sha`, so pass that as `ref:`. Its Arch Linux tarball test stays its own job.

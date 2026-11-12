# Actions and the reusable workflow

What each part does, in which order, and when it fails. Input and output names, defaults and
one-line descriptions are in each `action.yml` and in `publish.yml`, which are the source of
truth.

Conventions shared by every part:

- **Paths** are relative to the working directory, the caller's checkout. Absolute paths and `..`
  are refused. `packages` takes newline-separated paths or globs, and each line must match at
  least one file.
- **Booleans** are the strings `'true'` and `'false'`; anything else is an error.
- **`runner-mode: docker`** (the default) runs the tools with `docker run` in the image from
  `images.env` at the pinned commit. It needs Docker on the runner, which every GitHub-hosted
  Ubuntu runner has, and it installs the tools in the container on each run. The checkout is
  mounted at the same path, and files written in the container are handed back to the runner
  user. **`host`** runs the tools from `PATH` and fails early, naming any that are missing. Use
  it in a job with its own `container:` (docker mode can't mount that job's paths), or when the
  tools are already installed. `ubuntu-slim` runners have no Docker, so run docker-mode actions
  and `install-test` on `ubuntu-24.04` (or `-arm`); `fetch-history` runs anywhere.
- **Errors** are `::error::` annotations and a non-zero exit. Nothing is retried. A `::notice::`
  marks an intentionally unsigned run.
- **Signing outputs** (`signed`, `fingerprint`) are also written to `GITHUB_ENV` as
  `PKG_PAGES_SIGNED` and `PKG_PAGES_FINGERPRINT`, for later `if:` conditions in the same job.

## build-repo

`uses: ziptie-soft/pkg-pages@<sha>` (root `action.yml`; `lib/pages-repo.sh`).

Builds the site described in [design.md#published-layout](design.md#published-layout) from
`packages`, and uploads it as a Pages artifact.

1. Defaults: `name` is the repository name, lowercased, with `_` turned into `-`. `base-url` is
   `https://<owner, lowercased>.github.io/<repo>`, or `https://<owner>.github.io` for a
   `<owner>.github.io` repository. `homepage` is the repository URL.
2. Every file under `packages`, recursively, must be a `.deb` or a binary `.rpm`. Name, version
   and architecture come from `dpkg-deb -f` and `rpm -qp`; file names don't matter. The same
   package twice is fine if the bytes match and an error if they don't.
3. The release must be there. Each architecture listed in `deb-architectures` and
   `rpm-architectures` needs a package of `version` built for exactly that architecture; with
   both empty, any package of `version` will do. An `all` or `noarch` package counts only if you
   list `all` or `noarch` itself. Debian versions match `version` or `version-<revision>`,
   ignoring the epoch (cargo-deb writes `1.2.3-1`). RPM versions match `%{VERSION}`, with any
   release; `1.2.3-rc.1` also matches `1.2.3~rc.1`.
4. The key is imported, failing closed ([signing.md](signing.md#fail-closed-matrix)).
5. APT: the `.deb` files go to `pool/<component>/<p>/<package>/`, where `<p>` is the first letter,
   or `lib` plus the fourth letter for `lib*` packages. Then `apt-ftparchive packages` runs for
   each architecture, followed by `apt-ftparchive release`. When signed, `InRelease` is
   clearsigned and `Release.gpg` detach-signed.
6. DNF: there is one repository per architecture, and `noarch` packages are copied into each.
   When signed, files that already verify against the pin are left byte-identical, and the others
   (earlier releases, other keys) are re-signed. Then `createrepo_c --compatibility` runs, and
   `repomd.xml` is detach-signed.
7. The architectures published are those of the packages plus the required ones. With only
   `all`/`noarch` packages they are `amd64 arm64` and `x86_64 aarch64`.
8. It writes `<name>.asc` (the pin itself, revocations included), `deb/<name>.list`,
   `rpm/<name>.repo`, the landing page (install commands for every package of `version`, and
   every caller string HTML-escaped), `.nojekyll` and the directory listings. Then it merges
   `extra-site`, which may not overwrite a file of the site or contain symbolic links.
9. Self-check: the required files exist, each required Debian architecture's `Packages` lists
   `version`, and, when signed, `InRelease`, `Release.gpg`, every `repomd.xml.asc` and every
   `.rpm` verify against the pin.
10. With `upload: 'true'`, it runs `actions/upload-pages-artifact` and outputs `artifact-id`.

It fails when `out` exists, when the inputs are invalid, when a tool is missing in host mode, on
any signing mismatch, or when the self-check fails. On failure nothing is uploaded.

```yaml
- uses: ziptie-soft/pkg-pages@<sha> # vX.Y.Z
  with:
    packages: assets
    version: ${{ needs.release.outputs.version }}
    deb-architectures: amd64 arm64
    rpm-architectures: x86_64 aarch64
    signing-key: ${{ secrets.REPO_SIGNING_KEY }}
    description: Cached statusline badges for starship, tmux and other prompts
    retention-days: '30'
```

## sign-rpm

`uses: ziptie-soft/pkg-pages/sign-rpm@<sha>` (`lib/linux-signing.sh sign-rpm`; Fedora image).

It imports the key, failing closed against `public-key`, then signs each file in place with
`rpmsign --addsign`. A file that already verifies is left as it is, and a foreign signature is
replaced. Afterwards it checks every file as `check-rpm` does. With no pin and no key, it
changes nothing and outputs `signed=false`.

It doesn't upload anything; the caller re-uploads the signed files:

```yaml
sign-linux:
  needs: build
  runs-on: ubuntu-24.04
  environment: linux-signing
  permissions:
    contents: read
  steps:
    - uses: actions/checkout@<sha> # vX
      with: { persist-credentials: false }
    - uses: actions/download-artifact@<sha> # vX
      with: { pattern: pkg-rpm-*, path: dist }
    - id: sign
      uses: ziptie-soft/pkg-pages/sign-rpm@<sha> # vX.Y.Z
      with:
        packages: dist/*/*.rpm
        signing-key: ${{ secrets.REPO_SIGNING_KEY }}
    - if: ${{ steps.sign.outputs.signed == 'true' }}
      uses: actions/upload-artifact@<sha> # vX
      with: { name: pkg-rpm-signed, path: dist/*/*.rpm }
```

## check-rpm

`uses: ziptie-soft/pkg-pages/check-rpm@<sha>` (`lib/linux-signing.sh check-rpm`; Fedora image).

It runs `rpmkeys --import <pin>` into a temporary database, then
`rpmkeys --define '_pkgverify_level signature' --checksig` on each file. Without the signature
level, unsigned files would pass on their digests. It needs no secret. When the pin is absent,
it passes with a notice if `allow-unsigned` is `'true'` and fails otherwise.

## fetch-history

`uses: ziptie-soft/pkg-pages/fetch-history@<sha>` (`lib/fetch-history.sh`; runs on the runner).

It lists the newest non-draft releases with `gh release list` (non-prerelease unless
`include-prereleases`), skips `exclude-tag` and takes the first `keep`. Then
`gh release download --skip-existing` fetches their assets matching `patterns` into `dir`. A
release without matching assets is skipped with a notice. Any other failure is an error, because
a silently shorter history would remove versions from the site. It needs `contents: read` on
`repository`.

`build-repo` re-signs `.rpm` files from releases older than the signing key, so those then differ
from their release-page copies by the signature.

## install-test

`uses: ziptie-soft/pkg-pages/install-test@<sha>` (`lib/install-test.sh`; the distro's image).

It runs `docker run --rm` on the distribution image: `fedora`, `debian` and `ubuntu` map to
`images.env`, and any other image must be pinned by digest. The packages are copied inside the
container, because APT's `_apt` user can't read some mounts. An `.rpm` is checked against the
pin first, when the pin exists. Then it runs `dnf install -y` or `apt-get install -y` on the
files, and `smoke` with `sh -eu -c`. The smoke command reaches the container through the
environment, not the command line. The architecture is the runner's, so run an `aarch64` test
on an arm runner.

## package-rust

`uses: ziptie-soft/pkg-pages/package-rust@<sha>` (`lib/package-rust.sh`; runs on the runner).

It builds a crate's `.deb` and `.rpm` with cargo-deb and cargo-generate-rpm, and checks their
versions against the crate. See [building.md](building.md). Its output paths are relative to
`working-directory`.

## publish (reusable workflow)

`uses: ziptie-soft/pkg-pages/.github/workflows/publish.yml@<sha>`: every step above, as four jobs
([design.md#jobs-of-the-reusable-workflow](design.md#jobs-of-the-reusable-workflow)).

1. **sign** (in `signing-environment`): downloads the artifacts matching `deb-artifacts` and
   `rpm-artifacts` and keeps only their `.deb` and `.rpm` files, so build artifacts may also hold
   tarballs or checksums. It signs the `.rpm` files and uploads both sets again, as
   `<artifact-prefix>-deb` and `-rpm`.
2. **verify** (a matrix from `install-tests`): `install-test` on each distribution, with `smoke`.
   `kind` defaults to `rpm` for `fedora` and `deb` otherwise, and `arch: aarch64` runs on
   `ubuntu-24.04-arm`. Each test installs only the packages for its own architecture.
   `install-tests: '[]'` skips the job.
3. **repo** (in `signing-environment`): `fetch-history` (`keep-releases`, `history-patterns`,
   skipping `tag`), then `build-repo`, which uploads `<artifact-prefix>-site`.
4. **deploy** (in `pages-environment`), when `deploy` is true: skips a re-run of an older release
   (`skip-if-newer`, comparing `tag` with the newest published release, `sort -V`). Merges
   `extra-artifact-ids` into the site root, refusing to overwrite a site file, and deploys.

Artifacts move between the jobs by ID, so an artifact of the caller's with the same name can't
replace them. An empty `signing-environment` runs `sign` and `repo` without an environment.
Without one, `signing-key` resolves only from a repository secret, so keep the key in an
environment. `ref` picks the commit that `public-key` is read from: the released tag, say, when
the calling run's commit is not the release.

The calling job grants the maximum permissions ([C4](design.md#c4-permissions-only-go-down)). It
must grant all three, even with `deploy: false`, because GitHub checks every job's permissions
when the run starts:

```yaml
permissions:
  contents: read     # checkout, fetch-history, skip-if-newer
  pages: write       # deploy
  id-token: write    # deploy
```

It takes one secret, `signing-key`, which the caller maps from whatever its own secret is called
([C1](design.md#c1-environment-secrets-in-a-reusable-workflow)):

```yaml
secrets:
  signing-key: ${{ secrets.REPO_SIGNING_KEY }}
```

A full call:

```yaml
packages:
  needs: [release, build]
  if: ${{ needs.release.outputs.released == 'true' }}
  permissions:
    contents: read
    pages: write
    id-token: write
  uses: ziptie-soft/pkg-pages/.github/workflows/publish.yml@<sha> # vX.Y.Z
  with:
    version: ${{ needs.release.outputs.version }}
    tag: ${{ needs.release.outputs.tag_name }}
    ref: ${{ needs.release.outputs.tag_name }}
    deb-artifacts: release-linux-deb-*
    rpm-artifacts: release-linux-rpm-*
    deb-architectures: amd64 arm64
    rpm-architectures: x86_64 aarch64
    description: What these packages are, in one line
    install-tests: >-
      [{"distro":"fedora","arch":"x86_64"},{"distro":"debian","arch":"x86_64"},
       {"distro":"ubuntu","arch":"x86_64"},{"distro":"fedora","arch":"aarch64"},
       {"distro":"debian","arch":"aarch64"}]
    smoke: mytool --version
  secrets:
    signing-key: ${{ secrets.REPO_SIGNING_KEY }}
```

- Attach the `.rpm` files from `signed-rpm-artifact-id` to your GitHub release, not the build's
  unsigned copies, so the release page and the DNF repository serve the same bytes.
- `deploy: false` only builds and uploads the site (`site-artifact-id`), for a caller that
  deploys later, after its own post-publish checks say.
- Calling it twice in one run needs a different `artifact-prefix` for each call.

## Versioning

From v1.0.0 every part follows semantic versioning: renaming or removing an input or
output, changing a default, or changing the published layout is a major version
([releasing.md](releasing.md)). This covers `publish.yml` too.

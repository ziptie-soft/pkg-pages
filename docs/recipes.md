# Recipes

Copy-ready workflows for the common cases. Replace `<sha> # vX.Y.Z` with the commit SHA of a
pkg-pages release (the same one for every part), and pin the other actions the same way. The
inputs are described in [actions.md](actions.md).

Every recipe needs, once per repository:

- Settings → Pages → Source: **GitHub Actions**.
- For the signed recipes, the key set up as in [signing.md](signing.md#setting-up-a-project): the
  public key committed at `packaging/signing/repo.asc`, and the secret `REPO_SIGNING_KEY` in the
  environment `linux-signing`.

The recipes run on a pushed `v*` tag. An environment restricted to the default branch refuses
those runs, so also allow the tags (the tag rulesets of
[releasing.md](releasing.md#repository-settings) keep them from being moved):

```sh
gh api -X POST repos/<owner>/<repo>/environments/linux-signing/deployment-branch-policies -f name='v*' -f type=tag
```

## Packslip and mise

The reusable workflow can add CLI install commands to the Pages landing page when the caller
publishes a packslip bundle on its GitHub release. Set `packslip: true`; set `packslip-pin` as
well when you want the command pinned to a signer. See [jdx/packslip's GitHub Actions guide](https://packslip.dev/docs/actions/)
for producing and publishing the bundle.

```yaml
    with:
      packslip: true
```

## Building and publishing, unsigned

The starting point: build `.deb` and `.rpm` packages on two architectures, publish unsigned
repositories. Users install with `[trusted=yes]` and `gpgcheck=0`. The same workflow becomes
signed once the public key is committed and the secret set, with no change here.

```yaml
name: Release
on:
  push:
    tags: ['v*']

permissions: {}

jobs:
  meta:
    runs-on: ubuntu-slim
    timeout-minutes: 5
    permissions: {}
    outputs:
      version: ${{ steps.v.outputs.version }}
    steps:
      - id: v
        env:
          TAG: ${{ github.ref_name }}
        run: echo "version=${TAG#v}" >> "$GITHUB_OUTPUT"

  build:
    strategy:
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      # Any build that writes .deb and .rpm files; package-rust for a Rust crate.
      - id: pkg
        uses: ziptie-soft/pkg-pages/package-rust@<sha> # vX.Y.Z
      - uses: actions/upload-artifact@<sha> # vX
        with:
          name: pkg-deb-${{ steps.pkg.outputs.deb-arch }}
          path: ${{ steps.pkg.outputs.deb }}
          if-no-files-found: error
      - uses: actions/upload-artifact@<sha> # vX
        with:
          name: pkg-rpm-${{ steps.pkg.outputs.rpm-arch }}
          path: ${{ steps.pkg.outputs.rpm }}
          if-no-files-found: error

  packages:
    needs: [meta, build]
    permissions:
      contents: read
      pages: write
      id-token: write
    uses: ziptie-soft/pkg-pages/.github/workflows/publish.yml@<sha> # vX.Y.Z
    with:
      version: ${{ needs.meta.outputs.version }}
      tag: ${{ github.ref_name }}
      deb-artifacts: pkg-deb-*
      rpm-artifacts: pkg-rpm-*
      deb-architectures: amd64 arm64
      rpm-architectures: x86_64 aarch64
      description: What these packages are, in one line
      smoke: mytool --version
    secrets:
      signing-key: ${{ secrets.REPO_SIGNING_KEY }}
```

To publish unsigned for good, with no environment at all, add `signing-environment: ''` and
drop `secrets:`.

## Signed

The recipe above, once `packaging/signing/repo.asc` is committed and `REPO_SIGNING_KEY` is set in
`linux-signing`. Nothing else changes: the run is signed because the pin exists, and fails if the
secret is missing or doesn't match it ([signing.md](signing.md#fail-closed-matrix)).

To keep the secret in another environment, or the pin elsewhere:

```yaml
    with:
      # ...
      signing-environment: release-signing
      public-key: .github/signing/repo.asc
    secrets:
      signing-key: ${{ secrets.MY_RPM_KEY }}
```

## Attaching the signed packages to the release

The release page should serve the same signed `.rpm` files as the DNF repository. A job after
`packages`:

```yaml
  release-assets:
    needs: packages
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@<sha> # vX
        with:
          artifact-ids: ${{ needs.packages.outputs.signed-rpm-artifact-id }},${{ needs.packages.outputs.deb-artifact-id }}
          path: dist
          merge-multiple: true
      - env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
        run: gh release upload "$TAG" dist/*.rpm dist/*.deb --repo "$GITHUB_REPOSITORY" --clobber
```

The next release's `fetch-history` downloads them from there, so the repositories keep earlier
versions.

## .deb only (APT)

Leave out `rpm-artifacts` and `rpm-architectures`, and test on Debian and Ubuntu only. The site
then has no `rpm/` and the landing page shows only the APT commands.

```yaml
    with:
      version: ${{ needs.meta.outputs.version }}
      tag: ${{ github.ref_name }}
      deb-artifacts: pkg-deb-*
      deb-architectures: amd64 arm64
      history-patterns: '*.deb'
      install-tests: '[{"distro":"debian","arch":"x86_64"},{"distro":"ubuntu","arch":"x86_64"},{"distro":"debian","arch":"aarch64"}]'
```

`.deb` files are never signed themselves: APT checks the signed `InRelease`, which lists each
file's SHA-256. A signed `.deb`-only project still needs the pin and the secret.

With `package-rust`, pass `formats: deb` and drop the `.rpm` upload.

## .rpm only (DNF)

```yaml
    with:
      version: ${{ needs.meta.outputs.version }}
      tag: ${{ github.ref_name }}
      rpm-artifacts: pkg-rpm-*
      rpm-architectures: x86_64 aarch64
      history-patterns: '*.rpm'
      install-tests: '[{"distro":"fedora","arch":"x86_64"},{"distro":"fedora","arch":"aarch64"}]'
```

With `package-rust`, pass `formats: rpm`.

## One architecture

Build only on `ubuntu-24.04`, and say so:

```yaml
      deb-architectures: amd64
      rpm-architectures: x86_64
```

## Architecture-independent packages

Scripts, data, fonts: `Architecture: all` and `BuildArch: noarch`. Require those, and the
repositories list them for `amd64 arm64` and `x86_64 aarch64`:

```yaml
      deb-architectures: all
      rpm-architectures: noarch
```

## Install tests on more systems, or none

Each entry runs on its own runner. `kind` defaults to `rpm` for `fedora` and `deb` otherwise.
Any image works if it is pinned by digest and has `apt-get` or `dnf`:

```yaml
      install-tests: >-
        [{"distro":"fedora","arch":"x86_64"},
         {"distro":"debian","arch":"x86_64"},
         {"distro":"ubuntu","arch":"x86_64"},
         {"distro":"fedora","arch":"aarch64"},
         {"distro":"rockylinux/rockylinux:10@sha256:<64 hex>","arch":"x86_64","kind":"rpm"}]
      smoke: |
        mytool --version
        test -f /usr/lib/systemd/user/mytool.service
```

`install-tests: '[]'` skips the tests.

## Deploying later

Build the site with the release, deploy it after your own checks: `deploy: false`, then a job of
yours. It can add files, a provenance badge say, first.

```yaml
  packages:
    # ...
    with:
      # ...
      deploy: false
      retention-days: 30

  pages:
    needs: [packages, verify-published]
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    permissions:
      pages: write
      id-token: write
    steps:
      - uses: actions/download-artifact@<sha> # vX
        with:
          artifact-ids: ${{ needs.packages.outputs.site-artifact-id }}
          path: ${{ runner.temp }}/site
      - run: mkdir site && tar -xf "$RUNNER_TEMP/site/artifact.tar" -C site
      # ... add files to site/ here ...
      - uses: actions/configure-pages@<sha> # vX
      - uses: actions/upload-pages-artifact@<sha> # vX
        with:
          name: pages-${{ github.run_attempt }}
          path: site
      - id: deploy
        uses: actions/deploy-pages@<sha> # vX
        with:
          artifact_name: pages-${{ github.run_attempt }}
```

If the extra files are plain artifacts of the run, `extra-artifact-ids` does the same without a
job of your own.

## A site that also serves docs

Pages serves one site per repository, and every deploy replaces it. To keep docs next to the
repositories, upload them as an artifact in the build and pass its ID:

```yaml
      extra-artifact-ids: ${{ needs.docs.outputs.artifact-id }}
```

They are merged into the site root and may not overwrite a repository file.

## A custom domain or another base URL

```yaml
      base-url: https://packages.example.com
```

Configure the domain in Settings → Pages as usual. The URL ends up in `deb/<name>.list`,
`rpm/<name>.repo` and the landing page.

## Only this release, no history

```yaml
      keep-releases: 0
```

Users can then neither downgrade nor pin an earlier version.

## The composite actions: your own job layout

When the jobs must interleave with others (checksums or attestations of the signed files, a
release that goes public before the repositories), use the actions directly. This is the shape of
`publish.yml`; keep the key out of any job that builds, and the Pages token in its own job.

```yaml
  sign:
    needs: build
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    environment: linux-signing
    permissions:
      contents: read
    outputs:
      signed: ${{ steps.sign.outputs.signed }}
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      - uses: actions/download-artifact@<sha> # vX
        with:
          pattern: pkg-rpm-*
          path: dist
          merge-multiple: true
      - id: sign
        uses: ziptie-soft/pkg-pages/sign-rpm@<sha> # vX.Y.Z
        with:
          packages: dist/*.rpm
          signing-key: ${{ secrets.REPO_SIGNING_KEY }}
      - uses: actions/upload-artifact@<sha> # vX
        with:
          name: pkg-rpm-signed
          path: dist/*.rpm

  verify:
    needs: sign
    strategy:
      matrix:
        include:
          - { distro: fedora, kind: rpm, artifact: pkg-rpm-signed }
          - { distro: debian, kind: deb, artifact: pkg-deb-* }
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      - uses: actions/download-artifact@<sha> # vX
        with:
          pattern: ${{ matrix.artifact }}
          path: dist
          merge-multiple: true
      - uses: ziptie-soft/pkg-pages/install-test@<sha> # vX.Y.Z
        with:
          packages: dist/*.${{ matrix.kind }}
          distro: ${{ matrix.distro }}
          smoke: mytool --version

  repo:
    needs: [meta, verify]
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    environment: linux-signing
    permissions:
      contents: read
    outputs:
      site-id: ${{ steps.repo.outputs.artifact-id }}
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      - uses: actions/download-artifact@<sha> # vX
        with:
          pattern: '{pkg-deb-*,pkg-rpm-signed}'
          path: assets
          merge-multiple: true
      - uses: ziptie-soft/pkg-pages/fetch-history@<sha> # vX.Y.Z
        with:
          dir: assets
          exclude-tag: ${{ github.ref_name }}
      - id: repo
        uses: ziptie-soft/pkg-pages@<sha> # vX.Y.Z
        with:
          packages: assets
          version: ${{ needs.meta.outputs.version }}
          signing-key: ${{ secrets.REPO_SIGNING_KEY }}
          artifact-name: pages-site
          retention-days: '7'

  pages:
    needs: repo
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    permissions:
      pages: write
      id-token: write
    steps:
      - id: deploy
        uses: actions/deploy-pages@<sha> # vX
        with:
          artifact_name: pages-site
```

`assets` must hold only `.deb` and `.rpm` files: download the package artifacts only, or copy the
packages out of mixed ones. `sign-rpm` with no pin and no key passes the files through unsigned,
so this layout also works before signing starts.

## Inside a container job

Docker-mode actions can't run in a job with `container:` (they would mount the container's
paths, not the runner's). Install the tools in the container and use `runner-mode: host`:

```yaml
  repo:
    runs-on: ubuntu-24.04
    container: debian:trixie@sha256:<64 hex>
    steps:
      - run: |
          apt-get update -qq
          apt-get install -y -qq --no-install-recommends ca-certificates git gh gnupg gpgv apt-utils dpkg-dev createrepo-c rpm
      # ... checkout, download ...
      - uses: ziptie-soft/pkg-pages@<sha> # vX.Y.Z
        with:
          packages: assets
          version: ${{ needs.meta.outputs.version }}
          runner-mode: host
```

`install-test` always starts its own container, so it needs a plain runner.

## Checking a signature anywhere

`check-rpm` needs no secret: use it in CI to prove that what you are about to attach or ship is
signed by the committed key.

```yaml
      - uses: ziptie-soft/pkg-pages/check-rpm@<sha> # vX.Y.Z
        with:
          packages: dist/*.rpm
          allow-unsigned: 'false'
```

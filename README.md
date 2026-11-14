# pkg-pages

[![CI](https://github.com/ziptie-soft/pkg-pages/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/ziptie-soft/pkg-pages/actions/workflows/ci.yml)
[![Self-test](https://github.com/ziptie-soft/pkg-pages/actions/workflows/selftest.yml/badge.svg?branch=master)](https://github.com/ziptie-soft/pkg-pages/actions/workflows/selftest.yml)
[![CodeQL](https://github.com/ziptie-soft/pkg-pages/actions/workflows/codeql.yml/badge.svg?branch=master)](https://github.com/ziptie-soft/pkg-pages/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/ziptie-soft/pkg-pages/badge)](https://scorecard.dev/viewer/?uri=github.com/ziptie-soft/pkg-pages)
[![Release](https://img.shields.io/github/v/release/ziptie-soft/pkg-pages)](https://github.com/ziptie-soft/pkg-pages/releases/latest)
[![License](https://img.shields.io/github/license/ziptie-soft/pkg-pages)](LICENSE)

Publish your project's `.deb` and `.rpm` packages as **APT and DNF repositories on GitHub
Pages**, signed with OpenPGP, from GitHub Actions. No package hosting service, no server: a
release builds the packages, pkg-pages signs them and the repository metadata, and Pages serves
the result. Opt-in Nix support publishes a hash-pinned flake that installs prebuilt release
tarballs without compiling them.

> **Status: v1.** Every part follows semantic versioning. Pin a release's commit SHA.

## What users of your project get

```sh
# DNF (Fedora, RHEL, openSUSE via zypper)
sudo curl -fsSLo /etc/yum.repos.d/<name>.repo https://<owner>.github.io/<repo>/rpm/<name>.repo
sudo dnf install <name>
```

```sh
# APT (Debian, Ubuntu)
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/<name>.asc https://<owner>.github.io/<repo>/<name>.asc
echo 'deb [signed-by=/etc/apt/keyrings/<name>.asc] https://<owner>.github.io/<repo>/deb stable main' | sudo tee /etc/apt/sources.list.d/<name>.list
sudo apt update && sudo apt install <name>
```

When the release workflow enables Nix support:

```sh
nix profile install https://<owner>.github.io/<repo>/nix/flake.tar.gz
```

Every repository built with pkg-pages has the same layout and the same landing page with these
commands, so users who know one know them all ([docs/design.md](docs/design.md#published-layout)).

## What it does

- **APT and DNF from one set of inputs.** One `stable` suite, `deb/` and `rpm/<arch>/`, several
  architectures, `Architecture: all` and `noarch` packages.
- **Optional Nix flake.** Installs release tarballs by SHA-256; it builds no binaries and uses no
  binary cache.
- **Signing is optional and fails closed.** With no committed public key and no secret, the
  repositories are published unsigned. Once the key is committed, every release must be signed
  with it, or the release fails ([docs/signing.md](docs/signing.md)).
- **An offline primary key, with only a signing subkey in CI.** Subkeys can be rotated or
  revoked without users trusting a new key; they download `<name>.asc` again to get the change
  ([docs/signing.md](docs/signing.md#rotating-or-revoking-the-subkey)).
- **Earlier versions stay installable.** The last N releases' packages are fetched from GitHub
  Releases and republished, so `dnf downgrade` and `apt install pkg=1.2.3` keep working.
- **Install tests** on clean Fedora, Debian and Ubuntu containers before anything goes public.
- **Optional packslip and mise install commands** on the landing page for CLIs published on the
  caller's GitHub release.
- **Supply-chain hygiene.** Every action and container image is pinned, the signing key never
  shares a job with a build or with the Pages token, and permissions are set per job.

pkg-pages doesn't require a particular build tool: use cargo-deb, cargo-generate-rpm, nfpm,
dpkg-buildpackage or rpmbuild, and hand it the files. For Rust crates, the `package-rust` action
runs cargo-deb and cargo-generate-rpm for you ([docs/building.md](docs/building.md)).

## Parts

| Path | Kind | Does |
|---|---|---|
| [`action.yml`](action.yml) (`ziptie-soft/pkg-pages@…`) | composite | **build-repo**: build (and sign) the APT/DNF site from a directory of packages |
| [`build-keyring/`](build-keyring/action.yml) | composite | Build the `<name>-keyring` `.deb` that carries the public key |
| [`build-site/`](build-site/action.yml) | composite | Build the site without a key, so the job that parses packages never holds one |
| [`seal-site/`](seal-site/action.yml) | composite | Sign the site's metadata with the CI subkey: the only step that holds the key |
| [`check-site/`](check-site/action.yml) | composite | Check the built site as a client sees it, and upload it as the Pages artifact |
| [`sign-rpm/`](sign-rpm/action.yml) | composite | Sign `.rpm` files with the CI subkey, checked against the pin |
| [`check-rpm/`](check-rpm/action.yml) | composite | Verify `.rpm` signatures against the pin, as dnf does |
| [`fetch-history/`](fetch-history/action.yml) | composite | Download earlier releases' packages from GitHub Releases |
| [`install-test/`](install-test/action.yml) | composite | Install packages in a clean distro container, run a smoke test |
| [`package-rust/`](package-rust/action.yml) | composite | Build a Rust crate's `.deb` and `.rpm` (optional) |
| [`.github/workflows/publish.yml`](.github/workflows/publish.yml) | reusable workflow | All of the above plus the Pages deploy, wired in the right order |

Most projects want the **reusable workflow**. The composite actions suit a release with its own
job layout, for example one that deploys Pages only after other checks have passed.

## Usage

After a build job that uploads the packages as artifacts (`pkg-deb-<arch>`, `pkg-rpm-<arch>`;
other files in them are ignored):

```yaml
jobs:
  # build: ...

  packages:
    needs: build
    # Scoped to this job: the called workflow can't get more than the caller grants.
    permissions:
      contents: read
      pages: write
      id-token: write
    uses: ziptie-soft/pkg-pages/.github/workflows/publish.yml@<full commit SHA> # vX.Y.Z
    with:
      version: ${{ needs.build.outputs.version }}
      tag: ${{ needs.build.outputs.tag }}
      deb-artifacts: pkg-deb-*
      rpm-artifacts: pkg-rpm-*
      description: What these packages are, in one line
      smoke: mytool --version
    secrets:
      signing-key: ${{ secrets.REPO_SIGNING_KEY }}
```

It signs the `.rpm` files, install-tests on Fedora, Debian and Ubuntu, adds the last nine
releases' packages, builds and signs the repositories, and deploys them to Pages.

The same with the composite actions, for a custom job layout:

```yaml
jobs:
  # build: ...

  sign:
    needs: build
    runs-on: ubuntu-24.04
    environment: linux-signing # holds REPO_SIGNING_KEY, restricted to the default branch
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      - uses: actions/download-artifact@<sha> # vX
        with:
          pattern: pkg-*
          path: dist
          merge-multiple: true
      - uses: ziptie-soft/pkg-pages/sign-rpm@<sha> # vX.Y.Z
        with:
          packages: dist/*.rpm
          signing-key: ${{ secrets.REPO_SIGNING_KEY }}
      - uses: ziptie-soft/pkg-pages/fetch-history@<sha> # vX.Y.Z
        with:
          dir: dist
          exclude-tag: ${{ github.ref_name }}
      - uses: ziptie-soft/pkg-pages@<sha> # vX.Y.Z
        with:
          packages: dist
          version: ${{ needs.build.outputs.version }}
          description: What these packages are, in one line
          signing-key: ${{ secrets.REPO_SIGNING_KEY }}

  pages:
    needs: sign
    runs-on: ubuntu-24.04
    environment: github-pages
    permissions:
      pages: write
      id-token: write
    steps:
      - uses: actions/deploy-pages@<sha> # vX
```

Without a committed `packaging/signing/repo.asc` and with no secret, the same jobs publish
unsigned repositories. Full contract: [docs/actions.md](docs/actions.md). Setting up signing:
[docs/signing.md](docs/signing.md).

## Requirements for your repository

- Settings → Pages → Source: **GitHub Actions**. pkg-pages owns the whole Pages site of the
  repository, because every deploy replaces it. Docs can be merged in with `extra-site`.
- Packages attached to GitHub Releases, if you want earlier versions kept.
- For signing: an environment (default `linux-signing`) restricted to the default branch,
  holding the subkey secret, and the public key committed at `packaging/signing/repo.asc`.
- Organisations that restrict actions must allow `ziptie-soft/pkg-pages`.
- GitHub Pages limits: 1 GB per site, 100 MB per file.

## Documentation

- [Design](docs/design.md): architecture, security model, GitHub platform constraints,
  decisions.
- [Actions](docs/actions.md): the inputs, outputs and failure modes of every part.
- [Recipes](docs/recipes.md): copy-ready workflows: signed, unsigned, `.deb` or `.rpm` only, one
  architecture, deploying later, your own job layout.
- [Signing](docs/signing.md): key model, pin, environment, creating and rotating keys.
- [Releasing](docs/releasing.md): versioning, the self-pin release and how callers pin.
- [Building](docs/building.md): `package-rust`, other build tools, and the build actions worth
  adding.
- [Porting](docs/porting.md): where the code comes from and how existing projects migrate.
- [References](docs/references.md): the GitHub docs, formats and prior art behind the design.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): `mise run check` and `mise run test:containers` run
everything CI runs.

## License

[Apache-2.0](LICENSE). Security issues: see [SECURITY.md](SECURITY.md).

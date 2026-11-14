# Design

This document says why pkg-pages is shaped the way it is. The exact inputs and outputs are in
[actions.md](actions.md); the code it is extracted from is in [porting.md](porting.md).

## Goal

One public, versioned set of GitHub Actions that turns a project's `.deb` and `.rpm` files into
signed APT and DNF repositories on GitHub Pages. It should:

- **fit the existing pipelines:** SkeLLLa/star-forge, plasma-drop and cainary, which run copies
  of the same jobs today, without weakening any of their guarantees;
- **fit third parties:** any project that already builds packages, whatever it builds them with,
  with or without signing, one architecture or several.

## Non-goals

- **Owning the build.** Build tools differ per project (cargo-deb, nfpm, dpkg-buildpackage, ...)
  and the build belongs to the caller, in the caller's job. So does its provenance: see
  [C3](#c3-attestations-name-the-reusable-workflow-as-the-signer). `package-rust` is an optional
  helper for the common Rust case ([building.md](building.md)); nothing else depends on it.
- **Multiple distribution suites** (bookworm/trixie/noble side by side). One `stable` suite
  serves packages that run on every supported release. Projects that need per-suite builds are
  served by [mithro/apt-repo-action](https://github.com/mithro/apt-repo-action).
- **Hosting anywhere but GitHub Pages**, and source packages (`.dsc`, `.src.rpm`).
- **Signing `.deb` files.** APT never checks them: `dpkg-sig` and `debsigs` are off by default.
  The signed `InRelease` covers every `.deb` by its SHA-256.
- **Hosting packslip bundles on Pages.** A GitHub project discovers `packslip.sigstore.json` among
  its release assets, while a domain project needs a signed list at the host root under
  `/.well-known/packslip/`; project Pages paths cannot serve that location. Lists expire after
  30 days by default and need scheduled OIDC re-signing, and each bundle must name the domain
  project. For now the page advertises the caller's release install; a custom-domain release list
  may be future work.

## Published layout

```text
<base-url>/
  index.html               landing page: theme, install commands, fingerprint, latest version, footer
  <name>.asc               the public key (the committed pin, with revocations), when signed
  pkg-pages.tsv            every package file by SHA-256 and release tag, when a tag was given
  pkg-pages.tsv.asc        its detached signature, when signed
  .nojekyll
  deb/
    <name>.list            deb [signed-by=/etc/apt/keyrings/<name>.asc] <base-url>/deb stable main
                           (signed-by=/usr/share/keyrings/<name>-keyring.asc with the keyring package)
    pool/main/<p>/<pkg>/   the .deb files (<p>: first letter, or lib<x> for lib* packages),
                           and <name>-keyring_<version>_all.deb, the pin as an APT key, when asked
    dists/stable/
      Release, InRelease, Release.gpg
      main/binary-<arch>/Packages, Packages.gz
  rpm/
    <name>.repo            baseurl=<base-url>/rpm/$basearch, gpgcheck=1, repo_gpgcheck=1,
                           gpgkey=<base-url>/rpm/RPM-GPG-KEY-<name>
    RPM-GPG-KEY-<name>     the pin without revoked or expired subkeys, for dnf, when signed
    <arch>/                the .rpm files (noarch copied into each)
      repodata/repomd.xml, repomd.xml.asc, ...
  nix/                     optional hash-pinned flake for prebuilt release tarballs
    flake.tar.gz, flake.nix, flake.lock
  every directory: index.html listing (Pages serves none)
```

Unsigned sites use `[trusted=yes]` and `gpgcheck=0`/`repo_gpgcheck=0`, and they carry no `.asc`
file.

| Signed | Checked by |
|---|---|
| each `.rpm` (release page and DNF repo) | dnf `gpgcheck=1`, `rpm -K` |
| `rpm/<arch>/repodata/repomd.xml` (`repomd.xml.asc`) | dnf `repo_gpgcheck=1` |
| APT `InRelease` and `Release.gpg` | apt `signed-by=`; `InRelease` lists every `.deb`'s SHA-256 |
| `rpm/RPM-GPG-KEY-<name>` (not signed itself) | the build: it must be the pin minus revoked and expired subkeys, and every `.rpm` and `repomd.xml.asc` must verify against it alone; dnf imports it through `gpgkey=`, since rpm 4.16 can't import a pin with a revoked subkey |
| `pkg-pages.tsv` (`pkg-pages.tsv.asc`) | the next release, which takes the earlier releases from the site by these SHA-256 values |

`pkg-pages.tsv` is tab-separated with LF line endings. The header is
`#pkg-pages-manifest`, `1`, the name and the pin's primary fingerprint (`-` when unsigned). Each
following line is `release`, the release tag, the SHA-256 and the path of a package file (a `noarch`
copy per architecture included), and the `<name>-keyring` package is a `keyring` line with `-` for
the tag, last. The current tag comes first, then the earlier tags in the order of the history map,
each sorted by path.

## Components

Two layers in one repository, versioned together:

1. **Composite actions** are the core. Each does one thing, runs on a plain `ubuntu-*` runner,
   and runs its tools inside a pinned container (`runner-mode: docker`). Alternatively it uses
   tools the job's own container already has (`runner-mode: host`). A caller with its own job
   layout, like plasma-drop, writes its own jobs around them.
2. **The reusable workflow** `publish.yml` is the turnkey path. It owns the job boundaries, the
   environments and the permissions, which composite actions can't declare. Most third parties
   will use it.

| Part | Runs in | Holds the key | Notes |
|---|---|---|---|
| `sign-rpm` | Fedora (rpm 6) | yes | signs in place, then `check-rpm` |
| `check-rpm` | Fedora, or any image with rpmkeys | no | against the *committed* pin, not the key used |
| `install-test` | the target distro image | no | `dnf install ./x.rpm`, `apt-get install ./x.deb`, smoke |
| `fetch-history` | runner (`gh`, `curl`, `gpgv`) | no | last N published releases, from the live site or their assets |
| `build-keyring` | Debian trixie | no | the `<name>-keyring` `.deb` |
| `build-site` | Debian trixie | no | apt-ftparchive, createrepo_c; lists the files to sign |
| `seal-site` | Debian trixie | yes | gpg only; signs that list |
| `check-site` | Debian trixie | no | checks the sealed site, uploads it |
| `build-repo` (root) | Debian trixie | yes, when signed | all of the above in one job, for callers with their own job layout |
| `package-rust` | the build runner | no | optional: cargo-deb, cargo-generate-rpm |
| deploy | runner | no | `actions/deploy-pages` only, in its own job |

### Jobs of the reusable workflow

```text
caller: build ──► artifacts (.deb, .rpm, anything else is ignored)
publish.yml:
  prepare ─► history ─► sign ─► verify ─┐
     └───────────────────────────────────┴─► build ─► seal ─► check ─► deploy
```

| Job | Environment | Permissions | Key | Pages token | Does |
|---|---|---|---|---|---|
| prepare | – | `contents: read` | no | no | checks the inputs; checks out the pin only; keeps the `.deb`/`.rpm`/Nix files of the artifacts; `build-keyring` (a `.deb`) |
| history | – | `contents: read` | no | no | `fetch-history`, from the live site (checked against its signed manifest) or the releases |
| sign | `signing-environment` | none | **yes** | no | `sign-rpm` on this release's `.rpm` files and on the proven history |
| verify | – | none | no | no | `install-test` (the keyring `.deb` too), then the caller's `smoke` |
| build | – | none | no | no | `build-site` over everything; uploads the unsigned site and, on their own, the text files to sign |
| seal | `signing-environment` | none | **yes** | no | `seal-site`: signs `Release`, `repomd.xml` and `pkg-pages.tsv`; always runs |
| check | – | none | no | no | puts the signatures on the site; `check-site` against the pin; uploads the site |
| deploy | `pages-environment` | `contents: read`, `pages: write`, `id-token: write` | no | **yes** | `skip-if-newer`, `extra-artifact-ids`, `deploy-pages` |

Artifacts: `<prefix>-public-key`, `-deb`, `-rpm-unsigned`, `-keyring`, `-nix` (prepare), `-history`
(history), `-rpm`, `-history-resigned` (sign), `-site-unsealed`, `-to-sign` (build),
`-signatures` (seal) and `-site` (check). Every download is by artifact ID.

The key is in `sign` and `seal` only. `build` parses every package, history included, and holds no
secret. `sign` runs `rpmsign` with the key on this release's own `.rpm` files, which are the
caller's build output and trusted as such, and on history whose bytes the signed manifest or the
pin proves; untrusted bytes never meet the key. `seal` runs `gpg` on three kinds of text file that
`seal-site` re-validates, and signs whatever metadata `build` produced: a compromised `build`
could get one site's metadata signed, but can't take the key. `verify` runs the caller's `smoke`
command, and no secret exists in that job. `deploy` holds `pages: write` and `id-token: write`,
and nothing else does. No job runs caller code with a secret.

## Security model

Assets: the signing subkey, the caller's users' trust in the pin, the Pages deploy token.

- **The pin is the root of trust.** It is the committed public key, `packaging/signing/repo.asc`
  by default: exactly one primary, with its subkeys and revocations. `import` fails unless the
  secret is a subkey the pin lists, can sign (no passphrase, not expired or revoked), and is the
  only secret key. The published `<name>.asc` is the pin, revocations included, but clients keep
  the copy they first downloaded: a revocation reaches only users who fetch it again.
- **Fail closed** ([signing.md](signing.md#fail-closed-matrix)). Unsigned output happens only when
  both the pin and the key are absent.
- **Separation.** The key never shares a job with a build, the caller's smoke code or the Pages
  token, and the job that parses the packages never holds it ([D12](#decisions)). It lives in a
  fresh `GNUPGHOME` (or a `--rm` container) for one step.
- **Environment scoping.** The key sits in a GitHub environment restricted to the default branch,
  so a workflow on another branch can't reach it, even a modified copy of the caller's workflow.
- **Pinning.** Callers pin `ziptie-soft/pkg-pages` by commit SHA. pkg-pages pins every action it
  uses by SHA and every image by digest (`images.env`), and it references its own actions by SHA
  ([releasing.md](releasing.md#the-self-pin)). So the commit a caller pins determines everything
  that runs.
- **Untrusted inputs.** Inputs reach `run:` only through `env:`. Names, paths and URLs are
  validated. The landing page HTML-escapes every caller string.
- **History is proven, not trusted.** By default earlier releases come from the live site, by the
  SHA-256 values of its signed `pkg-pages.tsv` ([D11](#decisions)), and a release's assets are
  never republished unchecked. `.rpm` files that the manifest proves are signed again by the
  current subkey; one from a GitHub release that doesn't verify against the pin fails the build.
  `resign-history: true` (for one bootstrap run) signs it anyway, and then whoever can publish or
  edit a release of the caller's repository can get packages signed: turn on immutable releases
  ([signing.md](signing.md#setting-up-a-project)) and drop it again.

Threats out of scope: a compromised GitHub, a caller that keeps the key as a repository secret,
and a malicious maintainer of the caller's repository.

## GitHub platform constraints

These were checked against GitHub's documentation (links in [references.md](references.md)) and
decide the design.

### C1. Environment secrets in a reusable workflow

The job that calls a reusable workflow can't set `environment:`. A job *inside* the reusable
workflow can, and it then reads that environment's secrets **from the caller's repository**.
The caller must still pass the secret by name. GitHub's docs: "You can pass a secret by name even
if it only exists in the environment", and "If the caller workflow doesn't pass an environment
secret, the secret resolves to an empty string in the reusable workflow".

So: `signing-environment` is an input, used as `environment: ${{ inputs.signing-environment }}`
in the `sign` and `seal` jobs. The caller maps its secret to `secrets.signing-key`, so it
chooses the secret's name. `secrets: inherit` only works within one organisation or enterprise,
so third parties map the secret explicitly. Environment branch policies are checked against the
caller's ref.

An empty `signing-environment` means no environment: `environment: ${{ inputs.signing-environment }}`
with an empty value. The self-test (`selftest.yml`) runs `publish.yml` both ways.

### C2. A reusable workflow can't reference itself

`uses:` takes no expressions, and in a called workflow or a composite action `uses: ./x`
resolves in the **caller's** workspace. `publish.yml` must therefore reference its sibling
actions as `ziptie-soft/pkg-pages/<action>@<sha>`, with a SHA from *before* the commit that
contains it. [releasing.md](releasing.md#the-self-pin) describes the two-commit release, and
`dev/check-self-refs.sh` stops `./` references. Composite actions don't have this problem for
files: `${{ github.action_path }}` is the directory of the pinned commit.

### C3. Attestations name the reusable workflow as the signer

From the `gh attestation verify` manual: "if your attestation was generated via a reusable
workflow then that reusable workflow is the signer". plasma-drop verifies
`--signer-workflow …/plasma-drop/.github/workflows/release.yml` and pins its packslip identity
to that same workflow. pkg-pages therefore creates **no attestations** and leaves checksums and
provenance to the caller's build. It also republishes the caller's bytes unchanged, except for
the `.rpm` signatures that `sign-rpm` adds before the caller computes its checksums.

### C4. Permissions only go down

`GITHUB_TOKEN` permissions in a called workflow "can be only downgraded (not elevated)". The
caller's calling job grants the maximum: `contents: read`, plus `pages: write` and `id-token:
write` to deploy. If it grants too little, the run fails at startup before any job begins. Grant
these on the calling job, never at workflow level.

### C5. The `github` context is the caller's

In a called workflow `github.repository`, `github.token`, `github.sha` and `github.ref` are the
caller's. That is what we want: `fetch-history` reads the caller's releases, and the default
`base-url` is the caller's Pages URL. Workflow-level `env:` of the caller is **not** passed in,
so everything comes through `inputs`.

### C6. Marketplace lists one action per repository

"Each repository must contain a single action metadata file (`action.yml` …) at the root."
Actions in sub-folders aren't listed, and reusable workflows can't be listed at all. The root
action is therefore `build-repo`, the most useful on its own, and the README leads to the rest.
The Marketplace `name:` must be unique across the Marketplace and must not match an existing
GitHub user or organisation name.

### C7. Artifacts cross the call boundary

Jobs of a called workflow belong to the caller's run, so `download-artifact` sees the caller's
artifacts and the caller sees ours. To avoid collisions, pkg-pages names its own artifacts
`pkg-pages-*`. Artifacts are passed between jobs by **ID** (`artifact-ids:`), not by name: a
later upload with the same name would otherwise replace them unnoticed (plasma-drop does this
today).

### C8. GitHub Pages

Each deploy replaces the whole site, so the site is rebuilt each time from this release's
packages plus `fetch-history`. Limits: 1 GB per site, 100 MB per file, soft 100 GB/month of
bandwidth. Pages must deploy from GitHub Actions (`build_type: workflow`).

## Decisions

- **D1. Monorepo, one version.** The scripts, the actions and the workflow ship together, so they
  can't drift apart, which is the problem this project exists to fix. The cost: a breaking change
  in one part bumps the version for all of them.
- **D2. Composite core, reusable wrapper.** See [Components](#components). Composites give
  plasma-drop its ordering. The wrapper gives third parties a five-line adoption.
- **D3. POSIX sh, no Python or Node.** The scripts exist and are proven. They run unchanged in
  dash, Fedora and Ubuntu, need nothing installed and are easy to audit. Revisit only if
  metadata handling outgrows shell.
- **D4. Tools in pinned containers, through `docker run`.** The runner's rpm 4.18 can't read a pin
  with revoked subkeys, Fedora has no apt-ftparchive, and Debian's rpmsign looks for `gpg2`. Each
  action runs its tools in the `images.env` image. `runner-mode: host` is for callers that already
  run in a suitable container. The key goes in with `docker run -e REPO_SIGNING_KEY` (the name
  only, so the value is never in argv), with the gpg home on a tmpfs.
- **D5. Read package metadata, not file names.** `dpkg-deb -f` and `rpm -qp --qf` give name,
  version and architecture. This makes cargo-deb's default `-1` revision, nfpm names, several
  packages per repository, `all` and `noarch` packages work without patterns. The
  `*-architectures` inputs are assertions, not filters.
- **D6. One stable suite, `main` component.** The same layout as all three source projects, and
  their users' existing `.list` and `.repo` files keep working after migration.
- **D7. History from the live site** (last 9 releases by default), checked against its signed
  manifest. This replaces v1's rule (history from GitHub Releases, re-signing whatever came):
  a release's assets can be edited by anyone who can publish a release, while the site's manifest
  is signed by the key. GitHub Releases still decide which releases are kept, and
  `history-from: releases` stays as the bootstrap for a site that predates the manifest.
  Re-signing earlier `.rpm` files with the current subkey is expected, and documented as a
  difference from their release-page copies.
- **D8. Apache-2.0**, like the rest of ziptie-soft.
- **D9. Optional Nix flakes install prebuilt archives.** Each archive URL and SHA-256 is written
  into an unsigned flake; the action never builds binaries. The publish job that builds the site only
  lists and hashes the archives, without extracting or running them. Only the current release is
  included. Static or musl binaries are recommended because glibc binaries may need patching on
  NixOS. A binary cache would add a secret and consume GitHub Pages' 1 GB site limit, while
  signing it adds no trust for imported tarballs.
- **D10. Keyring packages.** A signed site publishes `<name>-keyring`, a `.deb` that installs the
  pin as `/usr/share/keyrings/<name>-keyring.asc`, with the version `YYYYMMDD.HHMMSS` of the pin's
  newest signature. `apt upgrade` then delivers new subkeys and revocations, and `deb/<name>.list`
  uses that path as `signed-by`. There is no `.rpm`: rpm can't import a key from a package
  scriptlet, because the transaction holds the rpm database lock. DNF takes the pin without its
  revoked or expired subkeys from `rpm/RPM-GPG-KEY-<name>` through `gpgkey=`, which rpm 4.16 can
  import where it can't import the full pin.
- **D11. History from the site, by a signed manifest.** `pkg-pages.tsv` lists every package file
  by SHA-256 and release tag, and `pkg-pages.tsv.asc` signs it. The next release downloads the
  files it lists, checks each SHA-256 and keeps them. So the bytes are the ones the key signed
  over, whatever a release's assets say. The live manifest may be signed by an expired subkey
  (expiry is not a compromise) but never by a revoked one. The cost is one bootstrap release for a
  site without a manifest ([upgrading.md](upgrading.md)).
- **D12. Two-stage build.** The key never meets code that parses untrusted packages. `build`
  (`build-site`) has no key; `sign` and `seal` have it and run only `rpmsign` and `gpg`, on this
  release's own `.rpm` files, on history the manifest proves and on three kinds of text file.
  The packages are verified before the build: `build-site` refuses an `.rpm` that doesn't verify
  against the pin. Accepted risk: `rpmsign` still parses this release's `.rpm` headers in `sign`.

## Open questions

1. Repositories that already serve docs on Pages: `extra-site` (merge) is enough for now. A
   sub-path mode (`<base-url>/packages/`) may come later.

Settled since: the pool path follows Debian (`pool/main/libf/libfoo` for `lib*` packages); the
landing page's install commands name every package of the release, not only `name`; and aarch64
install tests are opt-in (`"arch": "aarch64"` in `install-tests` runs on `ubuntu-24.04-arm`,
free for public repositories), because private callers pay for those runners.

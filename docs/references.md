# References

## GitHub platform

- [Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows):
  passing inputs and secrets, environment secrets in called workflows, nesting limits.
- [Reusing workflow configurations (reference)](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations):
  limits (50 unique reusable workflows per file), the `github` context being the caller's,
  workflow-level `env` not propagated, permissions only downgraded, access from public
  repositories.
- [Workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax):
  `on.workflow_call.inputs/secrets/outputs`, `jobs.<id>.environment`, `jobs.<id>.container`.
- [Metadata syntax for actions](https://docs.github.com/en/actions/reference/workflows-and-actions/metadata-syntax):
  composite actions, `github.action_path`, outputs.
- [Publishing actions in GitHub Marketplace](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace):
  one root `action.yml` per listing, unique `name`.
- [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments):
  deployment branch policies, environment secrets.
- [Using custom workflows with GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
  and [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).
- [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions):
  pinning to SHAs, script injection.
- [`gh attestation verify`](https://cli.github.com/manual/gh_attestation_verify): "if your
  attestation was generated via a reusable workflow then that reusable workflow is the signer".
- [Immutable releases](https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases).

## Actions this repository uses

- [actions/upload-pages-artifact](https://github.com/actions/upload-pages-artifact),
  [actions/deploy-pages](https://github.com/actions/deploy-pages),
  [actions/configure-pages](https://github.com/actions/configure-pages)
- [actions/upload-artifact](https://github.com/actions/upload-artifact),
  [actions/download-artifact](https://github.com/actions/download-artifact) (`artifact-ids`,
  `overwrite`)
- [googleapis/release-please-action](https://github.com/googleapis/release-please-action),
  [zizmorcore/zizmor-action](https://github.com/zizmorcore/zizmor-action),
  [ossf/scorecard-action](https://github.com/ossf/scorecard-action),
  [jdx/mise-action](https://github.com/jdx/mise-action)

## Repository formats and tools

- [Debian repository format](https://wiki.debian.org/DebianRepository/Format): Release,
  InRelease, Packages, pool layout.
- [apt-ftparchive(1)](https://manpages.debian.org/trixie/apt-utils/apt-ftparchive.1.en.html),
  [sources.list(5) `signed-by`](https://manpages.debian.org/trixie/apt/sources.list.5.en.html)
- [createrepo_c](https://github.com/rpm-software-management/createrepo_c),
  [dnf.conf(5) `gpgcheck`, `repo_gpgcheck`](https://dnf.readthedocs.io/en/latest/conf_ref.html)
- [rpmsign(1)](https://rpm-software-management.github.io/rpm/man/rpmsign.1.html),
  [rpmkeys(8)](https://rpm-software-management.github.io/rpm/man/rpmkeys.8.html)
- [GnuPG manual](https://www.gnupg.org/documentation/manuals/gnupg/): `--quick-gen-key`,
  `--quick-add-key`, `--export-secret-subkeys`, `--pinentry-mode loopback`.

## Prior art

None of these combines APT and DNF with an optional, fail-closed pin. Several have no licence,
so their code can't be reused.

- [mithro/apt-repo-action](https://github.com/mithro/apt-repo-action): APT only, several suites,
  composite actions plus reusable workflows, deploys to Pages. The closest in structure; its
  README's "Permissions" section matches [C4](design.md#c4-permissions-only-go-down).
- [morph027/apt-repo-action](https://github.com/morph027/apt-repo-action): APT only, reprepro,
  one composite action.
- [smeinecke/apt-repo-action](https://github.com/smeinecke/apt-repo-action) /
  [jrandiny/apt-repo-action](https://github.com/jrandiny/apt-repo-action): APT only, reprepro,
  pushes a `gh-pages` branch, keeps only the latest version per suite.
- [alexey-vostrikov/apt-repo-action](https://github.com/alexey-vostrikov/apt-repo-action): APT
  only, aptly, keeps several versions.
- [signalwire/sign-rpm-packages-action](https://github.com/marketplace/actions/sign-rpm-packages):
  RPM signing only.
- Per-project implementations of the same idea:
  [snstac/packages](https://github.com/snstac/packages),
  [fern-api/fern#17902](https://github.com/fern-api/fern/pull/17902),
  [CosmicDriftGameStudio/ncrs#219](https://github.com/CosmicDriftGameStudio/ncrs/pull/219),
  [OpenCHAMI/github-actions#43](https://github.com/OpenCHAMI/github-actions/issues/43),
  [pcavadas/tmp-companion#202](https://github.com/pcavadas/tmp-companion/pull/202),
  [jon.sprig.gs: DEB and RPM repos with GitHub Actions](https://jon.sprig.gs/blog/post/2835).
- Hosted alternatives: Cloudsmith, packagecloud, Gemfury (hosting); openSUSE Build Service, Fedora
  COPR, Launchpad PPA (build from source on their infrastructure).

## Source projects

See [porting.md#sources](porting.md#sources).

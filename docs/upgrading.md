# Upgrading to v2

v2.0.0 changes the jobs of `publish.yml`, where earlier releases come from, and a few defaults.
This page lists what to do. The contracts are in [actions.md](actions.md), the reasons in
[design.md](design.md).

## What changed

| Change | Who | What to do |
|---|---|---|
| `publish.yml`'s jobs are renamed and split | `publish.yml` callers | Update required status checks (the new names are below). |
| Earlier releases come from the live site (`history-from: site`) | callers | Nothing if you released once on v1.3.x. Otherwise run one release with `history-from: releases` (add `resign-history: true` if the earlier `.rpm` assets are unsigned). |
| `resign-history` defaults to `false` | everyone | Use it only for the one-run bootstraps. |
| A `<name>-keyring` package; the `.list` keyring path changes; new landing page commands | callers; end users | Callers: `keyring-package: false` opts out. End users: v1 installs keep working; rerun the new commands once to get future rotations and revocations. |
| DNF: no keyring package; the `.repo`'s `gpgkey=` now points at `rpm/RPM-GPG-KEY-<name>`; existing installs keep working | end users | Nothing. |
| `build-repo`: `tag` required; earlier releases go through `history` and `history-map` | composers | Wire `fetch-history`'s `dir` and `map` into them. |
| `fetch-history` defaults to `from: site` | composers | Pass `public-key`, or set `from: releases`. |
| Strict signature checks; history follows the current subkey | signing maintainers | Add a standby subkey. Rotate by switching CI first and releasing, and only then revoke the old subkey ([signing.md](signing.md)). |
| New site files `pkg-pages.tsv` and `pkg-pages.tsv.asc` | `extra-site` users | Don't ship files with those names. |

## `publish.yml`

No input or output is removed. New: the inputs `history-from` (`site` or `releases`, default
`site`), `history-url` (default `base-url`) and `keyring-package` (default `true`), and the output
`keyring-artifact-id`. `resign-history` now defaults to `false`, and `tag` must contain only
letters, digits and `. _ + / -`. `deb-artifact-id` and `signed-rpm-artifact-id` keep their
meaning.

The jobs, as they appear in the checks list (the `verify` name is unchanged):

| v1 | v2 |
|---|---|
| `Sign the packages` | `Collect the packages` (prepare), `Fetch earlier releases` (history), then `Sign the packages` (sign) |
| `Install test (<distro>, <arch>)` | the same |
| `Build the APT and DNF repositories` | `Build the APT and DNF repositories` (build), `Sign the repository metadata` (seal), `Check the repositories` (check) |
| `Deploy to GitHub Pages (if deploy is true)` | the same |

The reusable workflow's checks show as `<calling job> / <job name>`. A signing environment with
required reviewers now asks for approval twice, in `sign` and in `seal`.

## The bootstrap release

The first v2 release needs the live site to carry a signed `pkg-pages.tsv`, which every release
written by v1.3.x does. If yours doesn't (a site from before v1.3, or a lost one), the release
fails with "the site has no pkg-pages.tsv". Run that one release with:

```yaml
with:
  history-from: releases
  resign-history: true # only if earlier releases' .rpm assets are unsigned or don't verify
```

Then remove both lines: the next release reads the site that this one published. A revoked signer
needs the same bootstrap ([signing.md](signing.md#bootstrapping)).

## Composers

`build-repo`'s new requirements and defaults are in [actions.md](actions.md#build-repo). A caller
that wires `fetch-history` and `build-repo` itself passes `dir` and `map` on as `history` and
`history-map`, and sets `public-key` on `fetch-history`, or keeps `from: releases`.

# Releasing

How pkg-pages is versioned and released, and how callers should pin it.

## Versions

[release-please](https://github.com/googleapis/release-please) reads Conventional Commits on
`master`, keeps one release PR, and merging that PR tags `vX.Y.Z` and creates the GitHub release.
`feat!` and `fix!` (or a `BREAKING CHANGE:` footer) bump the major version. Because callers pin
versions, anything that changes what an existing caller gets counts as breaking:

- renaming or removing an input or output;
- changing a default;
- changing the published layout or a URL;
- changing an image digest in a way that changes behaviour.

## How callers pin

```yaml
uses: ziptie-soft/pkg-pages/.github/workflows/publish.yml@<40-hex SHA of the vX.Y.Z tag> # vX.Y.Z
uses: ziptie-soft/pkg-pages/sign-rpm@<same SHA> # vX.Y.Z
```

- Use the **same SHA for every part**: they are tested together only at the same commit.
- Dependabot (`package-ecosystem: github-actions`) bumps the SHA and the comment, and it
  understands sub-path actions and reusable workflows.
- Pin gates like `dev/check-action-pins.sh` accept `owner/repo/path@<sha>`.

A floating major tag (`v1`) may be offered later, for people who accept that risk. The docs will
always show SHAs.

## The self-pin

`publish.yml` must call this repository's own actions by SHA
([design.md#c2](design.md#c2-a-reusable-workflow-cant-reference-itself)), and a commit can't name
its own SHA. So a release is two commits on top of **W**, the `master` commit it releases:

1. release-please's release commit (changelog, version), and
2. a pin commit, `chore(release): pin publish.yml to <W>`, that points every
   `ziptie-soft/pkg-pages/<action>@…` line of `publish.yml` (those marked
   `# vX.Y.Z pkg-pages self-pin`) at W.

The tag **X** is the second one. A caller pinning X gets `publish.yml`@X → actions@W. Both are
immutable, and the actions, `lib/` and `images.env` in X and W are identical, so X's own actions
are W's too.

`release.yml` does this by itself:

- After release-please updates its PR (on every push to `master`), the `self-pin` job runs
  `dev/self-pin.sh <W> <version>` on the PR branch and pushes the pin commit. W is the pushed
  `master` commit, which the PR is based on. release-please rebuilds the branch on the next
  push, and the job pins it again.
- Merge the release PR with **rebase**, so both commits land on `master` unchanged.
- After the release is created, `check-release` runs `dev/self-pin.sh --check` on the tagged
  commit: every self reference points at one commit, an ancestor whose actions, `lib/` and
  `images.env` are identical. A failure means the release must be replaced by a fix release.

Between releases, `publish.yml` on `master` still points at the last release's W, so the
self-test exercises the workflow with those actions; `ci.yml` tests the current ones.

### The release app

GitHub refuses a `GITHUB_TOKEN` push that changes a workflow file, and PRs made with
`GITHUB_TOKEN` don't run CI. `release.yml` therefore uses a GitHub App token:

1. Create a GitHub App owned by the organisation, with no webhook, and with repository
   permissions Contents, Issues, Pull requests and Workflows set to read and write. Install it on
   this repository only.
2. Create an environment `release` that only `master` may use, holding the variable
   `RELEASE_APP_CLIENT_ID` (the app's client ID) and the secret `RELEASE_APP_PRIVATE_KEY` (a
   private key generated for it).

## Repository settings

Set these before the first release:

- **Immutable releases:** on (Settings → General → Releases), so a tag can't be moved and its
  assets can't be replaced.
- **Rulesets on `master`:**
  - pull requests only;
  - CI, `Self-test` and the `Commits` check required;
  - rebase merging only (squash and merge commits off), so release-please sees every commit;
  - linear history.
- **Tag ruleset:** `v*` tags can only be created by the release app (release-please) and never
  deleted or updated.
- **Private vulnerability reporting:** on (SECURITY.md links to it).
- **Actions:** "Allow ziptie-soft, and select non-ziptie-soft, actions", with the list being
  exactly the actions pinned in this repository.

## GitHub Marketplace

Publish from the GitHub release page ("Publish this Action to the GitHub Marketplace"):

- Only the root `action.yml` (`build-repo`) is listed.
- `name: pkg-pages` must stay unique on the Marketplace and must not equal a GitHub account name.
  Check this at the first listing, and rename to "pkg-pages build-repo" if it's taken.
- Categories: Deployment, Publishing. The README is the listing text, so keep its first screen
  self-explanatory.

## Images

`images.env` digests are bumped by hand, in their own PR (`fix(images): …` or `feat(images)!:
…`), after running the self-test. Note the old and new digests in the PR body.

# Releasing

How pkg-pages is versioned and released, and how callers should pin it.

## Versions

[release-please](https://github.com/googleapis/release-please) reads Conventional Commits on
`master`, keeps one release PR, and merging that PR tags `vX.Y.Z` and creates the GitHub release.
Before v1.0.0, `feat!` bumps the minor version. Because callers pin versions, anything that
changes what an existing caller gets counts as breaking:

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

Floating tags (`v1`) may be offered after v1.0.0, for people who accept that risk. The docs will
always show SHAs.

## The self-pin

`publish.yml` must call this repository's own actions by SHA
([design.md#c2](design.md#c2-a-reusable-workflow-cant-reference-itself)), and a commit can't name
its own SHA. So a release that changes any action takes two commits:

1. Commit **W**: the actions and `lib/` as released. `publish.yml` still points at the previous
   release's SHA.
2. Commit **X**: `publish.yml` rewritten so that every `ziptie-soft/pkg-pages/<action>@…` points
   at **W**. Tag X.

A caller pinning X gets `publish.yml`@X → actions@W, and both are immutable. The composite
actions in X and W are identical, so X's own actions are W's too.

To automate it, use a job in `release.yml` that runs on the release-please PR branch
before merge:

1. Read the PR branch's HEAD as W.
2. Rewrite the references in `publish.yml` with `dev/self-pin.sh W`.
3. Commit as `chore(release): pin publish.yml to <W>`.

release-please then tags the merge commit, which is X. A CI check (`dev/check-self-refs.sh
--pinned`) fails if `publish.yml` on a tagged commit points at anything except an ancestor whose
`lib/` and actions are identical.

## Repository settings

Set these before v0.1:

- **Immutable releases:** on (Settings → General → Releases), so a tag can't be moved and its
  assets can't be replaced.
- **Rulesets on `master`:**
  - pull requests only;
  - CI and the `Commits` check required;
  - rebase merging only (squash and merge commits off), so release-please sees every commit;
  - linear history.
- **Tag ruleset:** `v*` tags can only be created by release-please (GitHub Actions) and never
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

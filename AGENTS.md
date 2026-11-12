# Notes for AI coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first: its layout, commands and rules apply to you too.
The design and the contracts are in `docs/design.md` and `docs/actions.md`.

- Run `mise run check` before you say a change is done. If you touched `lib/` or `tests/`, also
  run `mise run test:containers` (or the affected file with `tests/container.sh`). Report what you
  ran and its result, including skips.
- Never create, export or upload real key material. Prepare the commands and give them to the
  user to run.
- This repository is public. Don't write about anyone's private key storage or tooling.
- Keep the docs short and factual, and update them in the same change as the code.
- Every commit message is a Conventional Commit: pull requests are rebased, not squashed, so
  each commit reaches release-please as written.

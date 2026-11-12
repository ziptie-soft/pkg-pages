# tools

Command-line tools for maintainers of projects that use pkg-pages. They run on your own machine,
never in CI.

- `ci-key [--homedir DIR] SUBKEY`: prints one signing subkey of your offline key in the form the
  `signing-key` input expects: armored, without the primary key's secret and without a
  passphrase. It asks for the passphrase and doesn't change the key in `DIR`. Pipe the output
  straight into the secret store, as [../docs/signing.md](../docs/signing.md) shows.

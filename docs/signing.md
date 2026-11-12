# Signing

How pkg-pages signs packages and repositories, and how a project sets up its key. Signing is
optional: without a committed pin and a secret, everything is published unsigned, with a
notice, and you can start signing at any release.

## Model

- **One key per project.** With a primary key shared across projects, every project's pin would
  accept every project's subkeys, so one leaked CI secret could sign packages that the other
  projects' users accept.
- **The primary key stays offline**, passphrase-protected, and can only certify
  (`rsa4096 cert never`). Users trust its fingerprint.
- **CI holds one signing subkey** (`rsa4096 sign 3y`), exported without the primary's secret
  and without a passphrase. RSA 4096 is accepted by every supported rpm, dnf and apt (sqv).
- **The pin** is the public certificate committed at `packaging/signing/repo.asc` (input
  `public-key`): the primary, every subkey and every revocation, armored, exactly one key. It is
  what gets published as `<name>.asc`, so revocations reach users with the next fetch.

## Fail-closed matrix

What `import` (shared by `sign-rpm` and `build-repo`) does:

| Pin committed | Secret set | Result |
|---|---|---|
| no | no | unsigned, `::notice::`, `signed=false` |
| no | yes | **fail**: commit the public key first |
| yes | no | **fail**: the environment has no secret, or the caller didn't map it |
| yes | yes, a subkey the pin lists, can sign | signed, `signed=true` |
| yes | another primary, or a subkey the pin doesn't list | **fail** |
| yes | passphrase-protected, expired or revoked | **fail** (probe signature) |
| yes | more than one secret key | **fail** |

## Setting up a project

Run these on your own machine, not in CI. The commands work in fish and bash. `<DIR>` is a
private directory used only for this key, `<FPR>` is the primary's fingerprint and `<SUB>` is the
subkey's. `ci-key` is [`tools/ci-key`](../tools/ci-key) from this repository.

1. Create the key; gpg asks for a passphrase:

   ```sh
   install -d -m 700 <DIR>
   gpg --homedir <DIR> --quick-gen-key '<project> packages <you@example.com>' rsa4096 cert never
   gpg --homedir <DIR> -K
   gpg --homedir <DIR> --quick-add-key <FPR> rsa4096 sign 3y
   gpg --homedir <DIR> -K --with-subkey-fingerprints
   ```

2. Commit the pin, in the same change that switches your README's install commands to the
   signed ones:

   ```sh
   gpg --homedir <DIR> --armor --export <FPR> > packaging/signing/repo.asc
   ```

3. Create the environment, restricted to the default branch (here `main`), and set the secret:

   ```sh
   gh api -X PUT repos/<owner>/<repo>/environments/linux-signing -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/<owner>/<repo>/environments/linux-signing/deployment-branch-policies -f name=main
   ci-key --homedir <DIR> <SUB> | gh secret set REPO_SIGNING_KEY --env linux-signing
   ```

   Never store the key as a repository secret: any workflow on any branch could read it.

4. Keep two things offline, separately: `<DIR>` (the primary's secret, passphrase-protected), and
   the revocation certificate gpg wrote to `<DIR>/openpgp-revocs.d/<FPR>.rev`, which revokes the
   whole key even if `<DIR>` is lost.

The next release is the first signed one.

## Rotating or revoking the subkey

Users trust the primary, so a subkey change needs nothing from them beyond the `<name>.asc` they
fetch. Order matters, because `import` refuses a subkey that the committed pin doesn't list:

1. Add the new subkey (`--quick-add-key <FPR> rsa4096 sign 3y`). If the old one leaked, revoke it
   (`gpg --homedir <DIR> --edit-key <FPR>`, then `key N`, `revkey`, `save`).
2. Export and commit `repo.asc`, and push it to the default branch.
3. Only then set the secret to the new subkey.

Releases fail between steps 2 and 3, which is intended. Once the revocation is published, dnf
refuses packages signed by the revoked subkey, and the next site build re-signs earlier
releases' `.rpm` files with the current one.

If the **primary** leaks: import the revocation certificate (delete the `:` before
`-----BEGIN`), and commit the revoked `repo.asc` (every release fails from then on). Then start
over with a new key. APT users must download the new `<name>.asc` (`apt update` fails until they
do), and DNF asks them to accept the new key.

## Gotchas the scripts handle

Problems the scripts work around, all met in the source projects:

- Debian's `rpmsign` runs `gpg2`. The scripts always pass `--define "__gpg <path of gpg>"`,
  plus `_gpg_name <fpr>` and `_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback`.
- rpm 6 skips an identical re-signature, but errors with "already contains a legacy signature"
  when a *different* key's signature is added. Only tests hit this.
- Verification uses `rpmkeys --dbpath <tmp>` and `_pkgverify_level signature`. Without it,
  unsigned files pass on their digests.
- The Ubuntu 24.04 runner's rpm 4.18 can't import a certificate with a revoked subkey, so
  `build-repo` runs in Debian trixie.
- gpg 2.4 has no `export-reset-subkey-passwd`. `ci-key` strips the passphrase in a temporary
  keyring with `--passwd` (old, empty, empty).
- Scripted revocation needs `--batch --command-fd 0` and `key N` (an index, not a
  fingerprint).
- Steps in a job with `container:` run with `sh` (dash), so `lib/` is POSIX sh.

## Tests

`tests/signing.bats` and `tests/pages-repo.bats` check all of this with throwaway keys, as root
in the Debian, Ubuntu and Fedora images (`mise run test:containers`, and CI):

- every row of the fail-closed matrix, plus a pin with two keys or with secret material, two
  secret keys, and the primary's secret in CI;
- rotation (the new subkey with the new pin passes; with the old pin it fails) and revocation (a
  revoked subkey fails `import`, and its old signatures fail `check-rpm`);
- an expired subkey, and a passphrase-protected one;
- signing with Fedora's rpm 6 and Debian's rpm 4.20, re-signing an earlier release's `.rpm`, and
  leaving a signed one byte-identical;
- a site built into `file:///`, then `apt install` with `signed-by` (and pinning an older
  version), and `dnf install` and `dnf downgrade` with `gpgcheck=1 repo_gpgcheck=1`;
- a tampered `InRelease`, another project's key in `signed-by`, and a modified `repomd.xml`, all
  rejected.

# Signing

How pkg-pages signs packages and repositories, and how a project sets up its key. Signing is
optional: without a committed pin and a secret, everything is published unsigned, with a
notice, and you can start signing at any release.

## Model

The optional Nix flake is not covered by OpenPGP signing; its referenced archives are pinned by
SHA-256.

- **One key per project.** With a primary key shared across projects, every project's pin would
  accept every project's subkeys, so one leaked CI secret could sign packages that the other
  projects' users accept.
- **The primary key stays offline**, passphrase-protected, and can only certify
  (`rsa4096 cert never`). Users trust its fingerprint.
- **CI holds one signing subkey**, exported without the primary's secret and without a
  passphrase. A second, **standby** subkey exists from the start and is not in CI. Both are
  `rsa4096 sign never`. RSA 4096 is accepted by every supported rpm, dnf and apt (sqv).
- **Signing subkeys have no expiry.** A DNF client never learns an extended expiry: it imports
  the key once and doesn't fetch it again, so packages signed after the original expiry would
  fail there. Rotation and revocation replace expiry.
- **The pin** is the public certificate committed at `packaging/signing/repo.asc` (input
  `public-key`): the primary, every subkey and every revocation, armored, exactly one key. It is
  published as `<name>.asc`.

## Published keys

- **`<name>.asc`**: the full pin, byte for byte, with revocations. APT and the
  `<name>-keyring` package use it, and rpm 6 users import it to apply a revocation.
- **`rpm/RPM-GPG-KEY-<name>`**: the pin without revoked or expired subkeys. The site's `.repo`
  sets `gpgkey=` to it, because rpm 4.16 (RHEL 9) can't import a pin that has a revoked subkey.

Never publish or import an older pin, and never import a pin after an expiry extension: rpm 6
would undo a revocation, and packages signed before the new binding would stop verifying.

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

A signed run also warns when the signing subkey expires within 90 days. This is a safety net for
keys created by other means; keys made as below never expire.

## Setting up a project

Run these on your own machine, not in CI. The commands work in fish and bash. `<DIR>` is a
private directory used only for this key, `<FPR>` is the primary's fingerprint and `<SUB>` is the
subkey's. `ci-key` is [`tools/ci-key`](../tools/ci-key) from this repository.

1. Create the key; gpg asks for a passphrase:

   ```sh
   install -d -m 700 <DIR>
   gpg --homedir <DIR> --quick-gen-key '<project> packages <you@example.com>' rsa4096 cert never
   gpg --homedir <DIR> -K
   gpg --homedir <DIR> --quick-add-key <FPR> rsa4096 sign never
   gpg --homedir <DIR> --quick-add-key <FPR> rsa4096 sign never
   gpg --homedir <DIR> -K --with-subkey-fingerprints
   ```

   The two subkeys are the active one (`<SUB>`, which goes to CI) and the standby (`<STANDBY>`).
   Create both before the first signed release, so the pin published with it already lists the
   standby.

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

   Never store the key as a repository secret: any workflow on any branch could read it. If
   your releases run on pushed tags rather than on the default branch, also allow the release
   tags, and protect them with a tag ruleset:

   ```sh
   gh api -X POST repos/<owner>/<repo>/environments/linux-signing/deployment-branch-policies -f name='v*' -f type=tag
   ```

   Create the environment before the first run: GitHub creates a missing one on first use, with
   no branch policy.

4. Protect the earlier releases, which every site build republishes and signs: turn on immutable
   releases (Settings → General → Releases), and add a tag ruleset that limits who can create
   tags.

5. Keep two things offline, separately: `<DIR>` (the primary's secret, passphrase-protected), and
   the revocation certificate gpg wrote to `<DIR>/openpgp-revocs.d/<FPR>.rev`, which revokes the
   whole key even if `<DIR>` is lost.

The next release is the first signed one; see [Bootstrapping](#bootstrapping).

## Rotating or revoking the subkey

Users trust the primary, so a subkey change asks no new trust of them. Rotate to the standby,
which every client's key copy already lists, in this order:

1. Switch CI to the standby and release:

   ```sh
   ci-key --homedir <DIR> <STANDBY> | gh secret set REPO_SIGNING_KEY --env linux-signing
   ```

   The release re-signs the earlier `.rpm` files that the new subkey didn't sign, and seals a
   new manifest with it.
2. Only then revoke the old subkey (`gpg --homedir <DIR> --edit-key <FPR>`, then `key N`,
   `revkey`, reason 2 "superseded", `save`). Add the next standby (`--quick-add-key <FPR> rsa4096
   sign never`), export and commit `repo.asc`, and release.

Never switch CI to a subkey that was published only in the same release: dnf5 caches the
repository key at first use, and `import` refuses a subkey the committed pin doesn't list.
If the old subkey leaked, don't wait: revoke it, add a new subkey, commit the pin, then set the
secret. Releases fail between the revocation and the new secret, which is intended.

Clients, per tool:

- **APT**: the `<name>-keyring` package carries the pin, so `apt upgrade` delivers new subkeys
  and revocations. The package version comes from the pin's newest signature.
- **dnf5 (rpm 6)**: packages pick up new subkeys automatically. Where `repo_gpgcheck=1` is set,
  clients that installed before the subkey now signing was published run:

  ```sh
  sudo rm -rf /var/cache/libdnf5/<name>-*
  ```

  To apply a revocation, import the full pin: `sudo rpmkeys --import <base-url>/<name>.asc`.
- **dnf4 (rpm 4.16)**: remove the old key, and the next dnf run imports the key file again:

  ```sh
  rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}  %{SUMMARY}\n'
  sudo rpm -e gpg-pubkey-<version>-<release>
  ```

dnf never fetches a key again because of a revocation, so a revocation reaches DNF users only
through these steps.

## Bootstrapping

Earlier releases normally come from the live site, checked against its signed manifest
(`pkg-pages.tsv`). Three cases have no usable site, or have unsigned or unprovable `.rpm`
assets. Run one release with `history-from: releases` and `resign-history: true`, then drop both:

- the first signed release of a project that published unsigned before;
- a lost site (no `pkg-pages.tsv`, or a deleted Pages deployment);
- a revoked signer: the live manifest of a revoked subkey is never accepted. Rotating in the
  order above avoids this.

`resign-history: true` re-signs unproven `.rpm` assets with a warning. Leave it `false` otherwise.

If the **primary** leaks: import the revocation certificate (delete the `:` before
`-----BEGIN`), and commit the revoked `repo.asc` (every release fails from then on). Then start
over with a new key. APT users get the new key from the keyring package only if they can still
install it, so give them the new `<name>.asc` (`apt update` fails until they have it), and DNF
asks them to accept the new key.

## Gotchas the scripts handle

Problems the scripts work around, all met in the source projects:

- Debian's `rpmsign` runs `gpg2`. The scripts always pass `--define "__gpg <path of gpg>"`,
  plus `_gpg_name <fpr>` and `_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback`.
- rpm 6 skips an identical re-signature, but errors with "already contains a legacy signature"
  when a *different* key's signature is added. Only tests hit this.
- Verification uses `rpmkeys --dbpath <tmp>` and `_pkgverify_level signature`. Without it,
  unsigned files pass on their digests. The database holds the pin without revoked or expired
  subkeys (`pin_rpm_key`), as dnf gets it, so a package signed by a revoked subkey fails.
- rpm before 4.20 (Ubuntu 24.04's 4.18, RHEL 9's 4.16) can't import a certificate with a revoked
  subkey, so `.rpm` checks import `pin_rpm_key`'s output instead of the pin.
- gpg 2.4 has no `export-reset-subkey-passwd`. `ci-key` strips the passphrase in a temporary
  keyring with `--passwd` (old, empty, empty).
- Scripted revocation needs `--batch --command-fd 0` and `key N` (an index, not a
  fingerprint).
- gpgv exits 0 for revoked and expired keys; only the status tokens tell. `gpg_verify` reads them
  and refuses `REVKEYSIG`, `EXPKEYSIG` (unless asked), `EXPSIG`, `BADSIG`, `ERRSIG` and
  `NO_PUBKEY`, and any primary other than the pin's.
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

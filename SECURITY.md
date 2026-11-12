# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/ziptie-soft/pkg-pages/security/advisories/new).
Do not open a public issue.

Include the affected action or workflow and version, what an attacker can do, and steps to
reproduce. You should get a first answer within a week. Fixes are released as a new version and
announced in a GitHub security advisory. Because callers pin commit SHAs, the advisory lists the
fixed version's tag and SHA.

## Supported versions

Only the latest release gets security fixes.

## Scope

In scope: anything that lets an attacker do one of these:

- get a package or repository signed or published without the caller's key;
- make a caller's release ship unsigned once its pin is committed;
- read or leak the signing key;
- run code in a job that holds the key or the Pages token;
- make clients accept metadata or packages that the pin did not sign.

Out of scope: weaknesses in GitHub Actions, GitHub Pages, gpg, rpm or apt themselves; a caller
that stores its key as a repository secret instead of in an environment, or passes untrusted
input to `smoke`; and anything that needs write access to the caller's repository.

The threat model is in [docs/design.md](docs/design.md#security-model).

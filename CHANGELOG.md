# Changelog

## [2.0.0](https://github.com/ziptie-soft/pkg-pages/compare/v1.2.0...v2.0.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* **publish:** publish.yml's jobs are renamed (update required status checks); earlier releases come from the live site (run once with history-from: releases if your site predates v1.3); resign-history defaults to false; signed sites publish <name>-keyring.
* **fetch-history:** fetch-history reads the live site's signed manifest; pass public-key, or set from: releases to keep the old behaviour.
* **build-repo:** an earlier release's .rpm that doesn't verify against the pin now fails the build; set resign-history: true for one run to re-sign it.
* **build-repo:** signed sites add a <name>-keyring .deb, and deb/<name>.list now uses signed-by=/usr/share/keyrings/<name>-keyring.asc; set keyring-package: false to opt out.
* **build-repo:** build-repo needs tag, and takes earlier releases as history and history-map (from fetch-history) instead of inside packages.

### Features

* **build-repo:** publish a &lt;name&gt;-keyring package by default ([05153e6](https://github.com/ziptie-soft/pkg-pages/commit/05153e60ebb761e40e90663def86d776014f74cd))
* **build-repo:** refuse unproven earlier .rpm files unless resign-history is true ([ff76726](https://github.com/ziptie-soft/pkg-pages/commit/ff76726bec21bb84dae7a878f5a06b582b5b8c1b))
* **build-repo:** run the key and the package parsing in separate containers, with earlier releases passed as history ([425884c](https://github.com/ziptie-soft/pkg-pages/commit/425884ced89fc649f995626894cb3d2c63e9ba6a))
* **fetch-history:** fetch earlier releases from the live site by default ([20d3336](https://github.com/ziptie-soft/pkg-pages/commit/20d3336fb78094411cda01977c08c0cfd2ecc54f))
* **publish:** build without the key, sign in separate jobs, and take earlier releases from the site ([c589041](https://github.com/ziptie-soft/pkg-pages/commit/c58904105183e914a966d61ec34c212edcba624d))

## [1.2.0](https://github.com/ziptie-soft/pkg-pages/compare/v1.1.1...v1.2.0) (2026-11-14)


### Features

* add the build-keyring, build-site, seal-site and check-site actions ([e95f2eb](https://github.com/ziptie-soft/pkg-pages/commit/e95f2eb92dee9ffad137259037c43f8238980b5e))
* **build-repo:** add resign-history, and warn for each earlier release's .rpm that is re-signed ([903cb8e](https://github.com/ziptie-soft/pkg-pages/commit/903cb8e51476cb23591e6e3724041fffd94824e7))
* **build-repo:** add tag, history-map and keyring-package, and publish the manifest when tag is set ([3c83f90](https://github.com/ziptie-soft/pkg-pages/commit/3c83f90a436117af412c1dd7983f0e151bb268cb))
* **build-repo:** publish a signed manifest of the site's packages, and an optional keyring package ([7a1d800](https://github.com/ziptie-soft/pkg-pages/commit/7a1d800653e79edd97fff38c8cc82fba107eeee3))
* **docker:** install the tools in a throwaway container, and run the command offline with fewer capabilities ([a3460f9](https://github.com/ziptie-soft/pkg-pages/commit/a3460f9bce6a7cb0fc686b367f11a7428e8acdbf))
* **fetch-history:** add the site source, an explicit tag list and the history map ([8eee912](https://github.com/ziptie-soft/pkg-pages/commit/8eee9126116020a7192bac750a7473497fe73884))
* **fetch-history:** fetch earlier releases from the live site, checked against its signed manifest ([5f6602f](https://github.com/ziptie-soft/pkg-pages/commit/5f6602f502925adbbc051a2aacf5087eb0455ba3))
* **lib:** build a &lt;name&gt;-keyring .deb from the pin ([62bf876](https://github.com/ziptie-soft/pkg-pages/commit/62bf87664b169f69dfce8fe32e6bc3f8f72eaa59))
* **publish:** pass the tag and the history map on, so that sites carry a signed manifest ([71462b2](https://github.com/ziptie-soft/pkg-pages/commit/71462b28af7a374417729ba46239142501d62e2c))
* **sign-rpm:** keep earlier releases' .rpm files signed by the current subkey, re-signing only proven ones ([3960920](https://github.com/ziptie-soft/pkg-pages/commit/396092037f5c561e80a2e080d3c215986d08e4ea))
* **sign-rpm:** sign earlier releases' .rpm files through history and history-map ([a3f4879](https://github.com/ziptie-soft/pkg-pages/commit/a3f4879af18297985001893545230bed163a063a))
* **signing:** warn when the signing subkey expires within 90 days ([5b9d5c1](https://github.com/ziptie-soft/pkg-pages/commit/5b9d5c1d49e959487dd950346339e8b91afa622b))


### Bug Fixes

* **actions:** check the files a packages glob matches, not only the pattern, against '..' ([9de01ca](https://github.com/ziptie-soft/pkg-pages/commit/9de01ca3fd847ffd7b4fa464912077ae2074a5b1))
* **build-repo:** fail instead of overwriting when two .deb files differ only in their epoch ([110a98d](https://github.com/ziptie-soft/pkg-pages/commit/110a98da470fc04838b3ed78b9e75b89b966f9af))
* **build-repo:** point dnf at a key without revoked or expired subkeys, which rpm 4.16 can import ([f70780e](https://github.com/ziptie-soft/pkg-pages/commit/f70780eec8cfbb4447ec2b8545bbff4b7191ba82))
* **build-repo:** refuse base-url characters that the install commands would need to quote ([1f897bf](https://github.com/ziptie-soft/pkg-pages/commit/1f897bff2583665ebb1a2f541bf9cd2082536af5))
* **build-repo:** refuse control characters in title, which goes into the .repo file and Release ([249e606](https://github.com/ziptie-soft/pkg-pages/commit/249e606ce6302a1866a38d07fa9284807222f0e4))
* **build-repo:** refuse symbolic links and other non-regular files among the packages ([85b15a7](https://github.com/ziptie-soft/pkg-pages/commit/85b15a7466c806a94d1e6fe35532c95dd52b7a4f))
* **docker:** hide the signing key from the package manager inside the container ([0bb44d4](https://github.com/ziptie-soft/pkg-pages/commit/0bb44d4f3b66b01ed2bf238dba6c15c729a12975))
* **fetch-history:** accept ~ in manifest paths, as pre-release versions use it ([ac97f81](https://github.com/ziptie-soft/pkg-pages/commit/ac97f8121f2fc994cc9f2212a21dd7c5a8bd40a6))
* **fetch-history:** keep assets of the same name from different releases instead of skipping them ([2800035](https://github.com/ziptie-soft/pkg-pages/commit/2800035a0d7d11d4922fc15381835f64572a00fd))
* **publish:** check the public-key path before the sparse checkout uses it ([448f43a](https://github.com/ziptie-soft/pkg-pages/commit/448f43a9c3bfa9f9d42f535aa1e7ef710c5d60b3))
* **publish:** name the release in the landing page footer, not the release before it ([89d219d](https://github.com/ziptie-soft/pkg-pages/commit/89d219d7a4d369cc295f54d79bfd74096c0a7284))
* **run:** stop gpg-agent on interrupt, keep the io files private, and mount check-rpm's checkout read-only ([4bf0e4d](https://github.com/ziptie-soft/pkg-pages/commit/4bf0e4d6872c659a0ac4500d7a0603a74d84c39b))
* **signing:** accept a signature only if it is valid, by the pin's key, and not by a revoked or expired key ([fb04a7f](https://github.com/ziptie-soft/pkg-pages/commit/fb04a7ff4cf1c94f58d0bd3973246c11717f60be))
* **signing:** check .rpm signatures against the pin without revoked or expired subkeys, which rpm before 4.20 can import ([80d7432](https://github.com/ziptie-soft/pkg-pages/commit/80d74329ea05133dc57c628a445155f589bc0538))
* **signing:** give gpg a temporary home in the read-only container, so check-rpm and the site checks work ([a97594f](https://github.com/ziptie-soft/pkg-pages/commit/a97594f318af5dfe13a0fe86a7dfb87673327b36))
* **signing:** keep the signing key out of the environment of every tool but the import ([ecf373d](https://github.com/ziptie-soft/pkg-pages/commit/ecf373dc391d3c210891ccdea76594e57e1b89f3))

## [1.1.1](https://github.com/ziptie-soft/pkg-pages/compare/v1.1.0...v1.1.1) (2026-11-13)


### Bug Fixes

* **build-repo:** mount version.txt in docker mode so the footer names the pkg-pages version ([ebc22d8](https://github.com/ziptie-soft/pkg-pages/commit/ebc22d8ffa3f78eea2d2fe0dc50d15d9d6a9e753))
* **build-repo:** widen the landing page and wrap long commands instead of scrolling ([63f9371](https://github.com/ziptie-soft/pkg-pages/commit/63f9371448f579dea81694956c864abb72da5c87))
* **publish:** give the deploy job a fixed name, as skipped jobs show expressions unevaluated ([ea1ad7e](https://github.com/ziptie-soft/pkg-pages/commit/ea1ad7e0cdbd009a18b70010f9eb8d279358c182))
* **publish:** name the deploy job after the deploy input, so a skipped deploy reads as intended ([e5628bd](https://github.com/ziptie-soft/pkg-pages/commit/e5628bd659b1e70e89640580568c46413c451860))

## [1.1.0](https://github.com/ziptie-soft/pkg-pages/compare/v1.0.0...v1.1.0) (2026-11-13)


### Features

* **build-repo:** add a footer linking to pkg-pages, with an opt-out input ([9705abd](https://github.com/ziptie-soft/pkg-pages/commit/9705abdc5ce056f29ad444b8727c2d6955bf4243))
* **build-repo:** advertise a packslip install on the landing page ([29df73a](https://github.com/ziptie-soft/pkg-pages/commit/29df73a6c387cc30e0fca795f7869e66aa7e69d1))
* **build-repo:** restyle the landing page and directory listings, with a light/dark theme ([0112515](https://github.com/ziptie-soft/pkg-pages/commit/01125158e8881fea9d51554261c1fb08d816cdc5))
* **nix:** publish a hash-pinned flake of the release's prebuilt tarballs ([2c21166](https://github.com/ziptie-soft/pkg-pages/commit/2c2116608d72680f057c27e437d8100d8af3e2e8))

## 1.0.0 (2026-11-12)


### Features

* init ([1283d2c](https://github.com/ziptie-soft/pkg-pages/commit/1283d2cf8dd4f9dc9f27a3f112d8d8ead0303d4b))
* **install-test:** install only the packages for the container's architecture ([1c72b4a](https://github.com/ziptie-soft/pkg-pages/commit/1c72b4a1643b09a67716170cf4c4d7702b3257a6))
* **publish:** implement the reusable workflow ([ff7b6d3](https://github.com/ziptie-soft/pkg-pages/commit/ff7b6d31b9b89efa4a686ed403453d14d06db223))


### Bug Fixes

* **publish:** check out only the public key, and run the self-pin from the trusted commit ([0ae9d1f](https://github.com/ziptie-soft/pkg-pages/commit/0ae9d1f42a9010fe843924d4123d1503e6cc8c42))
* **publish:** read the public key once, in the sign job, and pass it on as an artifact ([6a3b252](https://github.com/ziptie-soft/pkg-pages/commit/6a3b252887365840c3ee2623de11b535677f63c6))
* **release:** update the release PR through the API instead of checking it out ([b62b0d9](https://github.com/ziptie-soft/pkg-pages/commit/b62b0d9dc01f9ecf271782d7ec3f663c955fa720))
* scorecard ([924f21e](https://github.com/ziptie-soft/pkg-pages/commit/924f21ed7d0f513ee2f4addd330e5f444bef866c))

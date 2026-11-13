# Changelog

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

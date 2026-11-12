# Building packages

pkg-pages signs and publishes `.deb` and `.rpm` files; it doesn't care how they were built. It
reads each package's name, version and architecture from the package itself, so any tool works.
This page covers the build side: the `package-rust` action, the tools to use for other languages,
and the shared actions that would be worth adding.

Whatever you build with, build in its own job, upload the packages as artifacts, and sign and
publish them in later jobs. The signing key must never be in a job that compiles code.

## Rust: `package-rust`

`uses: ziptie-soft/pkg-pages/package-rust@<sha>` builds a crate with
[cargo-deb](https://github.com/kornelski/cargo-deb) and
[cargo-generate-rpm](https://github.com/cat-in-136/cargo-generate-rpm), the tools the source
projects use. It:

1. installs both tools at pinned versions with `cargo install --locked`, unless they are already
   present (`cargo-deb-version`, `cargo-generate-rpm-version`);
2. runs `cargo build --release --locked` (skip it with `build: 'false'`);
3. runs `cargo-deb --no-build` and `cargo-generate-rpm` into `out`;
4. checks that each package's version is the crate's (or `version`), and outputs the paths and
   the architectures.

The crate configures its packages as usual, in `[package.metadata.deb]` and
`[package.metadata.generate-rpm]` of `Cargo.toml` (see `tests/fixtures/hello-rust`). The job needs
Rust installed: the GitHub-hosted Ubuntu runners have rustup, and `rustup toolchain install` pins a
version. Build each architecture on its own runner (`ubuntu-24.04` and `ubuntu-24.04-arm`): cross
builds also need the target's linker and libraries.

```yaml
jobs:
  packages:
    strategy:
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX
        with:
          persist-credentials: false
      - id: pkg
        uses: ziptie-soft/pkg-pages/package-rust@<sha> # vX.Y.Z
      - uses: actions/upload-artifact@<sha> # vX
        with:
          name: pkg-deb-${{ steps.pkg.outputs.deb-arch }}
          path: ${{ steps.pkg.outputs.deb }}
      - uses: actions/upload-artifact@<sha> # vX
        with:
          name: pkg-rpm-${{ steps.pkg.outputs.rpm-arch }}
          path: ${{ steps.pkg.outputs.rpm }}
```

Version mismatches fail the build. cargo-deb adds the Debian revision `-1`, which pkg-pages
accepts. A pre-release `1.2.0-rc.1` becomes `1.2.0~rc.1` in the `.rpm`, because rpm forbids `-`
in versions, and `~` sorts it before `1.2.0`.

## Other languages

| Tool | For | Notes |
|---|---|---|
| [nfpm](https://nfpm.goreleaser.com) | anything that produces files: Go, C, Zig, scripts, prebuilt binaries | One YAML file, both formats, no dependencies (a single Go binary). The most general choice. |
| [GoReleaser](https://goreleaser.com) | Go | Builds, then packages with nfpm (`nfpms:`); upload its `dist/*.deb` and `dist/*.rpm`. |
| `dpkg-buildpackage` / `rpmbuild` | projects that already ship `debian/` or a `.spec` | The native tools; build in the target distribution's container. |
| [fpm](https://fpm.readthedocs.io) | quick conversions | Ruby; nfpm covers most of what it does. |
| cargo-deb / cargo-generate-rpm directly | Rust, when `package-rust` doesn't fit | Same tools, your own steps. |

## Shared actions worth adding

These would make pkg-pages cover the build end as well, for most projects. None of them exists
yet.

- **`package-nfpm`**: install nfpm (a pinned release binary, checked by SHA-256), run
  `nfpm package` for each of `deb` and `rpm` from the caller's `nfpm.yaml`, with `version` and
  `arch` passed in through the environment (`${VERSION}` and `${ARCH}` in the config), then check
  the metadata like `package-rust` does. Language-agnostic, so it covers Go, C, Zig and prebuilt
  binaries. This is the one to add next.
- **`package-go`**: a thin wrapper that runs `go build` for `GOOS=linux` and each `GOARCH` (no
  cross linker needed with `CGO_ENABLED=0`), then calls `package-nfpm`. GoReleaser users don't
  need it.
- **A `build:` stage in `publish.yml`**: a matrix job that calls `package-rust` or
  `package-nfpm` and uploads `pkg-pages-deb-<arch>` and `pkg-pages-rpm-<arch>`, so that a project
  with a standard layout needs only the reusable workflow. It has to stay a separate job from
  signing (see [design.md](design.md#security-model)).
- **Reproducible builds**: pass `SOURCE_DATE_EPOCH` from the release commit to the build tools
  (cargo-generate-rpm and nfpm honour it), so a rebuild from the tag gives the same bytes and the
  caller's attestations stay checkable.

#!/bin/sh
# Build the APT and DNF repositories site from a directory of .deb and .rpm files, ready to be
# served by GitHub Pages (or any static file server). Rewritten from SkeLLLa/star-forge's
# packaging/ci/pages-repo.sh to read each package's own metadata instead of matching file names.
#
# Usage:
#   pages-repo.sh --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]...
#
# Required:
#   --packages DIR          every .deb and .rpm the site publishes (searched recursively); any
#                           other file, or a symbolic link, is an error
#   --out DIR               the site directory to create; it must not exist
#   --base-url URL          where OUT is served: https://... or file:///..., letters, digits and . _ ~ : / % + @ = , - only
#   --version VERSION       the release; a package of it must be among the packages
#   --name NAME             base name of <name>.asc, deb/<name>.list, rpm/<name>.repo
# Optional:
#   --title TEXT            landing page title, .repo name and APT Description; one line (default "NAME package repositories")
#   --description TEXT      one line for the landing page
#   --homepage URL          project link on the landing page
#   --suite SUITE           APT suite and codename (default stable)
#   --component COMPONENT   APT component (default main)
#   --deb-architectures "A B"  Debian architectures that must each have a VERSION package built
#                           for exactly that architecture (all counts only when listed itself)
#   --rpm-architectures "A B"  the same for RPM architectures (noarch likewise)
#   --nix-archives "SYSTEM=PATH…" --nix-binaries "A B" --nix-url-base URL
#                           opt in to a hash-pinned flake of prebuilt archives
#
# Published architectures: those of the packages, plus the required ones. all/noarch packages
# are listed in every one of them; with only all/noarch packages, amd64 arm64 / x86_64 aarch64.
#   --public-key FILE       the pin; required when signing, published as <name>.asc
#   --directory-listings true|false  an index.html in every directory (default true)
#   --footer true|false     add a pkg-pages footer to the landing page and listings (default true)
#   --footer-version V      the pkg-pages version the footer names (default: version.txt beside lib/)
#   --packslip-project PROJECT  show packslip and mise install commands for this project (default off)
#   --packslip-pin PIN      optional packslip signer pin (ps1_ followed by 26 base32 characters)
#   --extra-site DIR        merged into the site root; may not overwrite a file of the site
#   --resign-history true|false  re-sign an earlier release's .rpm that doesn't verify against the
#                           pin, with a warning (default true), or fail on it (false)
#   --import-key true|false first import REPO_SIGNING_KEY into GNUPGHOME, failing closed against
#                           --public-key, as `linux-signing.sh import` does (default false)
#
# Signing: the site is signed when --import-key imported a key, or when GNUPGHOME is set and
# already holds one: every .rpm (rpmsign) here, then InRelease, Release.gpg and every repomd.xml
# by lib/site-seal.sh.
# Otherwise it is unsigned ([trusted=yes], gpgcheck=0). Whether a run *must* be signed is decided
# by the import, which fails closed (docs/signing.md).
#
# Tools: apt-ftparchive and dpkg-deb when there are .deb files; createrepo_c and rpm when there
# are .rpm files; gpg, gpgv, rpmsign and rpmkeys when signing; gzip, sed, awk, find, sha256sum.
#
# Outputs (GITHUB_OUTPUT): signed=true|false, fingerprint, site-path; and PKG_PAGES_SIGNED,
# PKG_PAGES_FINGERPRINT in GITHUB_ENV. Progress goes to stderr.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"
# The key is for signing_import alone, which reads the shell variable: no tool this script runs,
# the package readers included, gets it in its environment.
signing_key="${REPO_SIGNING_KEY-}"
unset REPO_SIGNING_KEY

usage() {
    die "usage: $0 --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]... (see the header of $0)"
}

packages='' out='' base_url='' version='' name='' title='' description='' homepage=''
suite=stable component=main deb_archs='' rpm_archs='' pin='' listings=true footer=true footer_version=''
nix_archives='' nix_binaries='' nix_url_base=''
packslip_project='' packslip_pin='' extra='' import_key=false resign_history=true
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --packages) packages="$2" ;;
        --out) out="$2" ;;
        --base-url) base_url="${2%/}" ;;
        --version) version="$2" ;;
        --name) name="$2" ;;
        --title) title="$2" ;;
        --description) description="$2" ;;
        --homepage) homepage="$2" ;;
        --suite) suite="$2" ;;
        --component) component="$2" ;;
        --deb-architectures) deb_archs="$2" ;;
        --rpm-architectures) rpm_archs="$2" ;;
        --nix-archives) nix_archives="$2" ;;
        --nix-binaries) nix_binaries="$2" ;;
        --nix-url-base) nix_url_base="${2%/}" ;;
        --public-key) pin="$2" ;;
        --directory-listings) listings="$2" ;;
        --footer) footer="$2" ;;
        --footer-version) footer_version="$2" ;;
        --packslip-project) packslip_project="$2" ;;
        --packslip-pin) packslip_pin="$2" ;;
        --extra-site) extra="$2" ;;
        --import-key) import_key="$2" ;;
        --resign-history) resign_history="$2" ;;
        *) usage ;;
    esac
    shift 2
done
check_bool import-key "$import_key"
check_bool resign-history "$resign_history"

# --- Inputs ----------------------------------------------------------------------------------
[ -n "$packages" ] && [ -n "$out" ] && [ -n "$base_url" ] && [ -n "$version" ] && [ -n "$name" ] || usage
[ -d "$packages" ] || die "packages $packages is not a directory"
[ ! -e "$out" ] && [ ! -L "$out" ] || die "out $out already exists"
check_base_url base-url "$base_url"
check_name name "$name"
check_word suite "$suite"
check_word component "$component"
check_bool directory-listings "$listings"
check_bool footer "$footer"
case "$footer_version" in
    *[!A-Za-z0-9.+-]*) die "footer-version must match [A-Za-z0-9.+-]*, not '$footer_version'" ;;
esac
case "$version" in
    '' | *[!A-Za-z0-9.+~_-]*) die "version must match [A-Za-z0-9.+~_-]+, not '$version'" ;;
esac
for a in $deb_archs; do check_word deb-architectures "$a"; done
for a in $rpm_archs; do check_word rpm-architectures "$a"; done
[ -z "$homepage" ] || check_url homepage "$homepage"
[ -z "$nix_archives$nix_binaries$nix_url_base" ] || {
    [ -n "$nix_archives" ] && [ -n "$nix_binaries" ] && [ -n "$nix_url_base" ] ||
        die "nix-archives, nix-binaries and nix-url-base must be set together"
}
if [ -n "$nix_archives$nix_binaries$nix_url_base" ]; then
    check_url nix-url-base "$nix_url_base"
    case "$nix_url_base" in *'"'* | *\\* | *'$'* | *'`'* | *' '*) die "nix-url-base contains characters unsafe in a Nix string" ;; esac
fi
[ -z "$extra" ] || [ -d "$extra" ] || die "extra-site $extra is not a directory"
case "$title" in
    *[[:cntrl:]]*) die "title must be one line without control characters (it goes into $name.repo and the APT Release file)" ;;
esac
case "$packslip_project$packslip_pin" in
    *[[:cntrl:]]*) die "packslip inputs may not contain control characters" ;;
esac
[ -z "$packslip_pin" ] || [ -n "$packslip_project" ] || die "--packslip-pin needs --packslip-project"
if [ -n "$packslip_project" ]; then
    printf '%s\n' "$packslip_project" | LC_ALL=C grep -Eq '^[a-z0-9.-]+(/[A-Za-z0-9._-]+)+$' ||
        die "packslip-project must match [a-z0-9.-]+(/[A-Za-z0-9._-]+)+, not '$packslip_project'"
    case "$packslip_project" in
        */../* | ../* | */.. | ..) die "packslip-project may not contain a '..' path segment" ;;
    esac
fi
if [ -n "$packslip_pin" ]; then
    printf '%s\n' "$packslip_pin" | LC_ALL=C grep -Eq '^ps1_[a-z2-7]{26}$' ||
        die "packslip-pin must match ps1_ followed by 26 lowercase base32 characters"
fi
[ -n "$title" ] || title="$name package repositories"
require_tools gzip sed awk find sha256sum sort
if [ -n "$nix_archives" ]; then
    require_tools tar
    case "$nix_archives" in *.tar.xz*) require_tools xz ;; esac
fi

# --- Read every package ----------------------------------------------------------------------
work=''
make_tmpdir work
index="$work/index"   # kind<TAB>name<TAB>version<TAB>arch<TAB>sha256<TAB>path, one per package
: > "$index"
odd="$(find "$packages" ! -type f ! -type d | LC_ALL=C sort | head -n 1)"
[ -z "$odd" ] || die "packages $packages holds $odd, which is not a regular file (symbolic links are refused)"
find "$packages" -type f | LC_ALL=C sort > "$work/files"
[ -s "$work/files" ] || die "packages $packages holds no files"
while IFS= read -r f; do
    case "$f" in *"	"*) die "$f: tabs in file names are not supported" ;; esac
    meta="$(pkg_meta "$f")"
    sum="$(sha256sum "$f" | cut -d' ' -f1)"
    key="$(printf '%s' "$meta" | cut -f1-4)"
    # Same name+version+arch twice: fine if the bytes match (the same file fetched twice).
    prev="$(awk -F'\t' -v k="$key" '$1"\t"$2"\t"$3"\t"$4 == k { print $5 "\t" $6; exit }' "$index")"
    if [ -n "$prev" ]; then
        [ "${prev%%	*}" = "$sum" ] ||
            die "$f and ${prev#*	} are both $(printf '%s' "$key" | tr '\t' ' ') but differ"
        continue
    fi
    printf '%s\t%s\t%s\n' "$meta" "$sum" "$f" >> "$index"
done < "$work/files"

has_deb=false has_rpm=false
grep -q '^deb	' "$index" && has_deb=true
grep -q '^rpm	' "$index" && has_rpm=true
if [ "$has_deb" = true ]; then require_tools apt-ftparchive dpkg-deb; fi
if [ "$has_rpm" = true ]; then require_tools createrepo_c rpm; fi

# has_release KIND ARCH: true when a VERSION package of KIND is built for exactly ARCH (any arch
# when ARCH is empty). An all/noarch package does not stand in for amd64: the assertion is that
# users of ARCH get the release's binaries. List all or noarch to require those.
has_release() {
    while IFS='	' read -r _hk _hn _hv _ha _hs _hp; do
        [ "$_hk" = "$1" ] || continue
        [ -z "$2" ] || [ "$_ha" = "$2" ] || continue
        pkg_matches_version "$_hk" "$_hv" "$version" && return 0
    done < "$index"
    return 1
}
if [ -z "$deb_archs$rpm_archs" ]; then
    has_release deb '' || has_release rpm '' || die "no package of version $version among $packages"
fi
for a in $deb_archs; do has_release deb "$a" || die "no $a .deb of version $version among $packages"; done
for a in $rpm_archs; do has_release rpm "$a" || die "no $a .rpm of version $version among $packages"; done

# archs_of KIND REQUIRED DEFAULT: the architectures to publish: those found plus REQUIRED, without
# all/noarch (listed in every architecture). DEFAULT when only all/noarch packages exist.
archs_of() {
    found="$(awk -F'\t' -v k="$1" '$1 == k { print $4 }' "$index")"
    found="$(printf '%s\n%s\n' "$found" "$2" | tr ' ' '\n' | sed '/^$/d; /^all$/d; /^noarch$/d' |
        LC_ALL=C sort -u | tr '\n' ' ')"
    found="${found% }"
    printf '%s\n' "${found:-$3}"
}

# --- Signing ---------------------------------------------------------------------------------
# --import-key: the fail-closed import of REPO_SIGNING_KEY against the pin (signing.sh), in this
# same process, so the key and the build share one GNUPGHOME and one container. Otherwise, a
# key already in GNUPGHOME signs; only an explicit GNUPGHOME counts, because on a developer's
# machine ~/.gnupg holds personal keys.
fpr=
if [ "$import_key" = true ]; then
    require_tools gpg
    [ -n "$pin" ] || die "--import-key needs --public-key"
    fpr="$(REPO_SIGNING_KEY="$signing_key"; signing_import "$pin")"
elif [ -n "${GNUPGHOME:-}" ] && command -v gpg > /dev/null 2>&1; then
    fpr="$(secret_fpr)"
fi
signing_key=''
if [ -n "$fpr" ]; then
    require_tools gpg gpgv
    [ -n "$pin" ] || die "gpg holds a signing key but no public-key was given"
    [ "$(pin_fpr "$pin")" = "$fpr" ] || die "the signing key $fpr is not the key of public-key $pin"
    if [ "$has_rpm" = true ]; then require_tools rpmsign rpmkeys; fi
fi
to_sign="$work/to-sign"   # the metadata files lib/site-seal.sh signs, once the site is laid out
: > "$to_sign"

mkdir -p "$out"
[ -z "$fpr" ] || cp "$pin" "$out/$name.asc"

# --- Optional Nix flake ----------------------------------------------------------------------
if [ -n "$nix_archives" ]; then
    "$lib/nix-flake.sh" --out "$out/nix" --name "$name" --version "$version" \
        --url-base "$nix_url_base" --binaries "$nix_binaries" --archives "$nix_archives"
fi

# --- APT: one suite with one component -------------------------------------------------------
deb_line=
deb_list=
if [ "$has_deb" = true ]; then
    deb_list="$(archs_of deb "$deb_archs" "amd64 arm64")"
    deb="$out/deb"
    while IFS='	' read -r k n v a _s p; do
        [ "$k" = deb ] || continue
        dir="$deb/pool/$component/$(pool_prefix "$n")/$n"
        mkdir -p "$dir"
        dest="$dir/${n}_${v#*:}_$a.deb"
        # Pool file names leave out the epoch, as Debian's do: two versions that differ only in it
        # would share one file.
        [ ! -e "$dest" ] || die "$p and another .deb are both ${dest##*/}: versions that differ only in their epoch can't both be published"
        cp "$p" "$dest"
    done < "$index"
    (
        cd "$deb"
        for a in $deb_list; do
            dir="dists/$suite/$component/binary-$a"
            mkdir -p "$dir"
            apt-ftparchive --arch "$a" packages "pool/$component" > "$dir/Packages"
            gzip -9n < "$dir/Packages" > "$dir/Packages.gz"
        done
        apt-ftparchive \
            -o "APT::FTPArchive::Release::Origin=$name" \
            -o "APT::FTPArchive::Release::Label=$name" \
            -o "APT::FTPArchive::Release::Suite=$suite" \
            -o "APT::FTPArchive::Release::Codename=$suite" \
            -o "APT::FTPArchive::Release::Architectures=$deb_list" \
            -o "APT::FTPArchive::Release::Components=$component" \
            -o "APT::FTPArchive::Release::Description=$title" \
            release "dists/$suite" > Release.tmp
        mv Release.tmp "dists/$suite/Release"
    )
    if [ -n "$fpr" ]; then
        printf 'deb/dists/%s/Release\n' "$suite" >> "$to_sign"
        deb_line="deb [signed-by=/etc/apt/keyrings/$name.asc] $base_url/deb $suite $component"
    else
        deb_line="deb [trusted=yes] $base_url/deb $suite $component"
    fi
    printf '%s\n' "$deb_line" > "$deb/$name.list"
fi

# --- DNF: one repository per architecture, rpm/$basearch -------------------------------------
rpm_list=
if [ "$has_rpm" = true ]; then
    rpm_list="$(archs_of rpm "$rpm_archs" "x86_64 aarch64")"
    if [ -n "$fpr" ]; then
        # Earlier releases' files that don't verify against the pin (from before signing, by a
        # revoked subkey, or put on a release by anyone who can edit it) are re-signed, or refused.
        hist_db=''
        rpm_db_with_pin "$pin" hist_db
        while IFS='	' read -r k n v pa _s p; do
            [ "$k" = rpm ] || continue
            if pkg_matches_version rpm "$v" "$version"; then continue; fi
            if rpm_verifies "$pin" "$p" "$hist_db"; then continue; fi
            [ "$resign_history" = true ] ||
                die "$p ($n $v $pa) is from an earlier release and not signed by public-key $pin; with resign-history false it is not re-signed"
            warning "re-signing $p ($n $v $pa): an earlier release's .rpm that is not signed by public-key $pin"
        done < "$index"
    fi
    for a in $rpm_list; do
        dir="$out/rpm/$a"
        mkdir -p "$dir"
        while IFS='	' read -r k n v pa _s p; do
            [ "$k" = rpm ] || continue
            [ "$pa" = "$a" ] || [ "$pa" = noarch ] || continue
            cp "$p" "$dir/$n-$v.$pa.rpm"
        done < "$index"
        if [ -n "$fpr" ]; then
            # Already-signed files (this release's, from sign-rpm) stay byte-identical; earlier
            # releases' files, signed before the key existed or by a rotated subkey, are re-signed.
            set -- "$dir"/*.rpm
            sign_rpm "$pin" "$@"
        fi
        createrepo_c --quiet --compatibility "$dir" > /dev/null
        [ -z "$fpr" ] || printf 'rpm/%s/repodata/repomd.xml\n' "$a" >> "$to_sign"
    done
    if [ -n "$fpr" ]; then
        rpm_check="gpgcheck=1
repo_gpgcheck=1
gpgkey=$base_url/$name.asc"
    else
        rpm_check="gpgcheck=0
repo_gpgcheck=0"
    fi
    cat > "$out/rpm/$name.repo" << EOF
[$name]
name=$title
baseurl=$base_url/rpm/\$basearch
enabled=1
$rpm_check
EOF
fi

# --- Seal ------------------------------------------------------------------------------------
# InRelease, Release.gpg and every repomd.xml.asc: lib/site-seal.sh signs the files named in the
# list with the key already in GNUPGHOME and checks each signature against the pin.
if [ -n "$fpr" ]; then
    "$lib/site-seal.sh" --site "$out" --to-sign "$to_sign" --public-key "$pin" --import-key false
fi

# --- The landing page ------------------------------------------------------------------------
# Every caller-provided string is HTML-escaped. The install commands name the packages of VERSION.
esc() { printf '%s' "$1" | html_escape; }
page_head() {
    printf '<!doctype html>\n<html lang="en">\n  <head>\n'
    printf '    <meta charset="utf-8">\n'
    printf '    <meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '    <meta name="color-scheme" content="light dark">\n'
    printf '    <title>%s</title>\n' "$1"
    cat <<'CSS'
    <style>
      :root {
        color-scheme: light dark;
        --bg: #f8fafc; --fg: #18212f; --muted: #536174; --border: #d7dee8;
        --surface: #fff; --code: #eef2f7; --accent: #175cd3; --accent-fg: #fff;
        --signed-fg: #166534; --signed-bg: #dcfce7; --signed-border: #86efac;
        --unsigned-fg: #854d0e; --unsigned-bg: #fef3c7; --unsigned-border: #fbbf24;
      }
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme=light]) {
          --bg: #111827; --fg: #e5eaf2; --muted: #aab6c7; --border: #344154;
          --surface: #1b2636; --code: #121c2a; --accent: #8ab4ff; --accent-fg: #101827;
          --signed-fg: #86efac; --signed-bg: #14532d; --signed-border: #4ade80;
          --unsigned-fg: #fde68a; --unsigned-bg: #78350f; --unsigned-border: #fbbf24;
        }
      }
      :root[data-theme=dark] {
        --bg: #111827; --fg: #e5eaf2; --muted: #aab6c7; --border: #344154;
        --surface: #1b2636; --code: #121c2a; --accent: #8ab4ff; --accent-fg: #101827;
        --signed-fg: #86efac; --signed-bg: #14532d; --signed-border: #4ade80;
        --unsigned-fg: #fde68a; --unsigned-bg: #78350f; --unsigned-border: #fbbf24;
      }
      * { box-sizing: border-box; }
      body {
        max-width: 80rem; margin: 0 auto; padding: clamp(1rem, 3vw, 2.5rem) clamp(.75rem, 4vw, 3rem);
        background: var(--bg); color: var(--fg);
        font: 1rem/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      }
      a { color: var(--accent); }
      a:focus-visible, button:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
      button {
        border: 1px solid var(--border); border-radius: 6px; padding: .25rem .5rem;
        background: var(--surface); color: var(--fg); font: inherit;
      }
      .top { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
      h1 { margin: 0; font-size: clamp(1.7rem, 5vw, 2.25rem); line-height: 1.2; }
      .theme, .badge, .browse a {
        border: 1px solid var(--border); border-radius: 999px;
        background: var(--surface); color: var(--fg); padding: .3rem .7rem;
      }
      .theme { cursor: pointer; white-space: nowrap; }
      .theme, .copy { display: none; }
      .js .theme, .js .copy { display: inline-block; }
      .copy[hidden] { display: none; }
      .intro { margin: .65rem 0 0; color: var(--muted); }
      .badges { display: flex; flex-wrap: wrap; gap: .5rem; margin: .8rem 0 1.4rem; }
      .badge { font-size: .85rem; text-decoration: none; }
      .signed { color: var(--signed-fg); background: var(--signed-bg); border-color: var(--signed-border); }
      .unsigned { color: var(--unsigned-fg); background: var(--unsigned-bg); border-color: var(--unsigned-border); }
      h2 { margin: 1.5rem 0 .6rem; font-size: 1.2rem; }
      .card { padding: clamp(.75rem, 2vw, 1.25rem); border: 1px solid var(--border); border-radius: 12px; background: var(--surface); }
      .card + .card { margin-top: 1rem; }
      .card-head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
      .card h2 { margin: 0; }
      .cmd { margin: .75rem 0 0; }
      .note { margin: .6rem 0 0; color: var(--muted); font-size: .9rem; }
      /* Long commands wrap (at spaces first) instead of scrolling; a wrapped command's
         continuation is indented. Copy still copies the commands as written. */
      pre {
        margin: 0; padding: clamp(.6rem, 2vw, 1rem); white-space: pre-wrap; overflow-wrap: break-word;
        border: 1px solid var(--border); border-radius: 8px; background: var(--code);
        font: .88rem/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      }
      .ln { display: block; padding-left: 2ch; text-indent: -2ch; }
      @media (max-width: 40rem) { pre { font-size: .8rem; } }
      .copy { cursor: pointer; }
      code { word-break: break-all; }
      .fpr {
        display: block; margin: .5rem 0 1.25rem; padding: .75rem 1rem;
        border: 1px solid var(--border); border-radius: 8px; background: var(--surface);
        font: .9rem/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      }
      .browse { display: flex; flex-wrap: wrap; gap: .5rem; }
      .browse a { text-decoration: none; font-size: .9rem; }
      .browse-row { display: flex; align-items: center; flex-wrap: wrap; gap: .5rem; margin-top: 1rem; }
      .listing { list-style: none; margin: .75rem 0 0; padding: 0; border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
      .listing li + li { border-top: 1px solid var(--border); }
      .listing a { display: block; padding: .55rem .8rem; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; text-decoration: none; }
      .listing a:hover, .browse a:hover { background: var(--code); }
      footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--muted); text-align: center; font-size: .85rem; }
      @media (prefers-reduced-motion: no-preference) {
        a, button { transition: background-color .12s ease, color .12s ease; }
      }
    </style>
    <script>
      (function () {
        var key = 'pkg-pages-theme';
        var mode = 'auto';
        try { mode = localStorage.getItem(key) || 'auto'; } catch (_) {}
        if (mode !== 'light' && mode !== 'dark') mode = 'auto';
        document.documentElement.classList.add('js');
        function apply() {
          if (mode === 'auto') document.documentElement.removeAttribute('data-theme');
          else document.documentElement.dataset.theme = mode;
        }
        apply();
        document.addEventListener('DOMContentLoaded', function () {
          var theme = document.getElementById('theme');
          function label() {
            theme.textContent = mode === 'auto' ? '◐ Auto' : mode === 'light' ? '☀ Light' : '☾ Dark';
            theme.setAttribute('aria-label', 'Theme: ' + mode + '. Activate to change theme.');
          }
          theme.addEventListener('click', function () {
            mode = mode === 'auto' ? 'light' : mode === 'light' ? 'dark' : 'auto';
            apply(); label();
            try { localStorage.setItem(key, mode); } catch (_) {}
          });
          label();
          document.querySelectorAll('.card').forEach(function (card) {
            var button = card.querySelector('.copy');
            var pre = card.querySelector('.cmd pre');
            if (!pre) return;
            var text = pre.textContent;
            // One block per command, so a wrapped command's continuation can be indented.
            pre.textContent = '';
            text.split('\n').forEach(function (line) {
              var span = document.createElement('span');
              span.className = 'ln';
              span.textContent = line;
              pre.appendChild(span);
            });
            if (!navigator.clipboard || !button) { if (button) button.hidden = true; return; }
            button.addEventListener('click', function () {
              navigator.clipboard.writeText(text).then(function () {
                button.textContent = 'Copied';
                setTimeout(function () { button.textContent = 'Copy'; }, 1500);
              }).catch(function () {});
            });
          });
        });
      })();
    </script>
  </head>
  <body>
CSS
}
page_footer() {
    [ "$footer" = true ] || return 0
    printf '    <footer>Published with <a href="https://github.com/ziptie-soft/pkg-pages">pkg-pages</a>%s</footer>\n' "$h_footer_version"
}
names="$(while IFS='	' read -r k n v _a _s _p; do
    pkg_matches_version "$k" "$v" "$version" && printf '%s\n' "$n"
done < "$index" | LC_ALL=C sort -u | tr '\n' ' ')"
names="${names% }"
h_title="$(esc "$title")"
h_name="$(esc "$name")"
h_base="$(esc "$base_url")"
h_names="$(esc "$names")"
h_packslip_project="$(esc "$packslip_project")"
h_packslip_pin="$(esc "$packslip_pin")"
if [ -z "$footer_version" ] && [ -f "$lib/../version.txt" ]; then
    IFS= read -r footer_version < "$lib/../version.txt" || true
    footer_version="$(printf '%s' "$footer_version" | tr -d '[:space:]')"
    case "$footer_version" in '' | *[!A-Za-z0-9.+-]*) footer_version='' ;; esac
fi
h_footer_version=''
[ -z "$footer_version" ] || h_footer_version="$(esc " $footer_version")"
{
    page_head "$h_title"
    printf '    <header>\n      <div class="top"><h1>%s</h1><button type="button" id="theme" class="theme" aria-label="Change theme">◐ Auto</button></div>\n' "$h_title"
    [ -z "$description" ] || printf '      <p class="intro">%s</p>\n' "$(esc "$description")"
    printf '      <div class="badges"><span class="badge">v%s</span>' "$(esc "$version")"
    if [ -n "$fpr" ]; then
        printf '<span class="badge signed">signed</span>'
    else
        printf '<span class="badge unsigned">unsigned</span>'
    fi
    [ -z "$homepage" ] || printf '<a class="badge" href="%s">%s</a>' "$(esc "$homepage")" "$(esc "$homepage")"
    printf '</div>\n    </header>\n'
    if [ -n "$fpr" ]; then
        printf '    <p>Packages and repository metadata are signed with <a href="%s.asc">%s.asc</a>.</p>\n' "$h_name" "$h_name"
        printf '    <p>Fingerprint:</p>\n    <code class="fpr">%s</code>\n' "$fpr"
    else
        printf '    <p>These repositories are unsigned.</p>\n'
    fi
    if [ "$has_rpm" = true ]; then
        printf '    <section class="card">\n      <div class="card-head"><h2>DNF (Fedora, RHEL)</h2><button type="button" class="copy">Copy</button></div>\n'
        printf '      <div class="cmd"><pre>sudo curl -fsSLo /etc/yum.repos.d/%s.repo %s/rpm/%s.repo\nsudo dnf install %s</pre></div>\n' "$h_name" "$h_base" "$h_name" "$h_names"
        printf '    </section>\n'
    fi
    if [ "$has_deb" = true ]; then
        printf '    <section class="card">\n      <div class="card-head"><h2>APT (Debian, Ubuntu)</h2><button type="button" class="copy">Copy</button></div>\n      <div class="cmd"><pre>'
        if [ -n "$fpr" ]; then
            printf 'sudo install -d -m 0755 /etc/apt/keyrings\n'
            printf 'sudo curl -fsSLo /etc/apt/keyrings/%s.asc %s/%s.asc\n' "$h_name" "$h_base" "$h_name"
        fi
        printf 'sudo curl -fsSLo /etc/apt/sources.list.d/%s.list %s/deb/%s.list\n' "$h_name" "$h_base" "$h_name"
        printf 'sudo apt update\nsudo apt install %s</pre></div>\n' "$h_names"
        printf '    </section>\n'
    fi
    if [ -n "$packslip_project" ]; then
        printf '    <section class="card">\n      <div class="card-head"><h2>packslip and mise (CLI only)</h2><button type="button" class="copy">Copy</button></div>\n'
        printf '      <div class="cmd"><pre>packslip install %s' "$h_packslip_project"
        [ -z "$packslip_pin" ] || printf ' --pin %s' "$h_packslip_pin"
        printf '\nmise use -g packslip:%s</pre></div>\n' "$h_packslip_project"
        printf '      <p class="note">Installs the release\047s signed packslip bundle from the GitHub release; packslip checks the signature before it installs.</p>\n'
        printf '    </section>\n'
    fi
    if [ -n "$nix_archives" ]; then
        nix_systems="$(printf '%s\n' "$nix_archives" | sed 's/=.*//' | tr '\n' ' ')"
        nix_systems="${nix_systems% }"
        printf '    <section class="card">\n      <div class="card-head"><h2>Nix</h2><button type="button" class="copy">Copy</button></div>\n'
        printf '      <div class="cmd"><pre>nix profile install %s/nix/flake.tar.gz\nnix run %s/nix/flake.tar.gz</pre></div>\n' "$h_base" "$h_base"
        printf '      <p class="note">Prebuilt binaries for %s, pinned by SHA-256. The flake itself is not signed.</p>\n' "$(esc "$nix_systems")"
        printf '    </section>\n'
    fi
    printf '    <div class="browse-row"><span>Browse:</span><nav class="browse" aria-label="Browse repositories">'
    [ "$has_rpm" = false ] || printf '<a href="rpm/">rpm/</a>'
    [ "$has_deb" = false ] || printf '<a href="deb/">deb/</a>'
    [ -z "$nix_archives" ] || printf '<a href="nix/">nix/</a>'
    printf '</nav></div>\n'
    page_footer
    printf '  </body>\n</html>\n'
} > "$out/index.html"
: > "$out/.nojekyll"

# --- extra-site ------------------------------------------------------------------------------
if [ -n "$extra" ]; then
    if [ -n "$(find "$extra" -type l)" ]; then die "extra-site $extra holds symbolic links"; fi
    (cd "$extra" && find . -type f) > "$work/extra"
    while IFS= read -r f; do
        f="${f#./}"
        [ ! -e "$out/$f" ] || die "extra-site $extra/$f would overwrite $f of the repositories"
    done < "$work/extra"
    cp -R "$extra/." "$out/"
fi

# --- Directory listings (Pages serves none); existing index.html files are kept ---------------
if [ "$listings" = true ]; then
    find "$out" -mindepth 1 -type d | LC_ALL=C sort | while IFS= read -r dir; do
        [ ! -e "$dir/index.html" ] || continue
        rel="$(esc "${dir#"$out"/}")"
        {
            page_head "Index of /$rel/"
            printf '    <header><div class="top"><h1>Index of /%s/</h1><button type="button" id="theme" class="theme" aria-label="Change theme">◐ Auto</button></div></header>\n' "$rel"
            printf '    <ul class="listing">\n      <li><a href="../">../</a></li>\n'
            for entry in "$dir"/*; do
                [ -e "$entry" ] || continue
                e="${entry##*/}"
                [ "$e" != index.html ] || continue
                [ ! -d "$entry" ] || e="$e/"
                e="$(esc "$e")"
                printf '      <li><a href="%s">%s</a></li>\n' "$e" "$e"
            done
            printf '    </ul>\n'
            page_footer
            printf '  </body>\n</html>\n'
        } > "$dir/index.html"
    done
fi

# --- Self-check ------------------------------------------------------------------------------
# The SHA-256 of every archive is in the flake: nix-flake.sh wrote it, so this guards the writer.
if [ -n "$nix_archives" ]; then
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        archive=${entry#*=}
        file=${archive##*/}
        sum=$(sha256sum "$archive" | cut -d' ' -f1)
        if ! grep -Fq "$nix_url_base/$file" "$out/nix/flake.nix" || ! grep -Fq "$sum" "$out/nix/flake.nix"; then
            die "self-check: SHA-256 for $file is missing from the Nix flake"
        fi
    done <<EOF
$nix_archives
EOF
fi
# What a client will see (lib/site-check.sh): the files exist, the release is listed, and the
# signatures verify against the pin rather than against whatever key did the signing.
"$lib/site-check.sh" --site "$out" --name "$name" --version "$version" --suite "$suite" \
    --component "$component" --deb-architectures "$deb_archs" ${fpr:+--public-key "$pin"}

n_deb="$(grep -c '^deb	' "$index" || true)"
n_rpm="$(grep -c '^rpm	' "$index" || true)"
log "wrote $out for $name $version: $n_deb .deb, $n_rpm .rpm, ${fpr:+signed by }${fpr:-unsigned}"
set_output site-path "$out"
if [ -n "$fpr" ]; then
    set_output signed true
    set_output fingerprint "$fpr"
    set_env PKG_PAGES_SIGNED true
    set_env PKG_PAGES_FINGERPRINT "$fpr"
else
    set_output signed false
    set_output fingerprint ''
    set_env PKG_PAGES_SIGNED false
fi

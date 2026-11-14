#!/bin/sh
# Build the APT and DNF repositories site from a directory of .deb and .rpm files, ready to be
# served by GitHub Pages (or any static file server). Rewritten from SkeLLLa/star-forge's
# packaging/ci/pages-repo.sh to read each package's own metadata instead of matching file names.
# Holds no key and signs nothing: it lays the site out, writes the list of metadata files to sign
# (lib/site-seal.sh signs them) and the checks of lib/site-check.sh come after.
#
# Usage:
#   site-build.sh --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]...
#
# Required:
#   --packages DIR          this release's .deb and .rpm files (searched recursively); any other
#                           file, or a symbolic link, is an error
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
#   --tag TAG               this release's tag (letters, digits and . _ + / -). Given: the site
#                           lists its packages in pkg-pages.tsv, each under its release tag
#   --history DIR           earlier releases' packages, laid out beside this release's; needs --tag
#                           and --history-map, and every file must be in the map
#   --history-map FILE      lines of <tag><TAB><sha256><TAB><path><TAB><site|release>: the tag of
#                           each history file, found by its SHA-256 (the order of the tags is the
#                           order of the manifest)
#   --keyring DIR           holds exactly one <name>-keyring_<version>_all.deb (build-keyring.sh).
#                           Needs --public-key. It is published with the packages, the .list uses
#                           it as the APT key and the landing page installs it first. A history
#                           copy of the same version is kept instead. Without .deb files, ignored.
#   --to-sign FILE          where to write the list of files to sign (default <out>.to-sign; it
#                           must not exist). It is empty when the site is unsigned.
#
# Published architectures: those of the packages, plus the required ones. all/noarch packages
# are listed in every one of them; with only all/noarch packages, amd64 arm64 / x86_64 aarch64.
#   --public-key FILE       the pin. When it exists the site is laid out signed ([signed-by],
#                           gpgcheck=1, <name>.asc, and with .rpm files rpm/RPM-GPG-KEY-<name>:
#                           the pin without revoked or expired subkeys, which the .repo names
#                           in gpgkey= because rpm 4.16 can't import a revoked subkey), every .rpm must already verify against it, and
#                           the to-sign list names the files site-seal.sh signs. When it doesn't
#                           exist the site is unsigned ([trusted=yes], gpgcheck=0).
#   --directory-listings true|false  an index.html in every directory (default true)
#   --footer true|false     add a pkg-pages footer to the landing page and listings (default true)
#   --footer-version V      the pkg-pages version the footer names (default: version.txt beside lib/)
#   --packslip-project PROJECT  show packslip and mise install commands for this project (default off)
#   --packslip-pin PIN      optional packslip signer pin (ps1_ followed by 26 base32 characters)
#   --extra-site DIR        merged into the site root; may not overwrite a file of the site
#
# A package named <name>-keyring is refused (.deb and .rpm alike): the name is for the keyring.
#
# pkg-pages.tsv, when --tag is given: tab-separated, LF line endings:
#   #pkg-pages-manifest<TAB>1<TAB><name><TAB><primary fingerprint of the pin, or ->
#   release<TAB><tag><TAB><sha256><TAB><path>      every package file, noarch copies included
#   keyring<TAB>-<TAB><sha256><TAB><path>          the keyring package(s), last
# The current tag first, then the history tags in map order, each sorted by path. A path is the
# package file's own (deb/pool/... or rpm/<arch>/...), so it holds the ~ of a pre-release version.
#
# Tools: apt-ftparchive and dpkg-deb when there are .deb files; createrepo_c and rpm when there
# are .rpm files; gpg, gpgv and rpmkeys when the pin exists; gzip, sed, awk, find, sha256sum.
#
# Outputs (GITHUB_OUTPUT): site-path, to-sign, signed=true|false (whether the layout is signed;
# the signatures themselves come from site-seal.sh). Progress goes to stderr.
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"
# shellcheck source=packages.sh
. "$lib/packages.sh"
# shellcheck source=signing.sh
. "$lib/signing.sh"

usage() {
    die "usage: $0 --packages DIR --out DIR --base-url URL --version VERSION --name NAME [OPTION]... (see the header of $0)"
}

packages='' out='' base_url='' version='' name='' title='' description='' homepage=''
suite=stable component=main deb_archs='' rpm_archs='' pin='' listings=true footer=true footer_version=''
nix_archives='' nix_binaries='' nix_url_base=''
packslip_project='' packslip_pin='' extra='' tag='' history='' history_map='' keyring='' to_sign=''
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
        --tag) tag="$2" ;;
        --history) history="$2" ;;
        --history-map) history_map="$2" ;;
        --keyring) keyring="$2" ;;
        --to-sign) to_sign="$2" ;;
        *) usage ;;
    esac
    shift 2
done

# --- Inputs ----------------------------------------------------------------------------------
[ -n "$packages" ] && [ -n "$out" ] && [ -n "$base_url" ] && [ -n "$version" ] && [ -n "$name" ] || usage
[ -d "$packages" ] || die "packages $packages is not a directory"
[ ! -e "$out" ] && [ ! -L "$out" ] || die "out $out already exists"
[ -n "$to_sign" ] || to_sign="$out.to-sign"
[ ! -e "$to_sign" ] && [ ! -L "$to_sign" ] || die "to-sign $to_sign already exists"
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
if [ -n "$tag" ]; then
    case "$tag" in -) die "tag may not be '-'" ;; esac
    printf '%s\n' "$tag" | LC_ALL=C grep -Eq '^[A-Za-z0-9._+/-]+$' ||
        die "tag must match [A-Za-z0-9._+/-]+, not '$tag'"
fi
if [ -n "$history$history_map" ]; then
    [ -n "$history" ] && [ -n "$history_map" ] || die "--history and --history-map must be given together"
    [ -n "$tag" ] || die "--history needs --tag"
    [ -d "$history" ] || die "history $history is not a directory"
    [ -f "$history_map" ] || die "history-map $history_map is not a file"
fi
[ -z "$keyring" ] || [ -d "$keyring" ] || die "keyring $keyring is not a directory"
[ -n "$title" ] || title="$name package repositories"
require_tools gzip sed awk find sha256sum sort
if [ -n "$nix_archives" ]; then
    require_tools tar
    case "$nix_archives" in *.tar.xz*) require_tools xz ;; esac
fi

# --- The pin ---------------------------------------------------------------------------------
# The site is laid out signed when the pin exists. A key is never needed here, so gpg gets a
# private, empty home whatever GNUPGHOME the caller holds.
signed=false fpr=
if [ -n "$pin" ] && [ -e "$pin" ]; then
    signed=true
    require_tools gpg gpgv
    GNUPGHOME=''
    make_tmpdir GNUPGHOME
    chmod 700 "$GNUPGHOME"
    export GNUPGHOME
    fpr="$(pin_fpr "$pin")"
fi
[ -z "$keyring" ] || [ "$signed" = true ] || die "--keyring needs --public-key: the keyring package carries the pin"

# --- Read every package ----------------------------------------------------------------------
work=''
make_tmpdir work
index="$work/index"   # kind<TAB>name<TAB>version<TAB>arch<TAB>sha256<TAB>path<TAB>tag, one per package
: > "$index"
# The history map: tag<TAB>sha256<TAB>path<TAB>origin. Every line is checked, none is trusted
# for more than the tag of the file with that SHA-256.
: > "$work/map"
if [ -n "$history_map" ]; then
    n=0
    while IFS='	' read -r mtag msum _mpath morigin mextra || [ -n "$mtag" ]; do
        n=$((n + 1))
        [ -z "$mextra" ] && [ -n "$morigin" ] || die "history-map $history_map line $n: expected <tag> <sha256> <path> <origin>"
        printf '%s\n' "$mtag" | LC_ALL=C grep -Eq '^[A-Za-z0-9._+/-]+$' || die "history-map line $n: bad tag '$mtag'"
        printf '%s\n' "$msum" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || die "history-map line $n: bad SHA-256 '$msum'"
        case "$morigin" in site | release) ;; *) die "history-map line $n: origin must be site or release, not '$morigin'" ;; esac
        printf '%s\t%s\n' "$mtag" "$msum" >> "$work/map"
    done < "$history_map"
fi

# add_files DIR LABEL ORIGIN: index every file below DIR. ORIGIN is current (this release's, tagged
# --tag) or history (tagged by SHA-256 through the map).
add_files() {
    _ad="$1" _al="$2" _ao="$3"
    _odd="$(find "$_ad" ! -type f ! -type d | LC_ALL=C sort | head -n 1)"
    [ -z "$_odd" ] || die "$_al $_ad holds $_odd, which is not a regular file (symbolic links are refused)"
    find "$_ad" -type f | LC_ALL=C sort > "$work/files.$_ao"
    if [ "$_ao" = current ]; then [ -s "$work/files.$_ao" ] || die "$_al $_ad holds no files"; fi
    while IFS= read -r f; do
        case "$f" in *"	"*) die "$f: tabs in file names are not supported" ;; esac
        meta="$(pkg_meta "$f")"
        sum="$(sha256sum "$f" | cut -d' ' -f1)"
        key="$(printf '%s' "$meta" | cut -f1-4)"
        pkind="$(printf '%s' "$meta" | cut -f1)"
        pname="$(printf '%s' "$meta" | cut -f2)"
        ftag="${tag:--}"
        if [ "$pname" = "$name-keyring" ]; then
            # The name is the keyring package's. A history copy of it (the live site's) is the one
            # thing allowed, and only a .deb in the shape build-keyring.sh gives it.
            [ "$_ao" = history ] && [ "$pkind" = deb ] ||
                die "$f is named $name-keyring, which pkg-pages reserves for its keyring package"
            if [ "$(printf '%s' "$meta" | cut -f4)" != all ] ||
                ! printf '%s\n' "$(printf '%s' "$meta" | cut -f3)" | LC_ALL=C grep -Eq '^[0-9]{8}\.[0-9]{6}$'; then
                die "$f is not a $name-keyring package of the form build-keyring.sh writes"
            fi
            if [ -z "$keyring" ]; then
                notice "$f: the keyring package is not published (no --keyring), so the old one is dropped"
                continue
            fi
            ftag=-
        elif [ "$_ao" = history ]; then
            ftag="$(awk -F'\t' -v s="$sum" '$2 == s { print $1; exit }' "$work/map")"
            [ -n "$ftag" ] || die "history file $f (SHA-256 $sum) is not in the history map $history_map"
            [ "$ftag" != - ] || die "history map gives $f the tag '-', which only the keyring has"
        fi
        # Same name+version+arch twice: fine if the bytes match (the same file fetched twice).
        prev="$(awk -F'\t' -v k="$key" '$1"\t"$2"\t"$3"\t"$4 == k { print $5 "\t" $6; exit }' "$index")"
        if [ -n "$prev" ]; then
            [ "${prev%%	*}" = "$sum" ] ||
                die "$f and ${prev#*	} are both $(printf '%s' "$key" | tr '\t' ' ') but differ"
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$meta" "$sum" "$f" "$ftag" >> "$index"
    done < "$work/files.$_ao"
}
add_files "$packages" packages current
[ -z "$history" ] || add_files "$history" history history

# The keyring package: only for APT, so only when there is a .deb. A history copy of the same
# version (the live site's, proven by its manifest) is kept instead of the fresh build.
keyring_pkg=false
if [ -n "$keyring" ]; then
    if grep -q '^deb	' "$index"; then
        _odd="$(find "$keyring" -mindepth 1 | LC_ALL=C sort | head -n 2 | tr '\n' ' ')"
        [ "$(find "$keyring" -mindepth 1 | wc -l)" -eq 1 ] && [ -f "${_odd% }" ] && [ ! -L "${_odd% }" ] ||
            die "keyring $keyring must hold exactly one file, $name-keyring_<version>_all.deb, and nothing else (found: ${_odd:-nothing})"
        kf="${_odd% }"
        case "${kf##*/}" in "$name-keyring"_*_all.deb) ;; *) die "keyring $keyring holds ${kf##*/}, not $name-keyring_<version>_all.deb" ;; esac
        meta="$(pkg_meta "$kf")"
        [ "$(printf '%s' "$meta" | cut -f1,2,4)" = "deb	$name-keyring	all" ] ||
            die "$kf is not the all-architecture .deb of $name-keyring"
        key="$(printf '%s' "$meta" | cut -f1-4)"
        if awk -F'\t' -v k="$key" '$1"\t"$2"\t"$3"\t"$4 == k { f = 1 } END { exit !f }' "$index"; then
            log "keeping the earlier $name-keyring $(printf '%s' "$meta" | cut -f3), the same version as the fresh build"
        else
            printf '%s\t%s\t%s\t-\n' "$meta" "$(sha256sum "$kf" | cut -d' ' -f1)" "$kf" >> "$index"
        fi
        keyring_pkg=true
    else
        notice "no .deb among the packages: no keyring package (it is for APT)"
    fi
fi

has_deb=false has_rpm=false
grep -q '^deb	' "$index" && has_deb=true
grep -q '^rpm	' "$index" && has_rpm=true
if [ "$has_deb" = true ]; then require_tools apt-ftparchive dpkg-deb; fi
if [ "$has_rpm" = true ]; then require_tools createrepo_c rpm; fi
if [ "$signed" = true ] && [ "$has_rpm" = true ]; then
    # A signed site publishes only .rpm files that already verify against the pin (sign-rpm does
    # that, for this release's and for the history's).
    require_tools rpmkeys
    rpm_db=''
    rpm_db_with_pin "$pin" rpm_db
    while IFS='	' read -r k n v pa _s p _t; do
        [ "$k" = rpm ] || continue
        rpm_verifies "$pin" "$p" "$rpm_db" ||
            die "$p ($n $v $pa) is not signed by public-key $pin; sign it first (sign-rpm)"
    done < "$index"
fi

# has_release KIND ARCH: true when a VERSION package of KIND is built for exactly ARCH (any arch
# when ARCH is empty). An all/noarch package does not stand in for amd64: the assertion is that
# users of ARCH get the release's binaries. List all or noarch to require those.
has_release() {
    while IFS='	' read -r _hk _hn _hv _ha _hs _hp _ht; do
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

# --- The layout ------------------------------------------------------------------------------
# to_sign_list: the metadata files site-seal.sh signs (only when signed); sig_paths: the signature
# files it will add, so the directory listings made now name them. packages_lines: tag, SHA-256 and
# path of every package file, for the manifest.
: > "$work/to-sign"
: > "$work/sig-paths"
: > "$work/package-lines"
mkdir -p "$out"
[ "$signed" = false ] || cp "$pin" "$out/$name.asc"

# --- Optional Nix flake ----------------------------------------------------------------------
if [ -n "$nix_archives" ]; then
    "$lib/nix-flake.sh" --out "$out/nix" --name "$name" --version "$version" \
        --url-base "$nix_url_base" --binaries "$nix_binaries" --archives "$nix_archives"
    # The SHA-256 of every archive is in the flake: nix-flake.sh wrote it, so this guards the writer.
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

# --- APT: one suite with one component -------------------------------------------------------
deb_line=
deb_list=
if [ "$has_deb" = true ]; then
    deb_list="$(archs_of deb "$deb_archs" "amd64 arm64")"
    deb="$out/deb"
    while IFS='	' read -r k n v a s p t; do
        [ "$k" = deb ] || continue
        rel="deb/pool/$component/$(pool_prefix "$n")/$n/${n}_${v#*:}_$a.deb"
        dest="$out/$rel"
        mkdir -p "${dest%/*}"
        # Pool file names leave out the epoch, as Debian's do: two versions that differ only in it
        # would share one file.
        [ ! -e "$dest" ] || die "$p and another .deb are both ${dest##*/}: versions that differ only in their epoch can't both be published"
        cp "$p" "$dest"
        printf '%s\t%s\t%s\n' "$t" "$s" "$rel" >> "$work/package-lines"
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
    if [ "$signed" = true ]; then
        printf 'deb/dists/%s/Release\n' "$suite" >> "$work/to-sign"
        printf 'deb/dists/%s/InRelease\ndeb/dists/%s/Release.gpg\n' "$suite" "$suite" >> "$work/sig-paths"
        if [ "$keyring_pkg" = true ]; then
            deb_line="deb [signed-by=/usr/share/keyrings/$name-keyring.asc] $base_url/deb $suite $component"
        else
            deb_line="deb [signed-by=/etc/apt/keyrings/$name.asc] $base_url/deb $suite $component"
        fi
    else
        deb_line="deb [trusted=yes] $base_url/deb $suite $component"
    fi
    printf '%s\n' "$deb_line" > "$deb/$name.list"
fi

# --- DNF: one repository per architecture, rpm/$basearch -------------------------------------
rpm_list=
if [ "$has_rpm" = true ]; then
    rpm_list="$(archs_of rpm "$rpm_archs" "x86_64 aarch64")"
    for a in $rpm_list; do
        dir="$out/rpm/$a"
        mkdir -p "$dir"
        while IFS='	' read -r k n v pa s p t; do
            [ "$k" = rpm ] || continue
            [ "$pa" = "$a" ] || [ "$pa" = noarch ] || continue
            cp "$p" "$dir/$n-$v.$pa.rpm"
            printf '%s\t%s\t%s\n' "$t" "$s" "rpm/$a/$n-$v.$pa.rpm" >> "$work/package-lines"
        done < "$index"
        createrepo_c --quiet --compatibility "$dir" > /dev/null
        if [ "$signed" = true ]; then
            printf 'rpm/%s/repodata/repomd.xml\n' "$a" >> "$work/to-sign"
            printf 'rpm/%s/repodata/repomd.xml.asc\n' "$a" >> "$work/sig-paths"
        fi
    done
    if [ "$signed" = true ]; then
        # dnf's key: the pin without its revoked and expired subkeys, which rpm 4.16 can import.
        pin_rpm_key "$pin" "$out/rpm/RPM-GPG-KEY-$name"
        rpm_check="gpgcheck=1
repo_gpgcheck=1
gpgkey=$base_url/rpm/RPM-GPG-KEY-$name"
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

# --- The manifest ----------------------------------------------------------------------------
# What this site vouches for: every package file by SHA-256, under the tag of its release. Signed
# (by site-seal.sh) it is what the next run takes the earlier releases from.
if [ -n "$tag" ]; then
    {
        { printf '%s\n' "$tag"; awk -F'\t' '{ print $1 }' "$work/map"; } | awk '$0 != "-" && !seen[$0]++'
    } > "$work/tag-order"
    {
        printf '#pkg-pages-manifest\t1\t%s\t%s\n' "$name" "${fpr:--}"
        while IFS= read -r t; do
            awk -F'\t' -v t="$t" '$1 == t { print $3 "\t" $2 }' "$work/package-lines" | LC_ALL=C sort |
                while IFS='	' read -r p s; do printf 'release\t%s\t%s\t%s\n' "$t" "$s" "$p"; done
        done < "$work/tag-order"
        awk -F'\t' '$1 == "-" { print $3 "\t" $2 }' "$work/package-lines" | LC_ALL=C sort |
            while IFS='	' read -r p s; do printf 'keyring\t-\t%s\t%s\n' "$s" "$p"; done
    } > "$out/pkg-pages.tsv"
    [ "$(wc -l < "$out/pkg-pages.tsv")" -eq "$(($(wc -l < "$work/package-lines") + 1))" ] ||
        die "internal error: pkg-pages.tsv does not list every package file"
    if [ "$signed" = true ]; then
        printf 'pkg-pages.tsv\n' >> "$work/to-sign"
        printf 'pkg-pages.tsv.asc\n' >> "$work/sig-paths"
    fi
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
names="$(while IFS='	' read -r k n v _a _s _p _t; do
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
    if [ "$signed" = true ]; then
        printf '<span class="badge signed">signed</span>'
    else
        printf '<span class="badge unsigned">unsigned</span>'
    fi
    [ -z "$homepage" ] || printf '<a class="badge" href="%s">%s</a>' "$(esc "$homepage")" "$(esc "$homepage")"
    printf '</div>\n    </header>\n'
    if [ "$signed" = true ]; then
        printf '    <p>Packages and repository metadata are signed with <a href="%s.asc">%s.asc</a>.</p>\n' "$h_name" "$h_name"
        printf '    <p>Fingerprint:</p>\n    <code class="fpr">%s</code>\n' "$fpr"
        if [ "$keyring_pkg" = true ]; then
            printf '    <p>Check the key before you trust it:</p>\n    <code class="fpr">curl -fsSL %s/%s.asc | gpg --show-keys</code>\n' "$h_base" "$h_name"
        fi
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
        if [ "$keyring_pkg" = true ]; then
            printf 'sudo curl -fsSLo /usr/share/keyrings/%s-keyring.asc %s/%s.asc\n' "$h_name" "$h_base" "$h_name"
        elif [ "$signed" = true ]; then
            printf 'sudo install -d -m 0755 /etc/apt/keyrings\n'
            printf 'sudo curl -fsSLo /etc/apt/keyrings/%s.asc %s/%s.asc\n' "$h_name" "$h_base" "$h_name"
        fi
        printf 'sudo curl -fsSLo /etc/apt/sources.list.d/%s.list %s/deb/%s.list\n' "$h_name" "$h_base" "$h_name"
        if [ "$keyring_pkg" = true ]; then
            printf 'sudo apt update\nsudo apt install %s-keyring %s</pre></div>\n' "$h_name" "$h_names"
        else
            printf 'sudo apt update\nsudo apt install %s</pre></div>\n' "$h_names"
        fi
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
        # A signature file the seal step will write is the repositories' too.
        ! grep -qxF "$f" "$work/sig-paths" || die "extra-site $extra/$f would overwrite $f of the repositories"
    done < "$work/extra"
    cp -R "$extra/." "$out/"
fi

# --- Directory listings (Pages serves none); existing index.html files are kept ---------------
# The signatures don't exist yet; the listing names the ones site-seal.sh will write.
if [ "$listings" = true ]; then
    find "$out" -mindepth 1 -type d | LC_ALL=C sort | while IFS= read -r dir; do
        [ ! -e "$dir/index.html" ] || continue
        rel="$(esc "${dir#"$out"/}")"
        {
            page_head "Index of /$rel/"
            printf '    <header><div class="top"><h1>Index of /%s/</h1><button type="button" id="theme" class="theme" aria-label="Change theme">◐ Auto</button></div></header>\n' "$rel"
            printf '    <ul class="listing">\n      <li><a href="../">../</a></li>\n'
            {
                for entry in "$dir"/*; do
                    [ -e "$entry" ] || continue
                    e="${entry##*/}"
                    [ "$e" != index.html ] || continue
                    [ ! -d "$entry" ] || e="$e/"
                    printf '%s\n' "$e"
                done
                awk -v d="${dir#"$out"/}" '{ i = match($0, /[^\/]+$/); if (i > 1 && substr($0, 1, i - 2) == d) print substr($0, i) }' "$work/sig-paths"
            } | LC_ALL=C sort -u | while IFS= read -r e; do
                e="$(esc "$e")"
                printf '      <li><a href="%s">%s</a></li>\n' "$e" "$e"
            done
            printf '    </ul>\n'
            page_footer
            printf '  </body>\n</html>\n'
        } > "$dir/index.html"
    done
fi

# --- Done ------------------------------------------------------------------------------------
cp "$work/to-sign" "$to_sign"
n_deb="$(grep -c '^deb	' "$index" || true)"
n_rpm="$(grep -c '^rpm	' "$index" || true)"
log "wrote $out for $name $version: $n_deb .deb, $n_rpm .rpm, ${fpr:+laid out for signing by }${fpr:-unsigned}"
set_output site-path "$out"
set_output to-sign "$to_sign"
set_output signed "$signed"

# shellcheck shell=sh
# Reading .deb and .rpm metadata. Source it after common.sh:
#
#   . "$lib/common.sh"
#   . "$lib/packages.sh"
#
# pkg-pages never trusts file names (cargo-deb, nfpm and rpmbuild all name files differently):
# name, version and architecture always come from the package itself.

# pkg_meta FILE: print one tab-separated line describing the package:
#
#   deb<TAB>NAME<TAB>VERSION<TAB>ARCH      VERSION is the full Debian version (epoch:upstream-rev)
#   rpm<TAB>NAME<TAB>VERSION<TAB>ARCH      VERSION is %{VERSION}-%{RELEASE}, without the epoch
#
# Needs dpkg-deb for .deb and rpm for .rpm. Fails on unreadable metadata, source packages and
# names or versions that are not safe to use in file names.
pkg_meta() {
    case "$1" in
        *.deb)
            command -v dpkg-deb > /dev/null || die "dpkg-deb is needed to read $1"
            _pm_fields="$(dpkg-deb --field "$1" Package Version Architecture 2> /dev/null)" ||
                die "$1 is not a readable .deb"
            _pm_name="$(printf '%s\n' "$_pm_fields" | sed -n 's/^Package: //p')"
            _pm_ver="$(printf '%s\n' "$_pm_fields" | sed -n 's/^Version: //p')"
            _pm_arch="$(printf '%s\n' "$_pm_fields" | sed -n 's/^Architecture: //p')"
            _pm_kind=deb
            ;;
        *.rpm)
            command -v rpm > /dev/null || die "rpm is needed to read $1"
            # The signature is not checked here: check-rpm and the site build do that.
            _pm_fields="$(rpm -qp --nosignature --nodigest \
                --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%|SOURCEPACKAGE?{src}:{bin}|\n' "$1" 2> /dev/null)" ||
                die "$1 is not a readable .rpm"
            _pm_name="$(printf '%s' "$_pm_fields" | cut -f1)"
            _pm_ver="$(printf '%s' "$_pm_fields" | cut -f2)"
            _pm_arch="$(printf '%s' "$_pm_fields" | cut -f3)"
            # Not %{SOURCERPM}: cargo-generate-rpm and nfpm leave it empty in binary packages.
            [ "$(printf '%s' "$_pm_fields" | cut -f4)" = bin ] ||
                die "$1 is a source package; only binary packages are published"
            _pm_kind=rpm
            ;;
        *) die "$1 is neither a .deb nor an .rpm" ;;
    esac
    case "$_pm_name" in
        '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._+-]*) die "$1 has an unusable package name '$_pm_name'" ;;
    esac
    case "$_pm_ver" in
        '' | *[!A-Za-z0-9.+~:_-]*) die "$1 has an unusable version '$_pm_ver'" ;;
    esac
    case "$_pm_arch" in
        '' | *[!A-Za-z0-9_-]*) die "$1 has an unusable architecture '$_pm_arch'" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$_pm_kind" "$_pm_name" "$_pm_ver" "$_pm_arch"
}

# pkg_matches_version KIND PKG_VERSION VERSION: true when a package version (as pkg_meta prints
# it) is the release VERSION.
#
#   deb: the epoch is ignored; VERSION itself, or VERSION-REVISION where the revision starts with
#        a digit (cargo-deb writes 1.2.3-1, Debian maintainers 1.2.3-1ubuntu1).
#   rpm: %{VERSION} is VERSION, with any release. rpm forbids '-' in versions, so a pre-release
#        1.2.3-rc.1 is also matched by 1.2.3~rc.1 (what cargo-generate-rpm and nfpm write).
pkg_matches_version() {
    case "$1" in
        deb)
            _pm_v="${2#*:}"
            [ "$_pm_v" = "$3" ] && return 0
            case "$_pm_v" in
                "$3"-[0-9]*)
                    _pm_rev="${_pm_v#"$3"-}"
                    case "$_pm_rev" in *-*) return 1 ;; esac
                    return 0
                    ;;
            esac
            return 1
            ;;
        rpm)
            _pm_v="${2%-*}"
            [ "$_pm_v" = "$3" ] && return 0
            _pm_tilde="$(printf '%s' "$3" | sed 's/-/~/')"
            [ "$_pm_v" = "$_pm_tilde" ]
            ;;
        *) return 1 ;;
    esac
}

# pool_prefix NAME: the directory of NAME under pool/<component>/, as Debian lays it out:
# the first letter, or lib plus the fourth letter for lib* packages (libfoo → libf).
pool_prefix() {
    case "$1" in
        lib?*) printf 'lib%s\n' "$(printf '%s' "$1" | cut -c4)" ;;
        *) printf '%s\n' "$(printf '%s' "$1" | cut -c1)" ;;
    esac
}

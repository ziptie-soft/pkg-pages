#!/bin/sh
# Point publish.yml's references to this repository's own actions at one commit (the self-pin,
# docs/releasing.md#the-self-pin), or check that they do it right.
#
# Usage:
#   dev/self-pin.sh SHA VERSION [FILE]
#       Rewrite every `uses: ziptie-soft/pkg-pages[/<action>]@<sha> # vX.Y.Z pkg-pages self-pin`
#       line of FILE (default .github/workflows/publish.yml) to `@SHA # vVERSION pkg-pages
#       self-pin`, and every `footer-version: X.Y.Z # pkg-pages self-pin` line to VERSION (the
#       actions at SHA predate the release commit, so their version.txt names the previous
#       release). SHA must be a full commit SHA, VERSION X.Y.Z.
#   dev/self-pin.sh --check [REV] [FILE]
#       Fail unless every self reference of FILE (as it is at REV, default HEAD) uses the same
#       commit W, W is an ancestor of REV, and the actions, lib/ and images.env are identical in
#       W and REV, so what a caller pinning REV runs is exactly what REV contains; and unless
#       every pin comment and footer-version line names one version, version.txt's at REV.
#   dev/self-pin.sh -C DIR ...
#       Work on the checkout in DIR instead of the one this script is in, so that a trusted
#       copy of the script can rewrite or check another checkout.
#
# A self reference without the marker comment is an error in both modes: it would not be moved
# at the next release.
set -eu

die() {
    echo "self-pin.sh: $*" >&2
    exit 1
}

if [ "${1:-}" = -C ]; then
    [ "$#" -ge 2 ] || die "-C needs a directory"
    cd "$2" || die "cannot enter $2"
    shift 2
else
    cd "$(dirname "$0")/.."
fi

refs='uses:[[:space:]]*ziptie-soft/pkg-pages(/[A-Za-z0-9._/-]+)?@'
fver='footer-version:[[:space:]]*'

if [ "${1:-}" = --check ]; then
    rev="${2:-HEAD}"
    file="${3:-.github/workflows/publish.yml}"
    content="$(git show "$rev:$file")" || die "$file is not in $rev"
    lines="$(printf '%s\n' "$content" | grep -E "$refs" || true)"
    [ -n "$lines" ] || die "$file has no self references at $rev"
    if printf '%s\n' "$lines" | grep -vqE '@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+ pkg-pages self-pin$'; then
        printf '%s\n' "$lines" | grep -vE '@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+ pkg-pages self-pin$' >&2
        die "the self references above are not pinned to a full SHA with the '# vX.Y.Z pkg-pages self-pin' comment"
    fi
    shas="$(printf '%s\n' "$lines" | sed -E 's/.*@([0-9a-f]{40}) .*/\1/' | sort -u)"
    [ "$(printf '%s\n' "$shas" | wc -l)" -eq 1 ] || die "the self references use several commits: $(echo "$shas" | tr '\n' ' ')"
    w="$shas"
    git cat-file -e "$w^{commit}" 2> /dev/null || die "the pinned commit $w is not in this repository"
    git merge-base --is-ancestor "$w" "$rev" || die "the pinned commit $w is not an ancestor of $rev"
    # The release version: every pin comment and footer-version line, and version.txt.
    fvers="$(printf '%s\n' "$content" | grep -E "$fver" || true)"
    [ -n "$fvers" ] || die "$file has no 'footer-version: X.Y.Z # pkg-pages self-pin' line at $rev"
    if printf '%s\n' "$fvers" | grep -vqE "${fver}[0-9]+\.[0-9]+\.[0-9]+ # pkg-pages self-pin\$"; then
        printf '%s\n' "$fvers" | grep -vE "${fver}[0-9]+\.[0-9]+\.[0-9]+ # pkg-pages self-pin\$" >&2
        die "the footer-version lines above lack 'X.Y.Z # pkg-pages self-pin'"
    fi
    versions="$({
        printf '%s\n' "$lines" | sed -E 's/.* # v([^ ]+) pkg-pages self-pin$/\1/'
        printf '%s\n' "$fvers" | sed -E "s/.*$fver([^ ]+) # pkg-pages self-pin\$/\1/"
        git show "$rev:version.txt" 2> /dev/null | tr -d '[:space:]' && echo
    } | sed '/^$/d' | sort -u)"
    [ "$(printf '%s\n' "$versions" | wc -l)" -eq 1 ] ||
        die "the pin comments, footer-version and version.txt name several versions: $(echo "$versions" | tr '\n' ' ')"
    # Every action.yml of either commit, lib/ and images.env.
    paths="action.yml lib images.env"
    for c in "$w" "$rev"; do
        for d in $(git ls-tree -d --name-only "$c"); do
            if git cat-file -e "$c:$d/action.yml" 2> /dev/null; then paths="$paths $d/action.yml"; fi
        done
    done
    # shellcheck disable=SC2086 # a list of paths
    if ! git diff --quiet "$w" "$rev" -- $paths; then
        # shellcheck disable=SC2086
        git diff --stat "$w" "$rev" -- $paths >&2
        die "the actions changed between the pinned commit $w and $rev; pin publish.yml again (dev/self-pin.sh)"
    fi
    echo "self-pin OK: $file at $rev uses $w"
    exit 0
fi

[ "$#" -ge 2 ] || die "usage: $0 SHA VERSION [FILE] | --check [REV] [FILE]"
sha="$1"
version="$2"
file="${3:-.github/workflows/publish.yml}"
printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "SHA must be a full 40-hex commit SHA, not '$sha'"
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "VERSION must be X.Y.Z, not '$version'"
[ -f "$file" ] || die "$file does not exist"
if grep -E "$refs" "$file" | grep -vqE ' # v[^ ]+ pkg-pages self-pin$'; then
    grep -nE "$refs" "$file" | grep -vE ' # v[^ ]+ pkg-pages self-pin$' >&2
    die "the self references above lack the '# vX.Y.Z pkg-pages self-pin' comment"
fi
grep -qE "$refs" "$file" || die "$file has no self references"
tmp="$(mktemp)"
sed -E -e "s|($refs)[^ ]+ # v[^ ]+ pkg-pages self-pin\$|\1$sha # v$version pkg-pages self-pin|" \
    -e "s|($fver)[^ ]+ # pkg-pages self-pin\$|\1$version # pkg-pages self-pin|" "$file" > "$tmp"
cat "$tmp" > "$file"
rm -f "$tmp"
echo "pinned $(grep -cE "$refs" "$file") self reference(s) in $file to $sha (v$version)"

#!/bin/sh
# Fail when a shipped action (action.yml, <action>/action.yml) or a reusable workflow
# (`on: workflow_call`) has a `uses: ./…`. In a composite action or a called workflow a local path
# resolves in the *caller's* workspace, not in pkg-pages, so it would run whatever the caller has
# at that path. Shipped code reaches its own files through ${{ github.action_path }} and its own
# actions through `ziptie-soft/pkg-pages/<action>@<sha>` (see docs/releasing.md).
# Usage: dev/check-self-refs.sh [FILE...]   (default: every shipped action and reusable workflow)
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
    set -- action.yml
    for f in */action.yml .github/workflows/*.yml; do
        [ -f "$f" ] || continue
        case "$f" in
            .github/workflows/*) grep -q '^  workflow_call:' "$f" || continue ;;
        esac
        set -- "$@" "$f"
    done
fi

bad=0
for f in "$@"; do
    [ -f "$f" ] || continue
    if grep -nE '^[[:space:]-]*uses:[[:space:]]*["'\'']?\./' "$f"; then
        echo "::error file=$f::local \`uses: ./…\` in shipped code resolves in the caller's checkout" >&2
        bad=1
    fi
done
exit "$bad"

#!/bin/sh
# Run a lib/ command either on this machine or in a pinned container of images.env, the way the
# actions' `runner-mode` input chooses.
#
# Usage:
#   run.sh host|docker [OPTION]... -- COMMAND [ARG]...
#
# Options:
#   --image IMAGE    docker mode: debian, ubuntu or fedora (the images.env pins), or a full
#                    reference pinned by digest (name:tag@sha256:<64 hex>)
#   --tools "T..."   tools COMMAND needs. host: fail early, naming the missing ones. docker: install
#                    them in the container first (see in-container.sh for the package names).
#   --gnupg          give COMMAND a fresh, empty GNUPGHOME and remove it afterwards: a tmpfs in
#                    docker mode, a private temporary directory in host mode
#   --env NAME       pass the environment variable NAME into the container (docker mode). Only
#                    the name is put on the command line, never the value, so secrets such as
#                    REPO_SIGNING_KEY don't show up in the process list.
#   --writes PATH    a path COMMAND creates or changes, relative to the working directory. In
#                    docker mode it is chowned back to the calling user afterwards, so the later
#                    steps of the job can read and delete it.
#
# docker mode mounts the working directory (the caller's checkout) at the same path, and lib/
# read-only at its own path, so COMMAND sees the same paths in both modes. Step outputs and
# GITHUB_ENV lines that COMMAND writes are copied back to the runner's files.
#
#   DOCKER   container engine (default docker; podman works for local runs)
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"

usage() { die "usage: $0 host|docker [--image IMAGE] [--tools \"T...\"] [--gnupg] [--env NAME]... [--writes PATH]... -- COMMAND [ARG]..."; }

[ "$#" -ge 1 ] || usage
mode="$1"
shift
case "$mode" in host | docker) ;; *) die "runner-mode must be host or docker, not '$mode'" ;; esac

image='' tools='' gnupg=false envs='' writes=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) [ "$#" -ge 2 ] || usage; image="$2"; shift 2 ;;
        --tools) [ "$#" -ge 2 ] || usage; tools="$2"; shift 2 ;;
        --gnupg) gnupg=true; shift ;;
        --env)
            [ "$#" -ge 2 ] || usage
            case "$2" in '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) die "--env needs a variable name, not '$2'" ;; esac
            envs="$envs $2"
            shift 2
            ;;
        --writes)
            [ "$#" -ge 2 ] || usage
            check_relpath "--writes" "$2"
            writes="$writes
$2"
            shift 2
            ;;
        --) shift; break ;;
        *) usage ;;
    esac
done
[ "$#" -ge 1 ] || usage

# --- host ------------------------------------------------------------------------------------
if [ "$mode" = host ]; then
    # shellcheck disable=SC2086 # tools is a space-separated list
    [ -z "$tools" ] || require_tools $tools
    if [ "$gnupg" = true ]; then
        GNUPGHOME=''
        make_tmpdir GNUPGHOME
        chmod 700 "$GNUPGHOME"
        export GNUPGHOME
        status=0
        "$@" || status=$?
        # Stop the agent gpg started, so nothing keeps the key in memory after the step.
        gpgconf --homedir "$GNUPGHOME" --kill all > /dev/null 2>&1 || true
        exit "$status"
    fi
    exec "$@"
fi

# --- docker ----------------------------------------------------------------------------------
case "$image" in
    debian | ubuntu | fedora)
        key="$(printf '%s' "$image" | tr '[:lower:]' '[:upper:]')_IMAGE"
        image="$(sed -n "s/^${key}=//p" "$lib/../images.env")"
        [ -n "$image" ] || die "images.env has no $key"
        ;;
    '') die "docker mode needs --image" ;;
    *)
        printf '%s\n' "$image" | grep -Eq '^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$' ||
            die "image must be debian, ubuntu, fedora or a reference pinned by digest (name:tag@sha256:...), not '$image'"
        ;;
esac
docker="${DOCKER:-docker}"
command -v "$docker" > /dev/null || die "$docker is not installed; use runner-mode: host in a job that has the tools"

io=''
make_tmpdir io
: > "$io/output"
: > "$io/env"
chmod 777 "$io"
chmod 666 "$io/output" "$io/env"

# Rootless podman (local runs) maps the container's root to the calling user already, where chown
# would hand the files to a subordinate uid; and on SELinux hosts it can't read the bind mounts
# unless labelling is off. Docker (the runners) needs the chown.
owner=
podman=false
case "$(basename "$docker")" in podman*) podman=true ;; *) owner="$(id -u):$(id -g)" ;; esac

# POSIX sh has no arrays, so the docker arguments are built in "$@" by prepending: first the
# image and COMMAND, then the options in front of them (their order doesn't matter).
set -- "$image" sh "$lib/in-container.sh" "$@"
set -- \
    --rm -i \
    --volume "$PWD:$PWD" --workdir "$PWD" \
    --volume "$lib:$lib:ro" \
    --volume "$io:/pkg-pages-io" \
    --env GITHUB_OUTPUT=/pkg-pages-io/output \
    --env GITHUB_ENV=/pkg-pages-io/env \
    --env "PKG_PAGES_TOOLS=$tools" \
    --env "PKG_PAGES_OWNER=$owner" \
    --env "PKG_PAGES_WRITES=$writes" \
    "$@"
[ -z "${GITHUB_ACTIONS:-}" ] || set -- --env GITHUB_ACTIONS "$@"
[ "$podman" = false ] || set -- --security-opt label=disable "$@"
if [ "$gnupg" = true ]; then
    # tmpfs: the key is never written to the runner's disk, and goes away with the container.
    set -- --tmpfs /pkg-pages-gnupg:rw,mode=0700 --env GNUPGHOME=/pkg-pages-gnupg "$@"
fi
for name in $envs; do
    set -- --env "$name" "$@"
done
# version.txt sits beside lib/: pages-repo.sh names it in the landing page footer.
root="$(dirname "$lib")"
[ ! -f "$root/version.txt" ] || set -- --volume "$root/version.txt:$root/version.txt:ro" "$@"

status=0
"$docker" run "$@" || status=$?
if [ -n "${GITHUB_OUTPUT:-}" ]; then cat "$io/output" >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_ENV:-}" ]; then cat "$io/env" >> "$GITHUB_ENV"; fi
exit "$status"

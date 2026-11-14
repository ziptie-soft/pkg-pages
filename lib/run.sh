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
#                    them in a throwaway container first and commit it as a local image (see below,
#                    and in-container.sh for the package names).
#   --gnupg          give COMMAND a fresh, empty GNUPGHOME and remove it afterwards: a tmpfs in
#                    docker mode, a private temporary directory in host mode
#   --env NAME       pass the environment variable NAME into the container (docker mode). Only
#                    the name is put on the command line, never the value, so secrets such as
#                    REPO_SIGNING_KEY don't show up in the process list.
#   --writes PATH    a path COMMAND creates or changes, relative to the working directory. In
#                    docker mode it is chowned back to the calling user afterwards, so the later
#                    steps of the job can read and delete it.
#   --read-only      docker mode: mount the working directory read-only (COMMAND writes nothing
#                    there; not with --writes). Not the engine's --read-only: the container's
#                    root filesystem is read-only in every run without --net.
#   --net            docker mode: keep the engine's default network, capabilities and writable
#                    root filesystem, for a COMMAND that installs packages (install-test)
#
# docker mode mounts the working directory (the caller's checkout) at the same path, and lib/
# read-only at its own path, so COMMAND sees the same paths in both modes. Step outputs and
# GITHUB_ENV lines that COMMAND writes are copied back to the runner's files.
#
# docker mode runs in two phases:
#   1. install: when --tools is given and no image pkg-pages-tools:<hash of the image and the
#      tools> exists yet, a container with lib/ only (no checkout, no io, no environment, no
#      key) installs the missing tools, and is committed to that tag. It is always removed. The
#      later steps of the job find the tag and skip this phase. On self-hosted runners these
#      images stay until removed (docker image rm).
#   2. command: COMMAND runs in the committed image (or the base image when nothing was missing),
#      without network, with only the CHOWN and DAC_OVERRIDE capabilities, no-new-privileges, and
#      a read-only root filesystem with a tmpfs /tmp, unless --net is given.
#
#   DOCKER   container engine (default docker; podman works for local runs)
set -eu

lib="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$lib/common.sh"

usage() { die "usage: $0 host|docker [--image IMAGE] [--tools \"T...\"] [--gnupg] [--env NAME]... [--writes PATH]... [--read-only] [--net] -- COMMAND [ARG]..."; }

[ "$#" -ge 1 ] || usage
mode="$1"
shift
case "$mode" in host | docker) ;; *) die "runner-mode must be host or docker, not '$mode'" ;; esac

image='' tools='' gnupg=false envs='' writes='' ro=false net=false
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
        --read-only) ro=true; shift ;;
        --net) net=true; shift ;;
        --) shift; break ;;
        *) usage ;;
    esac
done
[ "$#" -ge 1 ] || usage
[ "$ro" = false ] || [ -z "$writes" ] || die "--read-only and --writes exclude each other"

# --- host ------------------------------------------------------------------------------------
if [ "$mode" = host ]; then
    # shellcheck disable=SC2086 # tools is a space-separated list
    [ -z "$tools" ] || require_tools $tools
    if [ "$gnupg" = true ]; then
        GNUPGHOME=''
        make_tmpdir GNUPGHOME
        chmod 700 "$GNUPGHOME"
        export GNUPGHOME
        # Stop the agent gpg started, so nothing keeps the key in memory: after the command, and
        # when the step is interrupted (the EXIT trap then removes GNUPGHOME).
        stop_agent() { gpgconf --homedir "$GNUPGHOME" --kill all > /dev/null 2>&1 || true; }
        trap 'stop_agent; exit 130' INT
        trap 'stop_agent; exit 143' TERM
        status=0
        "$@" || status=$?
        stop_agent
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
# Private to the calling user: rootful Docker's root writes them anyway, and rootless engines map
# root to the calling user.
chmod 700 "$io"
chmod 600 "$io/output" "$io/env"
# docker --volume splits on ':', so a path holding one can't be mounted.
for p in "$PWD" "$lib" "$io"; do
    case "$p" in *:*) die "docker mode can't mount $p: the path contains ':'; use runner-mode: host" ;; esac
done

# Rootless podman (local runs) maps the container's root to the calling user already, where chown
# would hand the files to a subordinate uid; and on SELinux hosts it can't read the bind mounts
# unless labelling is off. Docker (the runners) needs the chown.
owner=
podman=false
case "$(basename "$docker")" in podman*) podman=true ;; *) owner="$(id -u):$(id -g)" ;; esac
label=
[ "$podman" = false ] || label="--security-opt label=disable"

# --- phase 1: install the tools in a throwaway container, and commit it ------------------------
# shellcheck disable=SC2086 # tools is a space-separated list
tools_sorted="$(printf '%s\n' $tools | sort -u | tr '\n' ' ')"
tools_sorted="${tools_sorted% }"
pull=
if [ -n "$tools_sorted" ]; then
    tag="pkg-pages-tools:$(printf '%s\n%s\n' "$image" "$tools_sorted" | sha256sum | cut -c1-12)"
    if "$docker" image inspect "$tag" > /dev/null 2>&1; then
        image="$tag" pull=--pull=never
    else
        cname="pkg-pages-install-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
        register_container "$docker" "$cname"
        log "installing $tools_sorted in a throwaway container"
        installed=0
        # stdout to stderr: run.sh's stdout is COMMAND's own.
        # shellcheck disable=SC2086 # label is empty or two words
        "$docker" run --name "$cname" $label \
            --volume "$lib:$lib:ro" \
            --env "PKG_PAGES_TOOLS=$tools_sorted" \
            "$image" sh "$lib/in-container.sh" --install-only >&2 || installed=$?
        case "$installed" in
            0)
                "$docker" commit "$cname" "$tag" > /dev/null || die "$docker commit of the tools image $tag failed"
                image="$tag" pull=--pull=never
                ;;
            10) ;; # nothing was missing: COMMAND runs in the base image
            *) die "installing the tools ($tools_sorted) failed" ;;
        esac
    fi
fi

# --- phase 2: run COMMAND ----------------------------------------------------------------------
# POSIX sh has no arrays, so the docker arguments are built in "$@" by prepending: first the
# image and COMMAND, then the options in front of them (their order doesn't matter).
ws=''
[ "$ro" = false ] || ws=:ro
set -- "$image" sh "$lib/in-container.sh" "$@"
set -- \
    --rm -i \
    --volume "$PWD:$PWD$ws" --workdir "$PWD" \
    --volume "$lib:$lib:ro" \
    --volume "$io:/pkg-pages-io" \
    --env GITHUB_OUTPUT=/pkg-pages-io/output \
    --env GITHUB_ENV=/pkg-pages-io/env \
    --env PKG_PAGES_TOOLS= \
    --env "PKG_PAGES_OWNER=$owner" \
    --env "PKG_PAGES_WRITES=$writes" \
    "$@"
if [ "$net" = false ]; then
    # Docker's --read-only, unlike podman's, adds no tmpfs of its own; make_tmpdir needs /tmp.
    set -- --network none --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE \
        --security-opt no-new-privileges \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 "$@"
fi
[ -z "${GITHUB_ACTIONS:-}" ] || set -- --env GITHUB_ACTIONS "$@"
# shellcheck disable=SC2086 # label is empty or two words, pull empty or one
set -- $label $pull "$@"
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

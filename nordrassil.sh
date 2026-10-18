#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# -----------------------------------------------------------------------------
# nordrassil.sh — the World Tree for a VMaNGOS vanilla WoW server.
#
# A gum-free, flag-driven engine that builds and runs a VMaNGOS-based vanilla
# WoW (1.12.1 / client build 5875) server from the repack at SOURCE_DIR
# (default ~/jaws/MaNGOS): natively for fast local iteration, and as a
# Docker/k8s deployment for LAN-wide play. scomp-link ships a thin gum TUI
# (wow-nordrassil) that drives this by flags; nothing here needs gum.
#
# The repack ships compiled Windows binaries (mangosd.exe/realmd.exe) and a
# bundled Windows MySQL, but also its own C++ source
# (source/Repack 25 Source.zip — a standard out-of-source CMake project with
# an official Linux Docker build recipe at contrib/docker-build/). This script
# always builds the native Linux binaries from that source — no Wine, no
# Windows MySQL. The Windows .exe files and mysql5/ directory are unused.
#
# Two independent paths:
#   - Local native (install-deps/configure/start/stop): builds mangosd/realmd
#     directly on this host via cmake+make for fast iteration. ACE toolkit
#     (a hard build dependency) isn't packaged for Fedora/RHEL, so install-deps
#     builds it from source there instead (cached under ACE_DEPS_DIR,
#     ~/.cache/ace-wrappers/<version>) — see _build_ace_from_source. Still
#     works everywhere apt has libace-dev.
#   - Container (build-image/run-docker/run-k8s): always builds inside an
#     Ubuntu build stage regardless of host OS, so it works everywhere Docker
#     does. This is the actual LAN-deployable artifact.
#
# The database is always a separate MariaDB container/pod — never bundled
# into the server image, and never installed natively on the host. The same
# DB bootstrap sequence (schemas + world dump + migrations + optional custom
# content) is reused by 'configure' (local dev) and the k8s db-init Job.
#
# Config: ~/.config/nordrassil/nordrassil.conf (XDG-style, key=value). The
# front-end pushes values with 'set <KEY> <VALUE>'; commands read them back.
# -----------------------------------------------------------------------------

# bash 4+: ${var^^} (delete-account), read -a/arrays etc. macOS ships 3.2.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# The rest of the engine, by concern (see each file's header). Sourced before
# anything runs, in this order: later files use what earlier ones define.
[[ -d "${SCRIPT_DIR}/lib" ]] || { echo "[error] ${SCRIPT_DIR}/lib not found — nordrassil.sh runs from its checkout, next to lib/ and templates/." >&2; exit 1; }
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/transport.sh"
source "${SCRIPT_DIR}/lib/provision.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/native.sh"
source "${SCRIPT_DIR}/lib/deploy.sh"
source "${SCRIPT_DIR}/lib/admin.sh"


# -----------------------------------------------------------------------------
# Main dispatch — gum-free, flag-driven. Global --context/--kind (kube target)
# may precede the subcommand; everything after the subcommand is passed to it.
# -----------------------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
nordrassil — VMaNGOS vanilla WoW (1.12.1) server engine

Usage: nordrassil.sh [--profile NAME] [--context CTX | --kind CLUSTER] <command> [flags]

Global flags (kube target for run-k8s/stop-k8s):
  --context CTX        use kube-context CTX
  --kind CLUSTER       use kind cluster CLUSTER (context kind-CLUSTER; side-loads the image)
  --profile NAME       use the profile NAME (see Profiles below)

Setup / local:
  install-deps
  configure [--custom NAMES]      DB bootstrap + render the local conf files (no build)
  edit --file mangosd|realmd      open a conf file in $EDITOR (default vim)
  start | stop | status

Deploy:
  build-image
  run-docker [--force]            recreate an existing container with --force
  stop-docker
  run-k8s [--namespace NS] [--address ADDR]
  stop-k8s

Accounts:
  create-account --name N --pass P [--level L] [--where local|docker|k8s]
  list-accounts [--where ...]
  delete-account --name N [--where ...]
  set-account-level --name N --level L [--where ...]

Characters:
  rename-character --from OLD --to NEW

Administration:
  apply-sql --file PATH --db NAME [--force] [--no-record]
                                  run a .sql file against one database.
                                  Tracked by content hash, so re-running an
                                  unchanged file does nothing and an edited
                                  one applies again.
  restart [--graceful [SECS]] [--where ...]
                                  restart at the orchestrator (default), or
                                  ask mangosd to restart in SECS, warning
                                  players and saving the world first.
  dump --all | --db NAME [--tables "a b c"] [--out PATH] [--no-gzip]
                                  gzipped SQL to ~/.config/nordrassil/dumps
                                  by default. Carries CREATE DATABASE, so a
                                  restore needs no --db — except with
                                  --tables, which dumps a subset and must be
                                  restored with --db.
  restore --file PATH --yes [--db NAME]
                                  DESTRUCTIVE: replaces the data in whichever
                                  databases the dump names. gzip is detected
                                  by content. --yes is required.

Search:
  search --kind items|npcs|teleports|characters --term TERM

Config store (used by the scomp-link front-end):
  set KEY VALUE | get KEY | config | list-custom

Transports (where this script looks for the server and the database):
  Two independent settings, because they need not be in the same place — a
  server can run in k8s while its database runs under podman on the host.

  set DB_TRANSPORT      auto | docker | podman | kubectl | tcp
  set SERVER_TRANSPORT  auto | local  | docker | podman  | kubectl

  'auto' probes the local container, then the cluster, then TCP. Supporting
  settings, each of which used to be hardcoded:

  set DB_HOST / DB_PORT        the tcp transport's endpoint
  set DB_POD_SELECTOR          default app=vanilla-wow-mariadb
  set SERVER_POD_SELECTOR      default app=vanilla-wow-server
  set SERVER_K8S_CONTAINER     container in the pod (empty = kubectl picks)
  set SERVER_FIFO              mangosd's console FIFO inside the container
                               (default /app/mangosd.stdin)

  SSH is a third, orthogonal axis — it says WHERE the orchestrator runs,
  not which one, so remote k8s needs no kubectl on this machine:

  set DB_SSH_HOST / SERVER_SSH_HOST    empty = local; needs key-based ssh

  With an ssh host set, the transport must be explicit: 'auto' will not
  probe across a network. tcp needs a mariadb client here.
  --where still selects between several running servers.

Profiles (one per server):
  --profile NAME <command>        or $NORDRASSIL_PROFILE
  --no-profile <command>          the base config, ignoring $NORDRASSIL_PROFILE
  profiles                        list them, marking the active one
  forget [--all]                  drop the cached database password

  A profile is $CONFIG_DIR/profiles/NAME.conf, layered OVER nordrassil.conf:
  a key present in the profile wins, anything absent falls through. So
  shared settings stay in one place and a profile carries only what differs.
  'set' writes to the active profile, or to the base file when none is.
  A profile that does not exist is an error for every command but 'set',
  which creates it: otherwise a typo would act on the base config instead.
  Profiles and dumps are 0600 in 0700 directories — both hold secrets.

  DB_PASS=ask prompts once per session per profile, cached in
  $XDG_RUNTIME_DIR (tmpfs, 0600, gone on logout). 'forget' clears it.

  Provisioning acts on THIS machine — the local docker socket, the ambient
  kube context, conf files here — so configure, build-image, run-docker,
  stop-docker, run-k8s, stop-k8s, start, stop and edit are REFUSED when the
  profile points elsewhere (*_SSH_HOST set, SERVER_TRANSPORT=kubectl with no
  --context/--kind, or DB_TRANSPORT=tcp to a non-local host). Administration
  honours the transports and is unaffected. run-k8s and stop-k8s print the
  kube context they are about to change.

  set MANAGED_EXTERNALLY 1     this server is provisioned by something else
                               (Ansible, GitOps, CI). configure, build-image,
                               run-docker, stop-docker, run-k8s, stop-k8s,
                               start, stop and edit are then REFUSED;
                               accounts, characters, search, apply-sql, dump,
                               restore, restart and status still work.
                               Mainly it stops 'configure' re-running the
                               world import over live data.

  A worked example — k8s server on another host, its MariaDB in podman
  beside it, driven from a machine with neither kubectl nor the password:

    --profile meksha set DB_TRANSPORT podman
    --profile meksha set DB_SSH_HOST meksha
    --profile meksha set DB_CONTAINER_NAME mariadb
    --profile meksha set DB_PASS ask
    --profile meksha set SERVER_TRANSPORT kubectl
    --profile meksha set SERVER_SSH_HOST meksha
    --profile meksha set K8S_NAMESPACE azeroth
    --profile meksha set SERVER_POD_SELECTOR app=azeroth
    --profile meksha set SERVER_K8S_CONTAINER azeroth
    --profile meksha set SERVER_FIFO /opt/azeroth/mangosd.stdin

  help | -h | --help
EOF
}

main() {
    # $NORDRASSIL_PROFILE first so an explicit --profile can still override it.
    [[ -n "$PROFILE" ]] && _profile_activate "$PROFILE"

    # Global flags first (kube target, profile), then the subcommand.
    while [[ $# -gt 0 ]]; do case "$1" in
        --context) KUBE_CONTEXT="$2"; shift 2 ;;
        --kind)    KIND_CLUSTER="$2"; shift 2 ;;
        --profile) _profile_activate "$2"; shift 2 ;;
        --no-profile) _profile_deactivate; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) error_exit "Unknown global flag: $1" ;;
        *) break ;;
    esac; done

    [[ $# -gt 0 ]] || { usage; exit 2; }

    # Named subcmd, not cmd: 'cmd' is a local ARRAY in the _db_run helpers, and
    # SC2178 reads that reuse across the file as one variable.
    local subcmd="$1"; shift
    SUBCMD="$subcmd"   # for _require_valid_settings
    # After the flags, before the command: 'set' may create a profile, every
    # other command must find one.
    _profile_require "$subcmd"
    case "$subcmd" in
        install-deps)       cmd_install_deps "$@" ;;
        configure)          cmd_configure "$@" ;;
        start)              cmd_start "$@" ;;
        stop)               cmd_stop "$@" ;;
        status)             cmd_status "$@" ;;
        edit)               cmd_edit "$@" ;;
        create-account)     cmd_create_account "$@" ;;
        list-accounts)      cmd_list_accounts "$@" ;;
        delete-account)     cmd_delete_account "$@" ;;
        set-account-level)  cmd_set_account_level "$@" ;;
        rename-character)   cmd_rename_character "$@" ;;
        search)             cmd_search "$@" ;;
        apply-sql)          cmd_apply_sql "$@" ;;
        restart)            cmd_restart "$@" ;;
        dump)               cmd_dump "$@" ;;
        restore)            cmd_restore "$@" ;;
        build-image)        cmd_build_image "$@" ;;
        run-docker)         cmd_run_docker "$@" ;;
        stop-docker)        cmd_stop_docker "$@" ;;
        run-k8s)            cmd_run_k8s "$@" ;;
        stop-k8s)           cmd_stop_k8s "$@" ;;
        set)                cmd_set "$@" ;;
        get)                cmd_get "$@" ;;
        config)             cmd_config "$@" ;;
        list-custom)        cmd_list_custom "$@" ;;
        profiles)           cmd_profiles "$@" ;;
        forget)             cmd_forget "$@" ;;
        -h|--help|help)     usage ;;
        *) error_exit "Unknown command: $subcmd (run with --help for usage)" ;;
    esac
}

main "$@"

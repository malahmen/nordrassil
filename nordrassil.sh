#!/usr/bin/env bash
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

# -----------------------------------------------------------------------------
# Self-contained, gum-free helpers (this is the engine; the scomp-link
# wow-nordrassil front-end owns all interactivity and drives this by flags).
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""; fi
info()       { printf '%s[info]%s  %s\n' "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s[ok]%s    %s\n' "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s[warn]%s  %s\n' "$C_Y" "$C_N" "$*" >&2; }
error_exit() { printf '%s[error]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }
header()     { printf '\n%s== %s ==%s\n' "$C_C" "$*" "$C_N" >&2; }
_section()   { printf '\n%s-- %s --%s\n' "$C_C" "$*" "$C_N" >&2; }

os_family() { case "$(uname -s)" in Darwin) echo macos ;; Linux) echo linux ;; *) echo other ;; esac; }
_pkg_manager() {
    command -v rpm-ostree &>/dev/null && { echo rpm-ostree; return; }
    command -v dnf &>/dev/null && { echo dnf; return; }
    command -v apt-get &>/dev/null && { echo apt; return; }
    echo ""
}
_require_sudo_or_instruct() {
    local desc="$1"; shift
    sudo -n true 2>/dev/null && return 0
    [[ -t 0 && -t 1 ]] && return 0
    warn "${desc} needs sudo, and this session has no TTY for a password prompt."
    error_exit "Run it yourself, then re-run:
  $*"
}
# rpm-ostree layers packages into a new deployment that only takes effect
# after a reboot, and every 'rpm-ostree install' is a separate (slow)
# transaction — so on those hosts _ensure_pkg/_ensure_pkgs only queue what's
# missing here, and cmd_install_deps layers the whole list in one go
# (_layer_rpm_ostree_pending). Per-package installs used to 'return 1' after
# the first one, which under set -e aborted install-deps right there.
RPM_OSTREE_PENDING=()
_layer_rpm_ostree_pending() {
    [[ ${#RPM_OSTREE_PENDING[@]} -gt 0 ]] || return 0
    local pkgs="${RPM_OSTREE_PENDING[*]}"
    _require_sudo_or_instruct "Layering packages" "sudo rpm-ostree install -y --idempotent --allow-inactive ${pkgs} (then reboot)"
    # --idempotent: already-layered packages aren't an error; --allow-inactive:
    # nor are ones the base image already ships.
    sudo rpm-ostree install -y --idempotent --allow-inactive "${RPM_OSTREE_PENDING[@]}" \
        || error_exit "rpm-ostree install failed for: ${pkgs}"
    warn "Layered via rpm-ostree: ${pkgs} — reboot, then re-run 'install-deps' to finish (ACE build)."
}
# _ensure_pkg <check-bin> <dnf-pkg> [apt-pkg]
_ensure_pkg() {
    local bin="$1" dnf_pkg="$2" apt_pkg="${3:-$2}" pm
    command -v "$bin" &>/dev/null && { info "${bin} found."; return 0; }
    pm="$(_pkg_manager)"; [[ -n "$pm" ]] || error_exit "No supported package manager (dnf/apt/rpm-ostree) to install '${dnf_pkg}'."
    case "$pm" in
        rpm-ostree) info "${bin} missing — queued for layering (${dnf_pkg})."; RPM_OSTREE_PENDING+=("$dnf_pkg"); return 0 ;;
        dnf)  _require_sudo_or_instruct "Installing ${dnf_pkg}" "sudo dnf install -y ${dnf_pkg}"; sudo dnf install -y "$dnf_pkg" || error_exit "dnf install failed for ${dnf_pkg}." ;;
        apt)  _require_sudo_or_instruct "Installing ${apt_pkg}" "sudo apt-get update -qq && sudo apt-get install -y ${apt_pkg}"; sudo apt-get update -qq && sudo apt-get install -y "$apt_pkg" || error_exit "apt install failed for ${apt_pkg}." ;;
    esac
    command -v "$bin" &>/dev/null || error_exit "${bin} installation appears to have failed."
    success "${bin} installed."
}
# _ensure_pkgs <dnf-list> <apt-list>  — bulk (-dev libs with no checkable binary)
_ensure_pkgs() {
    local dnf_pkgs="$1" apt_pkgs="$2" pm; pm="$(_pkg_manager)"
    [[ -n "$pm" ]] || error_exit "No supported package manager (dnf/apt/rpm-ostree)."
    # shellcheck disable=SC2086
    case "$pm" in
        rpm-ostree) info "Queued for layering: ${dnf_pkgs}"; local -a more; read -ra more <<<"$dnf_pkgs"; RPM_OSTREE_PENDING+=("${more[@]}"); return 0 ;;
        dnf)  _require_sudo_or_instruct "Installing packages" "sudo dnf install -y ${dnf_pkgs}"; sudo dnf install -y $dnf_pkgs || error_exit "dnf install failed." ;;
        apt)  _require_sudo_or_instruct "Installing packages" "sudo apt-get update -qq && sudo apt-get install -y ${apt_pkgs}"; sudo apt-get update -qq && sudo apt-get install -y $apt_pkgs || error_exit "apt install failed." ;;
    esac
    success "Packages installed."
}
_check_docker() {
    command -v docker &>/dev/null || error_exit "docker not found — install it (see scomp-link's docker.sh) and retry."
    docker info &>/dev/null 2>&1 || error_exit "docker daemon not reachable (start Docker, or check your 'docker' group membership)."
    info "docker: $(docker --version 2>/dev/null | head -1)"
}

# Port-forward / background-process PID-file helpers ("<pid>:<port>" format).
_pf_pid()       { local p; p="$(cut -d: -f1 < "$1" 2>/dev/null)"; [[ "$p" =~ ^[0-9]+$ ]] && printf '%s' "$p"; }
pf_is_running() { local f="$1" pid; [[ -f "$f" ]] || return 1; pid="$(_pf_pid "$f")"; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }
pf_port()       { [[ -f "$1" ]] && cut -d: -f2 < "$1" 2>/dev/null; }
pf_stop() {
    local f="$1" pid; [[ -f "$f" ]] || { success "Stopped."; return; }
    pid="$(_pf_pid "$f")"
    if [[ -n "$pid" ]]; then pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true
    else warn "PID file empty/invalid — removing without signalling."; fi
    rm -f "$f"; success "Stopped."
}

# Kubernetes context: driven by --context (KUBE_CONTEXT) or a kind cluster name
# (--kind KIND_CLUSTER, which implies context "kind-<name>"). Empty = current.
KUBE_CONTEXT=""
KIND_CLUSTER=""
kubectl_context_flag() {
    [[ -n "$KIND_CLUSTER" ]] && { echo "--context kind-${KIND_CLUSTER}"; return; }
    [[ -n "$KUBE_CONTEXT" ]] && { echo "--context ${KUBE_CONTEXT}"; return; }
    echo ""
}

trap 'echo "" >&2; warn "Interrupted."; exit 130' INT TERM

# -----------------------------------------------------------------------------
# Constants / config
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nordrassil"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/nordrassil.conf"
# PROFILES. One file per server, layered OVER nordrassil.conf: a key present
# in the active profile wins, anything absent falls through to the base file.
# That way shared settings (SOURCE_DIR, WOW_PATCH, rates) stay in one place
# and a profile only carries what actually differs — which, for a remote
# server, is the transports, the selectors and the credentials.
#
# Selected with --profile NAME or $NORDRASSIL_PROFILE. With none active, this
# script behaves exactly as it did before profiles existed.
DUMP_DIR="${CONFIG_DIR}/dumps"
# The four databases a VMaNGOS server uses. Fixed rather than configurable
# because _db_bootstrap targets these names literally when it imports.
NORDRASSIL_DBS=(mangos characters realmd logs)
PROFILE_DIR="${CONFIG_DIR}/profiles"
PROFILE="${NORDRASSIL_PROFILE:-}"
PROFILE_FILE=""
BUILD_DIR="${CONFIG_DIR}/build"
INSTALL_DIR="${CONFIG_DIR}/install"
SRC_UNPACK_DIR="${CONFIG_DIR}/src"
ETC_DIR="${CONFIG_DIR}/etc"
PF_DIR="${CONFIG_DIR}/pf"
# Legacy host-side import markers. Nothing writes here any more (import
# state lives in realmd.nordrassil_applied, see _db_bootstrap); the path is
# still read once, to seed that table on an already-bootstrapped deployment.
MIGRATIONS_MARKER_DIR="${CONFIG_DIR}/applied-migrations"
IMAGE_BUILD_CONTEXT="${CONFIG_DIR}/image-build-context"

mkdir -p "$CONFIG_DIR" "$ETC_DIR" "$PF_DIR"

CLIENT_BUILD_DEFAULT=5875
# Pinned release for the from-source ACE build (dnf/rpm-ostree hosts — no
# native package exists). Bump deliberately, not casually: VMaNGOS's
# FindACE.cmake has no version floor/ceiling of its own, so an untested newer
# ACE could silently drop an API this codebase still uses.
ACE_BUILD_VERSION="8.0.7"
# Shared across projects/repos on this machine, NOT under CONFIG_DIR — ACE
# itself has nothing project-specific about it, so every fork/port of this
# script (this one included — ported from vanilla-wow-server) reuses the same
# from-source build instead of paying the multi-minute compile again just
# because CONFIG_DIR's name changed. Versioned in the path since
# _build_ace_from_source only checks for the built files' existence, not
# their version — a bump to ACE_BUILD_VERSION must land in a new directory,
# not silently reuse a stale build under the old one.
ACE_DEPS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ace-wrappers/${ACE_BUILD_VERSION}/ACE_wrappers"

# -----------------------------------------------------------------------------
# Config persistence (flat key=value file, lgtm.sh style — enough knobs here
# that partial get/set beats dozzle.sh's plain whole-file source)
# -----------------------------------------------------------------------------

# Escapes a value for use as the replacement text of a sed 's|...|...|'
# command (backslash, '&', and the '|' delimiter every sed call in this
# script uses). Shared by cfg_set, the conf renderers and render_template.
_sed_escape() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }

# _mkdir_private <dir> — create it owner-only. For PROFILE_DIR and DUMP_DIR: a
# profile carries DB_PASS and a dump of realmd carries every account row, and
# both were made 0755 with 0644 files in them.
#
# Deliberately NOT used for CONFIG_DIR itself. ETC_DIR lives under it and its
# rendered conf files are bind-mounted into the server container, which may run
# as another uid — and traversing to a mount source needs search permission on
# every parent directory. Tightening the two directories that hold secrets
# costs nothing; tightening their parent would break 'run-docker'.
_mkdir_private() { mkdir -p "$1"; chmod 700 "$1" 2>/dev/null || true; }

# _cfg_has <file> <key> / _cfg_read <file> <key> — presence and value.
# Presence rather than a non-empty value is what the layering tests, so a
# profile can deliberately blank a key the base file sets (clearing an
# inherited DB_SSH_HOST, say) instead of being unable to override it.
_cfg_has()  { [[ -n "$1" ]] && grep -qE "^${2}=" "$1" 2>/dev/null; }
_cfg_read() { grep -E "^${2}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true; }

cfg_get() {
    if _cfg_has "$PROFILE_FILE" "$1"; then
        _cfg_read "$PROFILE_FILE" "$1"
        return 0
    fi
    _cfg_read "$CONFIG_FILE" "$1"
}

# _cfg_target — the file 'set' writes to: the active profile, else the base.
_cfg_target() { printf '%s' "${PROFILE_FILE:-$CONFIG_FILE}"; }
cfg_set() {
    local key="$1" val="$2" quoted
    # The key is spliced into a regex and the value into a sed replacement;
    # the file is one key=value per line, so neither may carry a newline.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error_exit "set: invalid key '${key}' (letters, digits, underscore)."
    [[ "$val" != *$'\n'* ]] || error_exit "set: ${key}: value must not contain a newline."
    # Validated on the way IN as well as on the way out. _settings reads this
    # key and used to error_exit on anything but 0 or 1 — and _settings runs
    # first in every command, 'set' included, so one 'set MANAGED_EXTERNALLY
    # yes' left no command able to correct it. The read side now fails safe
    # instead of fatally (see _settings); this stops the bad value being
    # stored at all.
    [[ "$key" != "MANAGED_EXTERNALLY" || "$val" =~ ^[01]$ ]] \
        || error_exit "set: MANAGED_EXTERNALLY must be 0 or 1 (got '${val}') — 1 means something else provisions this server."
    quoted="\"${val}\""
    local file dir; file="$(_cfg_target)"; dir="$(dirname "$file")"
    # Only PROFILE_DIR is tightened. The base file's directory IS CONFIG_DIR,
    # and ETC_DIR under it holds the rendered conf files that get bind-mounted
    # into the server container — which may run as another uid, and needs
    # search permission on every parent of a mount source. Caught by a test
    # asserting CONFIG_DIR stays traversable.
    if [[ "$dir" == "$PROFILE_DIR" ]]; then _mkdir_private "$dir"; else mkdir -p "$dir"; fi
    touch "$file"
    # DB_PASS is stored here. The file was 0644, and so was every profile.
    chmod 600 "$file" 2>/dev/null || true
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=$(_sed_escape "$quoted")|" "$file" && rm -f "${file}.bak"
    else
        echo "${key}=${quoted}" >> "$file"
    fi
}
# _profile_activate <name> — point the config layer at a profile.
# The name becomes a filename, so it is restricted rather than trusted: no
# slashes, no leading dot, which rules out traversal and dotfiles both.
_profile_activate() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || error_exit "profile: invalid name '${name}' (letters, digits, then . _ - )."
    [[ "$name" != *..* ]] || error_exit "profile: invalid name '${name}'."
    PROFILE="$name"
    PROFILE_FILE="${PROFILE_DIR}/${name}.conf"
}

# _profile_deactivate — back to the base config, whatever the environment says.
# $NORDRASSIL_PROFILE is read at startup, so without this there was no way to
# ask for the base file from a shell that exports one: the front-end's "base
# config (no profile)" entry acted on the exported profile instead.
_profile_deactivate() { PROFILE=""; PROFILE_FILE=""; }

# _profile_names — the profiles that exist, one per line.
_profile_names() {
    local f
    for f in "$PROFILE_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        basename "$f" .conf
    done
}

# _profile_require <command> — refuse to run a command with a profile whose
# file does not exist.
#
# _profile_activate only validates the NAME, because the file is allowed not to
# exist yet: '--profile new set KEY VALUE' is how a profile is created. The
# price of that was silent fallthrough — cfg_get checks the profile for a key,
# does not find the file, and reads the base config instead. So a typo did not
# fail; it acted on a DIFFERENT SERVER and exited 0. Measured:
# '--profile mekhsa restore --yes' restored over the local tcp database with
# the base password, reporting success.
#
# The check lives here, where the command is known, rather than in
# _profile_activate: 'set' may create a profile, 'profiles' is how you find out
# what the name should have been, and nothing else may act on one that is not
# there.
_profile_require() {
    [[ -n "$PROFILE" ]] || return 0
    [[ -f "$PROFILE_FILE" ]] && return 0
    case "$1" in
        set)                   info "profile '${PROFILE}': creating ${PROFILE_FILE}"; return 0 ;;
        profiles|help|-h|--help) return 0 ;;
    esac
    warn "No such profile: '${PROFILE}' — ${PROFILE_FILE} does not exist."
    warn "'${1}' would otherwise have run against the base config (${CONFIG_FILE}):"
    warn "its transport, its credentials, its server — and exited 0."
    local have; have="$(_profile_names | tr '\n' ' ')"
    [[ -n "${have// /}" ]] && warn "Profiles that do exist: ${have}" \
                           || warn "No profiles exist yet. Create one with: --profile ${PROFILE} set KEY VALUE"
    error_exit "Refusing to run '${1}' with a profile that does not exist."
}

cfg_default() {
    # cfg_default KEY DEFAULT — returns existing value or DEFAULT (does not persist)
    local val
    val="$(cfg_get "$1")"
    echo "${val:-$2}"
}

# -----------------------------------------------------------------------------
# Resolved settings (read fresh each invocation so cfg_set changes take effect
# without re-sourcing)
# -----------------------------------------------------------------------------

# Best-effort LAN IP for the realmlist "address" field — the WoW client
# connects to this after authenticating via realmd, so it must be a real,
# reachable IP (not 127.0.0.1, not 0.0.0.0). Falls back to 127.0.0.1 if
# nothing better can be determined (local-only testing).
_detect_lan_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "127.0.0.1"
}

# Every key _settings resolves below, in the same order — the allowlist
# 'get' answers from (see cmd_get). Keep the two in step: a setting missing
# here is still settable and still used, it just can't be read back with its
# default, which is how the front-end pre-fills its prompts.
SETTING_KEYS=(
    SOURCE_DIR CLIENT_BUILD
    DB_HOST DB_PORT DB_USER DB_PASS DB_CONTAINER_NAME DB_VOLUME
    REALM_ID REALM_PORT WORLD_PORT REALM_ADDRESS REALM_NAME REALM_ZONE
    GAME_TYPE PLAYER_LIMIT WOW_PATCH MOTD XP_RATE DROP_RATE
    WRONG_PASS_MAX_COUNT WRONG_PASS_BAN_TIME WRONG_PASS_BAN_TYPE
    REQ_EMAIL_VERIFICATION STRICT_VERSION_CHECK WARDEN_ENABLED STRICT_PLAYER_NAMES
    IMAGE_TAG SERVER_CONTAINER_NAME K8S_NAMESPACE CUSTOM_SQL
    K8S_STORAGE_TYPE K8S_DATA_HOSTPATH K8S_DB_HOSTPATH K8S_STORAGECLASS
    DB_TRANSPORT SERVER_TRANSPORT DB_POD_SELECTOR SERVER_POD_SELECTOR SERVER_FIFO
    DB_SSH_HOST SERVER_SSH_HOST SERVER_K8S_CONTAINER MANAGED_EXTERNALLY
)

_settings() {
    # Paths the front-end may hand over with a literal leading '~' (a quoted
    # 'set SOURCE_DIR ~/x' never reaches the shell's own tilde expansion) —
    # expand it the same way CONFIG_DIR is, so it isn't mkdir'd/mounted as a
    # directory literally named '~'.
    SOURCE_DIR="$(cfg_default SOURCE_DIR "${HOME}/jaws/MaNGOS")"
    SOURCE_DIR="${SOURCE_DIR/#\~/$HOME}"
    CLIENT_BUILD="$(cfg_default CLIENT_BUILD "$CLIENT_BUILD_DEFAULT")"
    DB_HOST="$(cfg_default DB_HOST 127.0.0.1)"
    DB_PORT="$(cfg_default DB_PORT 3306)"
    DB_USER="$(cfg_default DB_USER root)"
    DB_PASS="$(cfg_default DB_PASS root)"
    # DB_VOLUME's default intentionally still says vanilla-wow-mariadb-data —
    # this is the same underlying server, just ported to its own repo/name;
    # the container was adopted via `docker rename`, not recreated, so the
    # actual volume backing it really is still called that. Renaming a
    # Docker volume isn't a thing (would need create+copy), so the default
    # here just needs to keep matching reality, not the project's new name.
    DB_CONTAINER_NAME="$(cfg_default DB_CONTAINER_NAME nordrassil-mariadb)"
    DB_VOLUME="$(cfg_default DB_VOLUME vanilla-wow-mariadb-data)"

    # TRANSPORTS. How to reach the database and how to reach mangosd are two
    # independent questions, and conflating them is what made this script
    # unable to describe a real deployment: the kuat homelab runs the server
    # as a k8s Deployment while its MariaDB is a podman quadlet on the host,
    # so no single local/docker/k8s answer is correct for it.
    #
    #   DB_TRANSPORT      auto | docker | kubectl | tcp
    #   SERVER_TRANSPORT  auto | local  | docker  | kubectl
    #
    # 'auto' keeps the pre-split behaviour: probe for a running local
    # container first, then the cluster, then a TCP endpoint. Set either
    # explicitly to point this script at a deployment it cannot guess.
    #
    # 'tcp' uses DB_HOST/DB_PORT, which until now were only ever written into
    # the rendered conf files — the server's own connection string — and never
    # used for this script's queries. It needs a mariadb client on this host.
    DB_TRANSPORT="$(cfg_default DB_TRANSPORT auto)"
    SERVER_TRANSPORT="$(cfg_default SERVER_TRANSPORT auto)"
    # Label selectors and the console FIFO path are settings rather than
    # constants for the same reason: they were hardcoded to this project's own
    # k8s templates, so any other deployment's pods were simply invisible.
    DB_POD_SELECTOR="$(cfg_default DB_POD_SELECTOR app=vanilla-wow-mariadb)"
    SERVER_POD_SELECTOR="$(cfg_default SERVER_POD_SELECTOR app=vanilla-wow-server)"
    # Where mangosd's console FIFO lives INSIDE the container. This repo's
    # image puts it at /app; kuat's azeroth image uses /opt/azeroth.
    SERVER_FIFO="$(cfg_default SERVER_FIFO /app/mangosd.stdin)"
    # SSH is a THIRD axis, orthogonal to both transports: it says where the
    # orchestrator runs, not which one. 'kubectl' + SERVER_SSH_HOST=meksha
    # runs kubectl on meksha; 'podman' + DB_SSH_HOST=meksha runs podman
    # there. Treating remoteness as another transport value would multiply
    # the cases instead of adding one, and nothing about reaching a docker
    # socket changes because the socket is on another machine.
    #
    # Empty means local. Needs key-based ssh: every call is BatchMode.
    DB_SSH_HOST="$(cfg_default DB_SSH_HOST "")"
    SERVER_SSH_HOST="$(cfg_default SERVER_SSH_HOST "")"
    # Which container in the server pod holds mangosd. Empty lets kubectl
    # pick, which is right but makes it print "Defaulted container ... out
    # of: ..." to stderr on every single exec when the pod has init
    # containers — noise on top of real output. Naming it silences that.
    SERVER_K8S_CONTAINER="$(cfg_default SERVER_K8S_CONTAINER "")"
    # MANAGED_EXTERNALLY=1 says this profile describes a server something
    # ELSE provisions — Ansible, a GitOps controller, a CI pipeline. This
    # script may then administer it (accounts, SQL, dumps, restarts) but must
    # not provision it: see _refuse_if_managed.
    #
    # Validated strictly rather than tested for truthiness. The dangerous
    # direction is a typo reading as "not managed", so anything that is not
    # exactly 0 or 1 is treated as 1 — provisioning refused.
    #
    # Treated, not rejected: this check used to error_exit, and _settings runs
    # before anything else in every command, so a stored 'yes' took out the
    # whole tool — 'set MANAGED_EXTERNALLY 0' died here too, which left the
    # config file and an editor as the only way back. cfg_set now refuses the
    # value outright, so this path only exists for a file that is already in
    # that state, or one edited by hand.
    MANAGED_EXTERNALLY="$(cfg_default MANAGED_EXTERNALLY 0)"
    if [[ ! "$MANAGED_EXTERNALLY" =~ ^[01]$ ]]; then
        warn "MANAGED_EXTERNALLY='${MANAGED_EXTERNALLY}' is not 0 or 1 — treating it as 1, so provisioning is refused."
        warn "Fix it with: ${0##*/} ${PROFILE:+--profile ${PROFILE} }set MANAGED_EXTERNALLY 0"
        MANAGED_EXTERNALLY=1
    fi
    REALM_ID="$(cfg_default REALM_ID 1)"
    REALM_PORT="$(cfg_default REALM_PORT 3724)"
    WORLD_PORT="$(cfg_default WORLD_PORT 8085)"
    REALM_ADDRESS="$(cfg_default REALM_ADDRESS "$(_detect_lan_ip)")"
    REALM_NAME="$(cfg_default REALM_NAME "VanillaWoW")"
    REALM_ZONE="$(cfg_default REALM_ZONE 1)"
    GAME_TYPE="$(cfg_default GAME_TYPE 1)"  # matches the repack's own stock default (1 = PvP)
    PLAYER_LIMIT="$(cfg_default PLAYER_LIMIT 100)"
    # WowPatch: content/progression cap (quest, NPC, dungeon, raid data) —
    # distinct from CLIENT_BUILD (what the compiled binary itself supports).
    # 10 = patch 1.12, matching the CLIENT_BUILD_DEFAULT (5875) target.
    WOW_PATCH="$(cfg_default WOW_PATCH 10)"
    MOTD="$(cfg_default MOTD "Welcome to ${REALM_NAME}!")"
    XP_RATE="$(cfg_default XP_RATE 1)"
    DROP_RATE="$(cfg_default DROP_RATE 1)"
    # realmd.conf security/behavior settings — all match the repack's own
    # stock defaults unless changed in 'configure'.
    WRONG_PASS_MAX_COUNT="$(cfg_default WRONG_PASS_MAX_COUNT 0)"
    WRONG_PASS_BAN_TIME="$(cfg_default WRONG_PASS_BAN_TIME 600)"
    WRONG_PASS_BAN_TYPE="$(cfg_default WRONG_PASS_BAN_TYPE 0)"
    REQ_EMAIL_VERIFICATION="$(cfg_default REQ_EMAIL_VERIFICATION 0)"
    STRICT_VERSION_CHECK="$(cfg_default STRICT_VERSION_CHECK 1)"
    # Warden anti-cheat — matches the repack's own stock default (enabled).
    # Controls both Warden.WinEnabled/Warden.OSXEnabled together, a private
    # LAN server has no real use for per-platform cheat detection control.
    WARDEN_ENABLED="$(cfg_default WARDEN_ENABLED 1)"
    # StrictPlayerNames — matches the repack's own stock default (disabled).
    # As of the strict-player-names-gate-reserved-check.patch applied during
    # build (see _apply_source_patches), 0 also disables the DBC-based
    # profanity/reserved-name check, not just the character-set check —
    # before that patch, that check ran unconditionally regardless of this
    # setting.
    STRICT_PLAYER_NAMES="$(cfg_default STRICT_PLAYER_NAMES 0)"
    IMAGE_TAG="$(cfg_default IMAGE_TAG vanilla-wow-server:latest)"
    SERVER_CONTAINER_NAME="$(cfg_default SERVER_CONTAINER_NAME vanilla-wow-server)"
    K8S_NAMESPACE="$(cfg_default K8S_NAMESPACE vanilla-wow)"
    # Optional sql/Custom scripts to apply during configure, as a comma- or
    # space-separated list of basenames (without .sql). The front-end lets the
    # operator pick from what's available; empty = apply none.
    CUSTOM_SQL="$(cfg_default CUSTOM_SQL "")"
    # k8s storage (set by the front-end): hostpath | storageclass, + paths/class.
    K8S_STORAGE_TYPE="$(cfg_default K8S_STORAGE_TYPE hostpath)"
    K8S_DATA_HOSTPATH="$(cfg_default K8S_DATA_HOSTPATH "${SOURCE_DIR}/data")"
    K8S_DATA_HOSTPATH="${K8S_DATA_HOSTPATH/#\~/$HOME}"
    K8S_DB_HOSTPATH="$(cfg_default K8S_DB_HOSTPATH /var/vanilla-wow-mariadb)"
    K8S_DB_HOSTPATH="${K8S_DB_HOSTPATH/#\~/$HOME}"
    K8S_STORAGECLASS="$(cfg_default K8S_STORAGECLASS "")"
}

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

# _resolve_ace_root — echoes a usable ACE_ROOT and returns 0, checking (in
# priority order): an already-exported ACE_ROOT, the Debian/Ubuntu package
# location, then the from-source build this script maintains under
# ACE_DEPS_DIR (see _build_ace_from_source). Echoes nothing and returns 1 if
# none are usable. No install/messaging side effects, so both install-deps
# (_ensure_ace) and the build itself (_build_native) can check without
# duplicating the lookup.
_resolve_ace_root() {
    [[ -n "${ACE_ROOT:-}" && -f "${ACE_ROOT}/ace/ACE.h" ]] && { echo "$ACE_ROOT"; return 0; }
    [[ -f /usr/include/ace/ACE.h ]] && { echo "/usr/include/ace"; return 0; }
    [[ -f "${ACE_DEPS_DIR}/ace/ACE.h" ]] && { echo "$ACE_DEPS_DIR"; return 0; }
    return 1
}

_ace_present() { _resolve_ace_root &>/dev/null; }

# _build_ace_from_source — builds ACE via its own classic Linux GNU
# makefiles (the same mechanism the official ACE-INSTALL docs describe),
# in place under ACE_DEPS_DIR — no 'make install', nothing touches the
# system outside this directory. FindACE.cmake only needs ACE_ROOT pointed at it
# (it checks "$ACE_ROOT/ace/ACE.h" for the header and "$ACE_ROOT/lib" for
# the library), which _resolve_ace_root wires up automatically once this
# has run once. Verified against this project's actual FindACE.cmake and a
# real cmake configure — ACE 8.0.7 is found and linked with no changes
# needed on the VMaNGOS side (cmake auto-bumps to C++17 for it).
_build_ace_from_source() {
    [[ -f "${ACE_DEPS_DIR}/ace/ACE.h" && -f "${ACE_DEPS_DIR}/lib/libACE.so" ]] \
        && { info "ACE ${ACE_BUILD_VERSION} already built at ${ACE_DEPS_DIR}."; return 0; }

    info "No ACE package available for this distro — building ACE ${ACE_BUILD_VERSION} from source instead (one-time, a few minutes)."

    local ver_us="${ACE_BUILD_VERSION//./_}"
    local url="https://github.com/DOCGroup/ACE_TAO/releases/download/ACE%2BTAO-${ver_us}/ACE-${ACE_BUILD_VERSION}.tar.gz"
    local deps_dir; deps_dir="$(dirname "$ACE_DEPS_DIR")"
    local tarball="${deps_dir}/ACE-${ACE_BUILD_VERSION}.tar.gz"

    mkdir -p "$deps_dir"
    rm -rf "$ACE_DEPS_DIR"

    info "Downloading ACE ${ACE_BUILD_VERSION}..."
        curl -fsSL -o "$tarball" "$url" \
        || { warn "Failed to download ACE source from ${url}."; return 1; }

    info "Extracting ACE..."
        tar -xzf "$tarball" -C "$deps_dir" \
        || { warn "Failed to extract ACE tarball."; return 1; }
    rm -f "$tarball"

    echo '#include "ace/config-linux.h"' > "${ACE_DEPS_DIR}/ace/config.h"
    echo 'include $(ACE_ROOT)/include/makeinclude/platform_linux.GNU' \
        > "${ACE_DEPS_DIR}/include/makeinclude/platform_macros.GNU"

    local jobs; jobs="$(nproc 2>/dev/null || echo 2)"
    info "Building ACE (make -j${jobs})..."
        bash -c "cd '${ACE_DEPS_DIR}/ace' && ACE_ROOT='${ACE_DEPS_DIR}' make -j${jobs}" \
        || { warn "ACE build failed. See output above."; return 1; }

    [[ -f "${ACE_DEPS_DIR}/lib/libACE.so" ]] \
        || { warn "ACE build finished but libACE.so wasn't produced — something went wrong."; return 1; }
    success "ACE ${ACE_BUILD_VERSION} built at ${ACE_DEPS_DIR}."
}

_ensure_ace() {
    _ace_present && { info "ACE toolkit found."; return 0; }

    local pm; pm="$(_pkg_manager)"
    if [[ "$pm" == "apt" ]]; then
        _require_sudo_or_instruct "Installing libace-dev" "sudo apt-get update -qq && sudo apt-get install -y libace-dev"
        sudo apt-get update -qq && sudo apt-get install -y libace-dev \
            && { success "libace-dev installed."; return 0; }
        warn "libace-dev install failed — falling back to building ACE from source."
    fi

    _build_ace_from_source && return 0

    warn "Could not get a working ACE toolkit (a hard build dependency for local native builds) on ${pm:-this distro}."
    warn "The Docker path (build-image/run-docker/run-k8s) doesn't need it at all — it always builds inside an"
    warn "Ubuntu stage regardless of host OS. Use that instead if this keeps failing."
    return 1
}

cmd_install_deps() {
    header "nordrassil — Install dependencies"

    info "Build toolchain (for the local native path)..."
    # git: _apply_source_patches (git apply); make: the cmake build and the
    # ACE from-source build; unzip: _unpack_source; curl/tar: the ACE download.
    _ensure_pkg git    git    git
    _ensure_pkg cmake  cmake  cmake
    _ensure_pkg g++    gcc-c++ g++
    _ensure_pkg make   make   make
    _ensure_pkg unzip  unzip  unzip
    _ensure_pkg curl   curl   curl
    _ensure_pkg tar    tar    tar
    _ensure_pkgs "tbb-devel mariadb-devel openssl-devel zlib-ng-compat-devel" \
                 "libtbb-dev default-libmysqlclient-dev libssl-dev zlib1g-dev"
    _layer_rpm_ostree_pending
    if [[ ${#RPM_OSTREE_PENDING[@]} -gt 0 ]]; then
        # The toolchain just layered isn't usable until the reboot, so the
        # ACE from-source build would only fail here — deferred to the re-run.
        warn "Skipping the ACE check until after the reboot."
    else
        _ensure_ace || true
    fi

    info "Docker (required for the DB container and the Docker/k8s deployment paths)..."
    _check_docker

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# DB bootstrap — shared by 'configure' (local) and the k8s db-init Job
# -----------------------------------------------------------------------------

# The mariadb client reads its password from MYSQL_PWD when no -p is given,
# and 'docker exec -e NAME' (no '=value') forwards the variable from this
# process's own environment — so the password reaches the client without ever
# appearing in an argument vector. '-p"$DB_PASS"' put it in the docker CLI's
# argv, i.e. in every 'ps' on this host, for any user, for the whole
# (multi-minute, during a world-dump import) lifetime of the call.
#
# What remains: the value is in this script's and the docker CLI's
# environment, readable through /proc/<pid>/environ by the same user and by
# root — not by everyone, and not by a casual 'ps'. Removing that too would
# mean not handing the password to a client process at all.

# -----------------------------------------------------------------------------
# Transports
#
# Two independent axes. See the DB_TRANSPORT note in _settings for why: a
# deployment can perfectly well run its server in k8s and its database
# somewhere else entirely, and the single local/docker/k8s answer this script
# used to insist on could not express that.
# -----------------------------------------------------------------------------

# _shq <string> — single-quote one argument for a remote POSIX shell.
# _shq_argv <argv...> — the same for a whole command line.
#
# ssh does NOT take an argv. It joins its arguments with spaces and hands the
# resulting STRING to a shell on the far side, which parses it again. So
#   ssh h sh -c 'cat > /x'
# arrives as `sh -c cat > /x` and the redirect happens in the login shell,
# writing /x on the remote host instead of inside the container. Anything
# sent over ssh has to be quoted for that second parse. Single quotes with
# '\'' for embedded quotes is the POSIX-portable form; bash's printf %q is
# not, and the remote end is whatever login shell the user has.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
_shq_argv() { local a q=""; for a in "$@"; do q+="$(_shq "$a") "; done; printf '%s' "$q"; }

# _remote_run <host> <argv...> — run a command on another host. stdin is
# forwarded; callers that must not consume it redirect </dev/null, the same
# discipline as _db_client vs _db_client_stdin.
_remote_run() {
    local host="$1"; shift
    ssh -o BatchMode=yes "$host" "$(_shq_argv "$@")"
}

# _remote_pw_run <host> <want_stdin> <password> <argv...> — as above, but
# delivers a password through the remote shell's environment rather than its
# argv, by sending it as the first line of stdin and having the far side
# read exactly that one line. A password in a remote command string would be
# visible in `ps` on that host, which is the thing the local paths already
# take care to avoid.
_remote_pw_run() {
    local host="$1" want_stdin="$2" pw="$3"; shift 3
    # Declared then assigned: in one statement the exit status would be
    # local's, not _shq_argv's (SC2155), so a quoting failure would be invisible.
    local remote
    remote="IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec $(_shq_argv "$@")"
    if [[ -n "$want_stdin" ]]; then
        { printf '%s\n' "$pw"; cat; } | ssh -o BatchMode=yes "$host" "$remote"
    else
        printf '%s\n' "$pw" | ssh -o BatchMode=yes "$host" "$remote"
    fi
}

# _kube <ssh host or empty> <kubectl args...> — kubectl, here or there.
# stdin is forwarded; see _remote_run.
_kube() {
    local host="$1"; shift
    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    if [[ -z "$host" ]]; then
        command -v kubectl &>/dev/null || {
            warn "kubectl not found on this host. Set DB_SSH_HOST/SERVER_SSH_HOST to run it on the server instead."
            return 1
        }
        # shellcheck disable=SC2086
        kubectl $ctx_flags "$@"
    else
        # shellcheck disable=SC2086
        _remote_run "$host" kubectl $ctx_flags "$@"
    fi
}

# _db_password — the password to authenticate with, prompting if asked to.
#
# DB_PASS=ask means "prompt, once per session, per profile". The answer is
# cached in $XDG_RUNTIME_DIR, which is tmpfs, mode 0700 and owned by this
# user: it survives for the login session and is gone on logout or reboot,
# which is the lifetime wanted. With no XDG_RUNTIME_DIR there is nowhere
# appropriate to put it, so it prompts every time rather than writing a
# password into a persistent file.
#
# Prompting reads and writes /dev/tty, never stdin/stdout: callers run
# queries inside $(...) and pipe SQL in, so a prompt on either would end up
# captured as query output or eaten as SQL.
# _db_pw_cache_dir — a tmpfs directory to keep the session password in, or
# nothing.
#
# $XDG_RUNTIME_DIR first; /run/user/<uid> when it is unset but present, which
# is the same directory under its usual name and covers a shell started
# without a session environment. Nothing else is offered: /tmp is shared and
# survives a logout, and a password is not worth putting there to save a
# prompt.
_db_pw_cache_dir() {
    local base="${XDG_RUNTIME_DIR:-}"
    [[ -n "$base" ]] || base="/run/user/$(id -u)"
    [[ -d "$base" && -w "$base" ]] || return 1
    install -d -m 0700 "${base}/nordrassil" 2>/dev/null || return 1
    printf '%s' "${base}/nordrassil"
}

# _db_password_check <candidate> — 0 it authenticates, 1 it is refused,
# 2 cannot tell.
#
# Three states for the same reason _db_is_applied has three: "no" and "do not
# know" are different answers. A refused password must not be cached; an
# unreachable database says nothing about the password and must not cause one
# to be thrown away.
#
# _DB_PW_OVERRIDE breaks the recursion — _db_password is what _db_run calls to
# get a password, so verifying by running a query would otherwise call back
# into here. Exported for the command, so the subshells _db_run spawns see it.
_db_password_check() {
    local err
    err="$(_DB_PW_OVERRIDE="$1" _db_query_raw "SELECT 1;" 2>&1 >/dev/null)" && return 0
    case "$err" in
        *"Access denied"*|*"access denied"*) return 1 ;;
        *) return 2 ;;
    esac
}

# _db_prompt_password — read a password from the terminal.
#
# Split out from _db_password so the verify-then-cache policy around it can be
# tested: a test can replace this and _db_password_check and then assert what
# reaches the cache file, which is not possible while the prompt needs a tty.
_db_prompt_password() {
    # OPENED, not stat'ed. '[[ -r /dev/tty && -w /dev/tty ]]' tests the
    # permission bits on the device node, which are fine even for a process
    # with no controlling terminal — so under setsid, cron or a detached
    # service the guard PASSED, each of the three redirections below then
    # failed with a raw "/dev/tty: No such device or address" from bash, and
    # the function finally reported "No password entered", which is not what
    # happened. Measured, not assumed.
    #
    # The probe is a subshell so a failed redirection cannot take the caller
    # with it, and so bash's own error message stays out of the output.
    ( : <>/dev/tty ) 2>/dev/null || {
        warn "DB_PASS=ask needs a terminal to prompt on, and there is none."
        warn "  set DB_PASS explicitly for non-interactive use."
        return 1
    }
    # Initialised: bash 5 sets it to the empty string when read hits EOF, but
    # bash 3.2 — which macOS ships, and which this script supports — leaves it
    # unset, so the test below died with 'pw: unbound variable' under set -u
    # instead of saying no password was entered.
    local pw=""
    printf 'Database password for %s: ' "${PROFILE:-default}" >/dev/tty
    IFS= read -rs pw </dev/tty || true
    printf '\n' >/dev/tty
    [[ -n "$pw" ]] || { warn "No password entered."; return 1; }
    printf '%s' "$pw"
}

_db_password() {
    # Set only by _db_password_check, to break the recursion described there.
    [[ -z "${_DB_PW_OVERRIDE:-}" ]] || { printf '%s' "$_DB_PW_OVERRIDE"; return 0; }
    [[ "$DB_PASS" != "ask" ]] && { printf '%s' "$DB_PASS"; return 0; }

    local cache="" dir
    if dir="$(_db_pw_cache_dir)"; then
        cache="${dir}/${PROFILE:-default}.dbpass"
        [[ -f "$cache" ]] && { cat "$cache"; return 0; }
    fi

    local pw
    pw="$(_db_prompt_password)" || return 1

    # Verified BEFORE it is cached. A typo used to be written to the cache and
    # then reused by every command for the rest of the session, each one
    # failing with "Access denied" and none of them explaining why — the fix
    # was to know to run 'forget'.
    _db_password_check "$pw"
    case $? in
        0)  if [[ -n "$cache" ]]; then
                # umask in a subshell so the file cannot exist group- or
                # world-readable even momentarily.
                ( umask 077; printf '%s' "$pw" >"$cache" )
            else
                warn "No tmpfs directory to cache the password in (XDG_RUNTIME_DIR unset and"
                warn "  /run/user/$(id -u) unusable) — every command will prompt again."
            fi
            ;;
        1)  warn "That password was refused by the database. Nothing was cached."
            return 1
            ;;
        *)  warn "Could not verify the password (the database did not answer) — not caching it."
            ;;
    esac
    printf '%s' "$pw"
}

# _kube_pick_pod <label selector> — one Running, non-terminating pod name.
#
# Deliberately NOT `jsonpath={.items[0].metadata.name}`, which is what the
# rest of this script used to do: .items[0] is simply the first pod the API
# returns, which during a rollout is as likely to be a Terminating one as the
# live one — and exec'ing into a pod that is going away fails in a way that
# reads like a connection problem. A terminating pod still reports phase
# Running, so the phase alone is not enough; a deletionTimestamp is the thing
# that distinguishes it, hence the two-field line and `NF==1`.
_kube_pick_pod() {
    local selector="$1" host="${2:-}" pod
    pod="$(_kube "$host" get pods -n "$K8S_NAMESPACE" -l "$selector" \
             --field-selector=status.phase=Running \
             -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
             </dev/null 2>/dev/null \
           | awk 'NF==1{print $1; exit}')" || pod=""
    [[ -n "$pod" ]] || {
        warn "No Running pod matching '${selector}' in namespace ${K8S_NAMESPACE}${host:+ on ${host}}."
        return 1
    }
    printf '%s' "$pod"
}

# _container_state <docker|podman> <ssh host or empty> <name> — a container's
# status, asked of the engine that actually holds it. --type container because
# SERVER_CONTAINER_NAME and IMAGE_TAG share a base name and a plain inspect
# falls back to matching images, which would report an unrelated image's state
# instead of "not created".
_container_state() {
    local engine="$1" host="$2" name="$3" out
    if [[ -z "$host" ]]; then
        out="$("$engine" inspect --type container "$name" --format='{{.State.Status}}' 2>/dev/null)" || out=""
    else
        out="$(_remote_run "$host" "$engine" inspect --type container "$name" \
                 --format='{{.State.Status}}' </dev/null 2>/dev/null)" || out=""
    fi
    printf '%s' "${out:-not created}"
}

# _db_transport — echoes the resolved DB transport, autodetecting when 'auto'.
_db_transport() {
    case "$DB_TRANSPORT" in
        docker|podman|kubectl|tcp) printf '%s' "$DB_TRANSPORT"; return 0 ;;
        auto) ;;
        *) error_exit "DB_TRANSPORT must be auto|docker|podman|kubectl|tcp (got '${DB_TRANSPORT}')." ;;
    esac

    # Probing across ssh would mean several round trips on every invocation,
    # and guessing is the wrong default for a machine that is not this one.
    [[ -z "$DB_SSH_HOST" ]] || error_exit \
        "DB_TRANSPORT=auto cannot probe a remote host; set it to docker|podman|kubectl|tcp for DB_SSH_HOST=${DB_SSH_HOST}."

    # Probe order preserves the behaviour from before the split: the local
    # container was the only thing the DB helpers ever looked at, so it stays
    # first and an existing setup keeps working untouched.
    if [[ "$(docker inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]]; then
        printf 'docker'; return 0
    fi
    if [[ "$(podman inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]]; then
        printf 'podman'; return 0
    fi
    if command -v kubectl &>/dev/null; then
        local ctx_flags; ctx_flags="$(kubectl_context_flag)"
        # shellcheck disable=SC2086
        if kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l "$DB_POD_SELECTOR" --no-headers 2>/dev/null | grep -q Running; then
            printf 'kubectl'; return 0
        fi
    fi
    if command -v mariadb &>/dev/null \
       && timeout 3 bash -c "echo >/dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
        printf 'tcp'; return 0
    fi

    warn "No reachable database found."
    warn "  checked: container '${DB_CONTAINER_NAME}' (docker, podman), pods '${DB_POD_SELECTOR}' in ${K8S_NAMESPACE}, tcp ${DB_HOST}:${DB_PORT}"
    warn "  set DB_TRANSPORT (docker|podman|kubectl|tcp) and DB_HOST/DB_PORT to point at it explicitly."
    return 1
}

# _refuse_if_managed <command> — the guard for anything that provisions,
# destroys or re-bootstraps a server.
#
# Blocked in the ENGINE and not only in the front-end: a front-end-only check
# leaves the same mistake available to any script, and the engine is what
# holds the destructive power. The worst of these is not a deploy command at
# all — 'configure' re-runs the world import, and on a database this script
# did not bootstrap (no marker directory, realmd.account already present)
# _db_seed_applied_from_markers warns and lets every import run again, over
# live data.
# _is_local_db_host — whether DB_HOST names this machine.
_is_local_db_host() {
    case "${DB_HOST:-}" in
        ""|localhost|localhost.localdomain|127.*|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

# _refuse_if_remote <command> — the guard for provisioning a target this
# machine does not own.
#
# The transports say WHERE the database and the server are. Provisioning never
# consulted them: 'run-docker' drives the LOCAL docker socket, 'run-k8s' and
# 'stop-k8s' drive whatever kube context happens to be current, 'configure'
# writes conf files on THIS host, and 'build-image' builds an image only this
# host can see. Point a profile at another machine and every one of them still
# acts here — on the machine this was reviewed on the ambient context was an
# AWS EKS cluster, so 'run-k8s' with a homelab profile would have deployed to
# it.
#
# Refusing rather than routing. Routing means teaching six commands to run
# kubectl and docker over ssh, which is the file split's job; refusing costs a
# few lines and closes the hole now. The commands that ADMINISTER a remote
# server — accounts, characters, search, apply-sql, dump, restore, restart,
# status — already honour the transports and are untouched.
_refuse_if_remote() {
    local cmd="$1" why=""
    [[ -z "${SERVER_SSH_HOST:-}" ]] || why="SERVER_SSH_HOST=${SERVER_SSH_HOST}"
    [[ -z "${DB_SSH_HOST:-}" ]]     || why="${why:+${why}, }DB_SSH_HOST=${DB_SSH_HOST}"
    # kubectl is only suspect when no cluster was named: with --kind or
    # --context the operator has said which one, and a local kind cluster is a
    # workflow run-k8s supports on purpose. Without either it is the ambient
    # context, which is whatever the last tool to touch ~/.kube/config left
    # behind.
    if [[ "${SERVER_TRANSPORT:-}" == "kubectl" && -z "$KUBE_CONTEXT" && -z "$KIND_CLUSTER" ]]; then
        why="${why:+${why}, }SERVER_TRANSPORT=kubectl with no --context/--kind"
    fi
    if [[ "${DB_TRANSPORT:-}" == "tcp" ]] && ! _is_local_db_host; then
        why="${why:+${why}, }DB_TRANSPORT=tcp to ${DB_HOST}"
    fi
    [[ -n "$why" ]] || return 0

    warn "'${cmd}' provisions a server on THIS machine: the local docker socket, the"
    warn "ambient kube context, conf files here, an image only this host can see."
    warn "This profile${PROFILE:+ (${PROFILE})} describes a server somewhere else — ${why}."
    warn "Administration still works and honours the transports: accounts, characters,"
    warn "search, apply-sql, dump, restore, restart, status."
    error_exit "Refusing to run '${cmd}' locally for a profile that points elsewhere."
}

# _announce_kube_target — say which cluster is about to be changed.
#
# _refuse_if_remote covers the case where the profile says the server is
# elsewhere. This covers the one where nothing says anything: with no
# --context/--kind, kubectl uses the ambient context, which is whatever the
# last tool to touch ~/.kube/config left behind. Printing it is the difference
# between "deployed" and "deployed to the cluster you meant".
_announce_kube_target() {
    local ctx
    if [[ -n "$KIND_CLUSTER" ]]; then
        ctx="kind-${KIND_CLUSTER} (--kind)"
    elif [[ -n "$KUBE_CONTEXT" ]]; then
        ctx="${KUBE_CONTEXT} (--context)"
    else
        ctx="$(kubectl config current-context 2>/dev/null || true)"
        ctx="${ctx:-<none set>} (ambient — no --context/--kind given)"
    fi
    warn "kube context: ${ctx}   namespace: ${K8S_NAMESPACE}"
}

_refuse_if_managed() {
    [[ "$MANAGED_EXTERNALLY" == "1" ]] || return 0
    warn "'${1}' provisions or re-bootstraps a server, and this profile${PROFILE:+ (${PROFILE})} is marked"
    warn "MANAGED_EXTERNALLY=1 — something else owns it (Ansible, a GitOps controller, CI)."
    warn "Administration still works: accounts, characters, search, apply-sql, dump, restore, restart, status."
    error_exit "Refusing to run '${1}' against an externally managed server."
}

# _db_require — resolve the transport for its side effects only, so a command
# fails with a useful message before it starts prompting for arguments.
_db_require() { _db_transport >/dev/null; }

# _db_password_new — the password for a database this command is CREATING.
#
# Resolves exactly as _db_password does. The difference is what it says: with
# DB_PASS=ask the only copy of the password is the session cache under
# $XDG_RUNTIME_DIR, which is tmpfs and gone on logout. For a query that is the
# point of 'ask' — prompt again next session. For the root password of a
# database being brought into existence it is not, because afterwards nothing
# on disk knows it. That has already happened once to this setup's 3.46
# database.
_db_password_new() {
    local pw; pw="$(_db_password)" || return 1
    if [[ "$DB_PASS" == "ask" ]]; then
        warn "DB_PASS=ask, and this password is being SET on a database being created."
        warn "  The only copy is ${XDG_RUNTIME_DIR:-<XDG_RUNTIME_DIR unset>}/nordrassil/${PROFILE:-default}.dbpass — tmpfs, gone on logout."
        warn "  Keep it somewhere, or 'set DB_PASS <value>' so this profile records it."
    fi
    printf '%s' "$pw"
}

# _announce_db_target <resolved transport> — name the server about to be
# written to, before writing to it.
#
# The other half of the mistyped-profile problem. 'restore', 'apply-sql' and
# 'dump' each printed their file and their database and never the machine, so
# a restore into the wrong server produced output indistinguishable from a
# restore into the right one. Printed from the RESOLVED transport, not the
# configured one, so 'auto' reports what it actually picked.
_announce_db_target() {
    local t="$1" where=""
    case "$t" in
        docker|podman) where="container '${DB_CONTAINER_NAME}'" ;;
        kubectl)       where="pod '${DB_POD_SELECTOR}' in ${K8S_NAMESPACE}" ;;
        tcp)           where="${DB_HOST}:${DB_PORT}" ;;
        *)             where="<unresolved>" ;;
    esac
    # Same rule as status: the ssh hop is shown only where it is used, since
    # tcp connects straight to DB_HOST and naming a host there would claim a
    # hop that does not happen.
    [[ -n "$DB_SSH_HOST" && "$t" != tcp ]] && where="${where} on ${DB_SSH_HOST} (ssh)"
    warn "target:   ${PROFILE:-<base config>} — ${t} ${where}, as ${DB_USER}"
}

# _db_client <mariadb args...> — runs the mariadb client against the
# configured database, whatever it takes to reach it. stdin is passed through,
# so callers can pipe SQL in. The single place that knows how to reach a
# database; every query helper above is a one-line wrapper over this.
_db_client() {
    _db_run "" mariadb "$@"
}

# _db_client_stdin <mariadb args...> — as above, but forwards this shell's
# stdin to the client, for piping a .sql file in.
#
# The two are separate because forwarding stdin when the caller did not ask
# for it is actively destructive: `docker exec -i` (and the `cat` in the
# kubectl path) will drain whatever stdin happens to be connected. The
# migration loop in _db_bootstrap reads its file list on stdin and calls
# _db_is_applied/_db_mark_applied per iteration, so a stdin-forwarding
# _db_exec eats the list. Measured, not theorised: a 5-line loop saw 1 line.
_db_client_stdin() {
    _db_run 1 mariadb "$@"
}

# _db_dump <mariadb-dump args...> — the dump client rather than the query
# client, reached exactly the same way. stdin is not forwarded; the dump
# comes back on stdout, which is why nothing else may be written there.
_db_dump() {
    _db_run "" mariadb-dump "$@"
}

# _db_run <want_stdin> <mariadb args...> — the single place that knows how to
# reach a database. Do not call directly; use _db_client/_db_client_stdin.
_db_run() {
    local want_stdin="$1" client="$2"; shift 2
    # Resolved once per shell. _db_transport's 'auto' probe is cheap when it
    # succeeds, but the DB bootstrap issues dozens of statements and there is
    # no reason to re-probe for each. Callers that run this inside a $(...)
    # substitution get their own subshell and so resolve once more —
    # harmless, and not worth contorting the call sites to avoid.
    if [[ -z "${_DB_T:-}" ]]; then
        _DB_T="$(_db_transport)" || return 1
    fi
    local pw; pw="$(_db_password)" || return 1

    case "$_DB_T" in
        docker|podman)
            local -a cmd=( "$_DB_T" exec )
            # -i only when the caller asked for stdin: see _db_client_stdin.
            [[ -n "$want_stdin" ]] && cmd+=( -i )
            cmd+=( -e MYSQL_PWD "$DB_CONTAINER_NAME" "$client" -u"$DB_USER" "$@" )
            if [[ -z "$DB_SSH_HOST" ]]; then
                # The password stays in this process's environment, never in
                # argv — readable through /proc by this user and root, not by
                # a casual `ps`.
                if [[ -n "$want_stdin" ]]; then
                    MYSQL_PWD="$pw" "${cmd[@]}"
                else
                    MYSQL_PWD="$pw" "${cmd[@]}" </dev/null
                fi
            else
                _remote_pw_run "$DB_SSH_HOST" "$want_stdin" "$pw" "${cmd[@]}"
            fi
            ;;
        kubectl)
            _kube_mariadb "$want_stdin" "$pw" "$client" "$@"
            ;;
        tcp)
            # --ssl-verify-server-cert=0 is explicit rather than left to the
            # client, which otherwise disables it anyway and prints a warning
            # to stderr on every single call. Saying it here keeps the output
            # of parsed queries clean and makes the choice visible: this is a
            # LAN connection to a server with no certificate of its own.
            local -a cmd=( "$client" -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER"
                           --ssl-verify-server-cert=0 "$@" )
            if [[ -n "$want_stdin" ]]; then
                MYSQL_PWD="$pw" "${cmd[@]}"
            else
                MYSQL_PWD="$pw" "${cmd[@]}" </dev/null
            fi
            ;;
    esac
}

_db_exec() {
    # _db_exec <sql>
    _db_client -e "$1"
}

_db_import() {
    # _db_import <database> <file>
    local db="$1" file="$2"
    [[ -f "$file" ]] || { warn "Missing SQL file, skipping: ${file}"; return 0; }
    _db_client_stdin "$db" < "$file"
}

_ensure_local_mariadb() {
    # RESOLVED, not $DB_PASS. DB_PASS is a setting and may hold the sentinel
    # 'ask', which the TUI offers first — and the literal string 'ask' was
    # what became the container's root password, what the ping below
    # authenticated with, and what went into the conf files and the k8s
    # Secret. Nothing failed: the database was created with a three-character
    # password, the conf files matched it, and the server started.
    local pw; pw="$(_db_password_new)" || return 1

    if docker inspect --type container "$DB_CONTAINER_NAME" &>/dev/null; then
        docker start "$DB_CONTAINER_NAME" &>/dev/null || true
    else
        info "Starting local MariaDB container '${DB_CONTAINER_NAME}'..."
        # -e NAME (no '=value'): the password comes from this process's
        # environment instead of the docker CLI's argv — see _db_exec.
        MARIADB_ROOT_PASSWORD="$pw" docker run -d \
            --name "$DB_CONTAINER_NAME" \
            -e MARIADB_ROOT_PASSWORD \
            -p "127.0.0.1:${DB_PORT}:3306" \
            -v "${DB_VOLUME}:/var/lib/mysql" \
            --restart unless-stopped \
            mariadb:11 &>/dev/null \
            || error_exit "Failed to start MariaDB container '${DB_CONTAINER_NAME}'."
    fi

    info "Waiting for MariaDB to accept connections..."
    local attempts=0
    until MYSQL_PWD="$pw" docker exec -e MYSQL_PWD "$DB_CONTAINER_NAME" mariadb-admin ping -u"$DB_USER" --silent &>/dev/null; do
        attempts=$((attempts + 1))
        [[ $attempts -ge 40 ]] && error_exit "Timed out waiting for MariaDB. Check: docker logs ${DB_CONTAINER_NAME}"
        sleep 1
    done
    success "MariaDB ready."
}

# -----------------------------------------------------------------------------
# Import bookkeeping — realmd.nordrassil_applied
#
# Which dumps/migrations have been imported is a property OF THE DATABASE, so
# that is where it is recorded: one row per applied item in
# realmd.nordrassil_applied. It used to be host-side marker files under
# CONFIG_DIR/applied-migrations, which silently lied whenever the two drifted
# apart — rename or recreate the MariaDB container (or its volume) and every
# import still looked "already done" against an empty database, leaving
# mangosd unable to start against schemas that were never created.
#
# Row names: "base", "anticheat", "world-full", "migration:<file>.sql",
# "custom:<file>.sql". Every name goes through _sql_escape, like every other
# string literal this script sends.
#
# All three helpers talk to the local MariaDB container (_db_exec/_db_query_raw
# with the "docker" target — local and docker share that one container); the
# k8s deployment keeps the same table, written by its own db-init Job.
# -----------------------------------------------------------------------------

# _db_table_exists <database> <table>
_db_table_exists() {
    local out
    out="$(_db_query_raw "SHOW TABLES FROM ${1} LIKE '$(_sql_escape "$2")';" 2>/dev/null)" || out=""
    [[ -n "$out" ]]
}

# _db_is_applied <name>
# Returns 0 = applied, 1 = not applied, 2 = the question could not be
# answered. The third state is the point of this function.
#
# It used to collapse a query ERROR into "not applied" (`|| out=""`), which is
# the dangerous direction: an unreachable database, a failed login or a
# missing table made every import look pending, so the next step re-imported
# the world dump and re-ran every Custom script on top of live data. An empty
# result and a failed query are different answers and callers need to tell
# them apart — see _db_applied_or_die.
_db_is_applied() {
    local out rc=0
    out="$(_db_query_raw "SELECT 1 FROM realmd.nordrassil_applied WHERE name='$(_sql_escape "$1")' LIMIT 1;" 2>/dev/null)" || rc=$?
    [[ $rc -eq 0 ]] || return 2
    [[ -n "$out" ]]
}

# _db_applied_or_die <name> — _db_is_applied, with "cannot tell" fatal.
#
# For every import in _db_bootstrap the alternative to knowing is writing on
# top of whatever is already there, so not knowing has to stop the run. The
# bookkeeping table is created (with its own error_exit) before the first of
# these calls, so a failure here is a real one and not a fresh database.
_db_applied_or_die() {
    local st=0
    _db_is_applied "$1" || st=$?
    [[ $st -ne 2 ]] || error_exit "Could not read the import state of '${1}' from realmd.nordrassil_applied. Refusing to continue — the next step would import on top of whatever is already in the database."
    return $st
}

# _db_mark_applied <name> — INSERT IGNORE so a re-run after a partial failure
# doesn't error out on the primary key.
_db_mark_applied() {
    _db_exec "INSERT IGNORE INTO realmd.nordrassil_applied (name) VALUES ('$(_sql_escape "$1")');" >/dev/null \
        || warn "Could not record '${1}' as applied — it will be imported again on the next run."
}

# _db_seed_applied_from_markers — one-time transition for deployments
# bootstrapped by the marker-file version of this script: the tracking table
# is brand new but realmd.account is already there, so the database really is
# populated and re-importing would be destructive. Translate whatever markers
# the host still has into rows. Without markers nothing can be seeded (the
# imports then re-run, as they would have before this table existed) — say so
# rather than failing silently.
_db_seed_applied_from_markers() {
    if ! _db_table_exists realmd account; then
        return 0  # genuinely empty database — a normal first bootstrap.
    fi
    if [[ ! -d "$MIGRATIONS_MARKER_DIR" ]]; then
        warn "The database looks bootstrapped but no import state was found (no tracking table, no ${MIGRATIONS_MARKER_DIR}) — imports below will run again."
        return 0
    fi
    local marker name seeded=0
    # The three top-level markers are dotfiles, so they need naming, not a glob.
    local -a legacy=(".base-imported:base" ".anticheat-imported:anticheat" ".world-full-imported:world-full")
    local pair
    for pair in "${legacy[@]}"; do
        [[ -f "${MIGRATIONS_MARKER_DIR}/${pair%%:*}" ]] || continue
        _db_mark_applied "${pair#*:}"; seeded=$((seeded + 1))
    done
    for marker in "${MIGRATIONS_MARKER_DIR}"/*.done; do
        [[ -e "$marker" ]] || continue          # nullglob is not set here
        name="$(basename "$marker" .done)"
        case "$name" in
            custom-*) _db_mark_applied "custom:${name#custom-}" ;;
            *)        _db_mark_applied "migration:${name}" ;;
        esac
        seeded=$((seeded + 1))
    done
    [[ $seeded -gt 0 ]] \
        && info "Migrated ${seeded} host-side import marker(s) into realmd.nordrassil_applied (${MIGRATIONS_MARKER_DIR} is no longer used)." \
        || warn "The database looks bootstrapped but no import markers were found — imports below will run again."
    return 0
}

# _db_bootstrap — creates schemas, imports Base + world dump + Migrations
# (idempotent via the realmd.nordrassil_applied table), optionally applies
# sql/Custom/*.sql.
_db_bootstrap() {
    local sql_dir="${SOURCE_DIR}/sql"
    [[ -d "$sql_dir" ]] || error_exit "sql/ directory not found under SOURCE_DIR: ${sql_dir}"

    info "Creating databases (realmd, mangos, characters, logs) if missing..."
    _db_exec "CREATE DATABASE IF NOT EXISTS realmd; CREATE DATABASE IF NOT EXISTS mangos; CREATE DATABASE IF NOT EXISTS characters; CREATE DATABASE IF NOT EXISTS logs;"

    # Import bookkeeping table (see the block above _db_bootstrap). Whether it
    # already existed has to be known BEFORE creating it: its absence on an
    # otherwise-populated database is exactly the upgrade case that needs the
    # old host-side markers translated into rows.
    local had_tracking=0
    _db_table_exists realmd nordrassil_applied && had_tracking=1
    _db_exec "CREATE TABLE IF NOT EXISTS realmd.nordrassil_applied (name VARCHAR(255) PRIMARY KEY, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" \
        || error_exit "Failed to create realmd.nordrassil_applied (the import bookkeeping table)."
    [[ $had_tracking -eq 1 ]] || _db_seed_applied_from_markers

    if ! _db_applied_or_die base; then
        info "Importing base schemas (sql/Base/*.sql)..."
        info "Importing sql/Base/logon.sql -> realmd..."
        # Was an inline 'bash -c' that redefined _db_import with the password
        # spliced into the child shell's own command line — the same argv
        # exposure, twice over. The real _db_import does exactly this.
        _db_import realmd "${sql_dir}/Base/logon.sql" \
            || error_exit "Failed to import Base/logon.sql"
        _db_import mangos     "${sql_dir}/Base/world.sql"
        _db_import characters "${sql_dir}/Base/characters.sql"
        _db_import logs       "${sql_dir}/Base/logs.sql"
        _db_mark_applied base
        success "Base schemas imported."
    else
        info "Base schemas already imported (recorded in the database) — skipping."
    fi

    # sql/Anticheat/*.sql — despite living next to the optional Custom/
    # content, this is REQUIRED: the repack's Anticheat/Warden/antispam
    # features are always compiled in and mangosd hard-crashes at startup
    # (uncaught C++ exception) if e.g. realmd.antispam_blacklist doesn't
    # exist. Same per-database file naming as Base/.
    if [[ -d "${sql_dir}/Anticheat" ]] && ! _db_applied_or_die anticheat; then
        info "Importing anticheat schemas (sql/Anticheat/*.sql) — required, not optional..."
        _db_import realmd     "${sql_dir}/Anticheat/realmd.sql"
        _db_import mangos     "${sql_dir}/Anticheat/world.sql"
        _db_import characters "${sql_dir}/Anticheat/characters.sql"
        _db_mark_applied anticheat
        success "Anticheat schemas imported."
    else
        info "Anticheat schemas already imported (recorded in the database) — skipping."
    fi

    if ! _db_applied_or_die world-full; then
        local dump="${sql_dir}/world_full_14_june_2021.sql"
        [[ -f "$dump" ]] || error_exit "World dump not found: ${dump}"
        warn "Importing the full world dump (~250MB) — this can take several minutes."
        info "Importing world_full_14_june_2021.sql..."
        # The file's existence is checked above, so _db_import's skip-if-missing
        # path can't swallow anything here.
        _db_import mangos "$dump" \
            || error_exit "Failed to import world_full_14_june_2021.sql"
        _db_mark_applied world-full
        success "World dump imported."
    else
        info "World dump already imported (recorded in the database) — skipping."
    fi

    # Migrations/ holds per-migration files for all 4 databases, distinguished
    # by suffix (_world.sql -> mangos, _characters.sql -> characters,
    # _logon.sql -> realmd, _logs.sql -> logs), each with a numeric timestamp
    # prefix. It also holds 4 pre-merged "*_db_updates.sql" aggregates (one
    # per database, presumably produced by merge.sh/merge.bat from the
    # individual files) and merge.bat/merge.sh/README — none of those have a
    # numeric prefix, and applying the aggregates on top of the individual
    # migrations would double-apply the same changes, so both are excluded
    # by requiring the ^[0-9]+_ prefix.
    local mfile mname target_db applied=0 skipped=0
    while IFS= read -r mfile; do
        [[ -z "$mfile" ]] && continue
        mname="$(basename "$mfile")"
        if _db_applied_or_die "migration:${mname}"; then
            skipped=$((skipped + 1))
            continue
        fi
        case "$mname" in
            *_world.sql)      target_db=mangos ;;
            *_characters.sql) target_db=characters ;;
            *_logon.sql)      target_db=realmd ;;
            *_logs.sql)       target_db=logs ;;
            *) warn "Skipping migration with unrecognized suffix: ${mname}"; continue ;;
        esac
        _db_import "$target_db" "$mfile" || error_exit "Migration failed: ${mname} (target db: ${target_db})"
        _db_mark_applied "migration:${mname}"
        applied=$((applied + 1))
    done < <(find "${sql_dir}/Migrations" -maxdepth 1 -name "[0-9]*.sql" 2>/dev/null | sort)
    info "Migrations: ${applied} applied, ${skipped} already up to date."

    # Custom/*.sql is a grab-bag, not one coherent feature — this repack's
    # own copy includes both ADD_GM_ISLAND_VENDORS.sql and its counterpart
    # REMOVE_GM_ISLAND_VENDORS.sql (applying both back-to-back in filename
    # order is a no-op at best), several bonus legendary items, and
    # START_ON_GM_ISLAND.sql, a one-line blanket UPDATE with no WHERE
    # clause that overwrites playercreateinfo for every race/class to the
    # same coordinates — every new character, GM or not, spawns on GM
    # Island instead of its actual racial starting zone. A single
    # "apply optional custom content?" yes/no (what this used to be) hides
    # that entirely behind vague wording ("vendors/trainers, custom items")
    # and applies everything found, found live when a user asked why every
    # character was spawning in the wrong place. Listing each file lets the
    # operator actually choose, and skips files already applied so a later
    # 'configure' run doesn't re-prompt for the same ones.
    # The engine applies exactly the scripts named in CUSTOM_SQL (comma- or
    # space-separated basenames, without .sql) — the front-end shows the operator
    # the available list (see 'list-custom') and sets this. Anything not listed is
    # skipped; files already applied (recorded in the DB) are never re-applied.
    if [[ -d "${sql_dir}/Custom" && -n "${CUSTOM_SQL:-}" ]]; then
        local want cfile st applied_custom=0 failed_custom=0
        local wanted="${CUSTOM_SQL//,/ }"
        for want in $wanted; do
            want="${want%.sql}"
            cfile="${sql_dir}/Custom/${want}.sql"
            [[ -f "$cfile" ]] || { warn "Custom script not found, skipping: ${want}.sql"; continue; }
            st=0; _db_is_applied "custom:${want}.sql" || st=$?
            if [[ $st -eq 0 ]]; then
                info "Custom already applied: ${want}.sql"; continue
            elif [[ $st -eq 2 ]]; then
                # Not fatal here, unlike the bootstrap imports: one Custom
                # script is skippable, and the rest of configure is still
                # worth finishing. Skipped rather than applied, because
                # applying it twice is the unrecoverable direction.
                warn "Cannot tell whether ${want}.sql was already applied (the tracking query failed) — skipping it."
                failed_custom=$((failed_custom + 1)); continue
            fi
            if _db_import mangos "$cfile"; then
                _db_mark_applied "custom:${want}.sql"
                info "Applied: ${want}.sql"; applied_custom=$((applied_custom + 1))
            else
                # NOT marked. It used to be marked regardless of the import's
                # exit status, so a script that failed halfway was recorded as
                # done and could never run again — including after it was
                # fixed, which is exactly when it needs to.
                warn "Custom script FAILED and was NOT recorded as applied: ${want}.sql"
                warn "  Fix it and re-run 'configure'; a partial import may need undoing by hand."
                failed_custom=$((failed_custom + 1))
            fi
        done
        [[ $applied_custom -gt 0 ]] && success "Custom content applied (${applied_custom})."
        [[ $failed_custom -gt 0 ]] && warn "Custom scripts not applied: ${failed_custom} (see above)."
    fi

    _ensure_realmlist
}

# None of the SQL dumps seed the realmlist table — the realm's reachable
# address/port is inherently deployment-specific, so every MaNGOS-family
# server needs this set by the operator. Without it mangosd refuses to start
# ("Config contains invalid realmID"). ON DUPLICATE KEY UPDATE keeps this in
# sync with the current REALM_ADDRESS/WORLD_PORT/CLIENT_BUILD on every run.
_ensure_realmlist() {
    info "Ensuring realmlist row (id=${REALM_ID}, name=${REALM_NAME}, address=${REALM_ADDRESS}:${WORLD_PORT})..."
    # Both values are operator-supplied free text (the front-end takes them
    # from a prompt) — escape them like every other string literal here.
    local name_sql addr_sql
    name_sql="$(_sql_escape "$REALM_NAME")"; addr_sql="$(_sql_escape "$REALM_ADDRESS")"
    _db_exec "INSERT INTO realmd.realmlist (id, name, address, localAddress, localSubnetMask, port, gamebuild_min, gamebuild_max)
        VALUES (${REALM_ID}, '${name_sql}', '${addr_sql}', '127.0.0.1', '255.255.255.0', ${WORLD_PORT}, ${CLIENT_BUILD}, ${CLIENT_BUILD})
        ON DUPLICATE KEY UPDATE name='${name_sql}', address='${addr_sql}', port=${WORLD_PORT}, gamebuild_min=${CLIENT_BUILD}, gamebuild_max=${CLIENT_BUILD};" \
        || error_exit "Failed to write the realmlist row."
    success "realmlist ready."
}

# -----------------------------------------------------------------------------
# Config file generation — patches the repack's stock conf files rather than
# hand-authoring new ones (they're 3000+ lines of documented settings; only a
# handful need to change for a containerized/local deployment).
# -----------------------------------------------------------------------------

# _render_mangosd_conf <src> <dst> <data_dir> <logs_dir> <warden_dir>
_render_mangosd_conf() {
    local src="$1" dst="$2" data_dir="$3" logs_dir="$4" warden_dir="$5"
    local motd_escaped; motd_escaped="$(_sed_escape "$MOTD")"
    # Everything spliced into a sed replacement below goes through
    # _sed_escape — a DB password or path containing '&', '|' or '\' would
    # otherwise corrupt the line (or, with '|', break the sed command).
    data_dir="$(_sed_escape "$data_dir")"; logs_dir="$(_sed_escape "$logs_dir")"; warden_dir="$(_sed_escape "$warden_dir")"
    # Resolved, not $DB_PASS — see _ensure_local_mariadb.
    local pw; pw="$(_db_password)" || return 1
    local db_conn; db_conn="$(_sed_escape "${DB_HOST};${DB_PORT};${DB_USER};${pw}")"
    cp "$src" "$dst"
    # The repack's conf files ship with Windows CRLF line endings (they were
    # distributed alongside .exe binaries). Left as-is, sed's substitutions
    # below strip the trailing \r only on the handful of lines they touch
    # (matched by .* and not present in the replacement) while every other
    # line keeps its \r — a mixed-line-ending file, which shows up as a wall
    # of ^M in vim/cmd_edit and is generally fragile. Normalize to LF first.
    sed -i 's/\r$//' "$dst"
    sed -i \
        -e "s|^DataDir[[:space:]]*=.*|DataDir = \"${data_dir}\"|" \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^Warden\.ModuleDir[[:space:]]*=.*|Warden.ModuleDir             = \"${warden_dir}\"|" \
        -e "s|^Warden\.WinEnabled[[:space:]]*=.*|Warden.WinEnabled            = ${WARDEN_ENABLED}|" \
        -e "s|^Warden\.OSXEnabled[[:space:]]*=.*|Warden.OSXEnabled            = ${WARDEN_ENABLED}|" \
        -e "s|^StrictPlayerNames[[:space:]]*=.*|StrictPlayerNames = ${STRICT_PLAYER_NAMES}|" \
        -e "s|^LoginDatabase\.Info[[:space:]]*=.*|LoginDatabase.Info              = \"${db_conn};realmd\"|" \
        -e "s|^WorldDatabase\.Info[[:space:]]*=.*|WorldDatabase.Info              = \"${db_conn};mangos\"|" \
        -e "s|^CharacterDatabase\.Info[[:space:]]*=.*|CharacterDatabase.Info          = \"${db_conn};characters\"|" \
        -e "s|^LogsDatabase\.Info[[:space:]]*=.*|LogsDatabase.Info               = \"${db_conn};logs\"|" \
        -e "s|^WorldServerPort[[:space:]]*=.*|WorldServerPort = ${WORLD_PORT}|" \
        -e "s|^RealmID[[:space:]]*=.*|RealmID = ${REALM_ID}|" \
        -e "s|^GameType[[:space:]]*=.*|GameType = ${GAME_TYPE}|" \
        -e "s|^RealmZone[[:space:]]*=.*|RealmZone = ${REALM_ZONE}|" \
        -e "s|^PlayerLimit[[:space:]]*=.*|PlayerLimit = ${PLAYER_LIMIT}|" \
        -e "s|^WowPatch[[:space:]]*=.*|WowPatch = ${WOW_PATCH}|" \
        -e "s|^Motd[[:space:]]*=.*|Motd = \"${motd_escaped}\"|" \
        -e "s|^Rate\.XP\.Kill[[:space:]]*=.*|Rate.XP.Kill    = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Kill\.Elite[[:space:]]*=.*|Rate.XP.Kill.Elite = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Quest[[:space:]]*=.*|Rate.XP.Quest   = ${XP_RATE}|" \
        -e "s|^Rate\.XP\.Explore[[:space:]]*=.*|Rate.XP.Explore = ${XP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Poor[[:space:]]*=.*|Rate.Drop.Item.Poor = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Normal[[:space:]]*=.*|Rate.Drop.Item.Normal = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Uncommon[[:space:]]*=.*|Rate.Drop.Item.Uncommon = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Rare[[:space:]]*=.*|Rate.Drop.Item.Rare = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Epic[[:space:]]*=.*|Rate.Drop.Item.Epic = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Legendary[[:space:]]*=.*|Rate.Drop.Item.Legendary = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Artifact[[:space:]]*=.*|Rate.Drop.Item.Artifact = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Item\.Referenced[[:space:]]*=.*|Rate.Drop.Item.Referenced = ${DROP_RATE}|" \
        -e "s|^Rate\.Drop\.Money[[:space:]]*=.*|Rate.Drop.Money = ${DROP_RATE}|" \
        "$dst"
}

# _render_realmd_conf <src> <dst> <logs_dir>
_render_realmd_conf() {
    local src="$1" dst="$2" logs_dir="$3"
    # sed-replacement escaping — see _render_mangosd_conf.
    logs_dir="$(_sed_escape "$logs_dir")"
    # Resolved, not $DB_PASS — see _ensure_local_mariadb.
    local pw; pw="$(_db_password)" || return 1
    local db_conn; db_conn="$(_sed_escape "${DB_HOST};${DB_PORT};${DB_USER};${pw}")"
    cp "$src" "$dst"
    # See the matching comment in _render_mangosd_conf — same CRLF-source,
    # mixed-line-ending issue applies here too.
    sed -i 's/\r$//' "$dst"
    sed -i \
        -e "s|^LogsDir[[:space:]]*=.*|LogsDir = \"${logs_dir}\"|" \
        -e "s|^LoginDatabaseInfo[[:space:]]*=.*|LoginDatabaseInfo = \"${db_conn};realmd\"|" \
        -e "s|^RealmServerPort[[:space:]]*=.*|RealmServerPort = ${REALM_PORT}|" \
        -e "s|^WrongPass\.MaxCount[[:space:]]*=.*|WrongPass.MaxCount = ${WRONG_PASS_MAX_COUNT}|" \
        -e "s|^WrongPass\.BanTime[[:space:]]*=.*|WrongPass.BanTime = ${WRONG_PASS_BAN_TIME}|" \
        -e "s|^WrongPass\.BanType[[:space:]]*=.*|WrongPass.BanType = ${WRONG_PASS_BAN_TYPE}|" \
        -e "s|^ReqEmailVerification[[:space:]]*=.*|ReqEmailVerification = ${REQ_EMAIL_VERIFICATION}|" \
        -e "s|^StrictVersionCheck[[:space:]]*=.*|StrictVersionCheck = ${STRICT_VERSION_CHECK}|" \
        "$dst"
}

# _effective_conf_source <filename> — prefer the already-configured copy
# under ETC_DIR (which carries both the 'configure' prompts and any manual
# `edit` tweaks) over the repack's pristine file. Used by the deploy paths
# (run-docker/run-k8s) so a hand edit isn't silently discarded on the next
# build/deploy; 'configure' itself always re-derives from the pristine
# SOURCE_DIR file, since re-establishing the baseline is its whole job.
_effective_conf_source() {
    local filename="$1"
    if [[ -f "${ETC_DIR}/${filename}" ]]; then
        echo "${ETC_DIR}/${filename}"
    else
        echo "${SOURCE_DIR}/${filename}"
    fi
}

# -----------------------------------------------------------------------------
# configure
# -----------------------------------------------------------------------------


# The value/label pickers and _prompt_server_settings were interactive (gum);
# the engine takes these as config instead. All server-identity/gameplay
# settings (REALM_NAME, REALM_ZONE, GAME_TYPE, PLAYER_LIMIT, WOW_PATCH, MOTD,
# XP_RATE, DROP_RATE, WRONG_PASS_*, REQ_EMAIL_VERIFICATION, STRICT_VERSION_CHECK,
# WARDEN_ENABLED, STRICT_PLAYER_NAMES) come from the config file — the front-end
# pushes them with 'set <KEY> <VALUE>' and _settings reads them back.

# configure — NON-INTERACTIVE. (Re)establishes the DB + local conf baseline from
# the persisted config. SOURCE_DIR and REALM_ADDRESS must already be set (the
# front-end collects them). Optional:
#   --custom "name1,name2,..."  apply exactly these sql/Custom/<name>.sql scripts
#                               (overrides the CUSTOM_SQL config value)
cmd_configure() {
    header "nordrassil — Configure"
    _settings
    _refuse_if_managed configure
    _refuse_if_remote configure
    while [[ $# -gt 0 ]]; do case "$1" in
        --custom) CUSTOM_SQL="$2"; shift 2 ;;
        *) error_exit "configure: unknown flag: $1" ;;
    esac; done

    [[ -d "$SOURCE_DIR" ]] || error_exit "SOURCE_DIR not found: ${SOURCE_DIR} (set it: nordrassil set SOURCE_DIR <path>)."
    [[ -f "${SOURCE_DIR}/mangosd.conf" && -f "${SOURCE_DIR}/realmd.conf" ]] \
        || error_exit "mangosd.conf/realmd.conf not found under ${SOURCE_DIR} — is this really the repack root?"

    _check_docker
    _ensure_local_mariadb
    _db_bootstrap

    info "Generating local conf files (native start/stop path)..."
    mkdir -p "$INSTALL_DIR"
    # DataDir/Warden.ModuleDir point straight at the repack's data/ and
    # warden_modules — local native runs directly against SOURCE_DIR.
    _render_mangosd_conf "${SOURCE_DIR}/mangosd.conf" "${ETC_DIR}/mangosd.conf" "${SOURCE_DIR}/data" "${INSTALL_DIR}/logs" "${SOURCE_DIR}/warden_modules"
    _render_realmd_conf  "${SOURCE_DIR}/realmd.conf"  "${ETC_DIR}/realmd.conf"  "${INSTALL_DIR}/logs"
    success "Conf files written to ${ETC_DIR}."

    success "Configure complete. Run 'start' to build and launch the local server."
}

# -----------------------------------------------------------------------------
# start / stop — native local build (cmake+make, cached) for fast iteration
# -----------------------------------------------------------------------------

_unpack_source() {
    if [[ ! -f "${SRC_UNPACK_DIR}/CMakeLists.txt" ]]; then
        local zip="${SOURCE_DIR}/source/Repack 25 Source.zip"
        [[ -f "$zip" ]] || error_exit "Source zip not found: ${zip}"
        mkdir -p "$SRC_UNPACK_DIR"
        info "Unpacking VMaNGOS source (one-time)..."
        info "Unzipping source..."
            unzip -q -o "$zip" -d "$SRC_UNPACK_DIR" \
            || error_exit "Failed to unpack ${zip}"
    fi

    _apply_source_patches
}

# _apply_source_patches — scomp-link-maintained fixes to the repack's own
# source, layered on top of the pristine unzip. Two so far:
#   strict-player-names-gate-reserved-check.patch — gates the DBC-based
#     profanity/reserved-name check (ValidateName, in ObjectMgr.cpp's
#     CheckPlayerName) behind StrictPlayerNames, the same setting that
#     already gates the character-set check right next to it — found live,
#     with StrictPlayerNames=0 that check still ran unconditionally on every
#     login, permanently blocking any character whose name matched an entry
#     in the client's NamesReserved.dbc/NamesProfanity.dbc (Blizzard's own
#     original content filter), with no config toggle to turn it off —
#     before this fix existed, working around it meant binary-editing the
#     DBC file itself.
#   remove-dead-ace-auto-ptr-include.patch — drops two `#include
#     <ace/Auto_Ptr.h>` lines (MangosSocketImpl.h, realmd/PatchHandler.h)
#     that don't reference anything from it (verified: no ACE_Auto_Ptr/
#     Auto_Basic_Ptr/Auto_Array_Ptr symbol appears in either file). ACE
#     dropped that header in its 8.x line — it only ever wrapped
#     std::auto_ptr, itself removed in C++17 — which is what a from-source
#     ACE build on Fedora/RHEL resolves to (see _build_ace_from_source);
#     without this patch the local native build fails on those hosts with
#     "ace/Auto_Ptr.h: No such file or directory".
# Idempotent via a marker per patch, independent of whether the unzip step
# above actually ran this time — a source tree unpacked before a given fix
# existed (already has CMakeLists.txt, skips the unzip) still gets that
# patch applied on its next build.
_apply_source_patches() {
    local patch_dir="${TEMPLATES_DIR}/patches"
    [[ -d "$patch_dir" ]] || return 0

    local patch_file pname marker_dir="${SRC_UNPACK_DIR}/.scomp-link-patches-applied"
    mkdir -p "$marker_dir"
    for patch_file in "$patch_dir"/*.patch; do
        [[ -f "$patch_file" ]] || continue
        pname="$(basename "$patch_file")"
        [[ -f "${marker_dir}/${pname}" ]] && continue

        info "Applying source patch: ${pname}"
        (cd "$SRC_UNPACK_DIR" && git apply --check "$patch_file") \
            || error_exit "Patch doesn't apply cleanly: ${pname} — the repack source may have changed, or it's already partially applied outside this marker."
        (cd "$SRC_UNPACK_DIR" && git apply "$patch_file") \
            || error_exit "Failed to apply patch: ${pname}"
        touch "${marker_dir}/${pname}"
    done
}

_build_native() {
    local ace_root
    ace_root="$(_resolve_ace_root)" \
        || error_exit "ACE toolkit not found — required for the local native build. Run 'install-deps' first (it installs the package on apt-based distros, or builds ACE from source otherwise)."
    export ACE_ROOT="$ace_root"
    export TBB_ROOT_DIR="${TBB_ROOT_DIR:-/usr/include/tbb}"

    _unpack_source
    mkdir -p "$BUILD_DIR"

    info "Configuring (cmake, client build ${CLIENT_BUILD})..."
    info "cmake configure..."
        cmake -S "$SRC_UNPACK_DIR" -B "$BUILD_DIR" \
            -DDEBUG=0 -DUSE_EXTRACTORS=0 \
            -DSUPPORTED_CLIENT_BUILD="${CLIENT_BUILD}" \
            -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        || error_exit "cmake configure failed. See output above."

    local jobs; jobs="$(nproc 2>/dev/null || echo 2)"
    info "Building (make -j${jobs}) — first build compiles ~1600 files, this takes a while..."
    info "Building mangosd/realmd..."
        bash -c "make -C '${BUILD_DIR}' -j${jobs} && make -C '${BUILD_DIR}' install" \
        || error_exit "Build failed. Re-run with 'make -C ${BUILD_DIR}' to see full compiler output."

    success "Built and installed to ${INSTALL_DIR}."
}

# mangosd/realmd both run an interactive console reader on stdin. A
# backgrounded process inherits this shell's stdin, which under a
# nohup/non-interactive invocation delivers an immediate EOF — the console
# reads that as an implicit quit, so the server fully starts and then shuts
# itself down seconds later. Each one therefore gets its own FIFO with a
# small detached 'sleep infinity' holding the write end open, so stdin never
# reaches EOF for as long as the server is meant to run (the container path
# hits the same issue — solved there with 'docker run -i' / pod stdin: true).
# mangosd's FIFO doubles as its console channel (create-account & friends
# write to it); realmd's exists purely to hold stdin open.
#
# The holder PID is recorded so 'stop' can kill it. It used to be an
# anonymous '< <(sleep infinity)' process substitution for realmd, which
# nothing tracked and nothing ever killed: every 'start' left another
# orphaned 'sleep infinity' behind, surviving 'stop' and the shell itself.
#
# _start_stdin_holder <fifo> <holder-pidfile>
_start_stdin_holder() {
    local fifo="$1" holder_pf="$2"
    rm -f "$fifo"
    mkfifo "$fifo" || error_exit "Could not create the stdin FIFO: ${fifo}"
    # exec 9<>fifo: open both ends (never blocks, never sees EOF), then
    # become 'sleep infinity' so $! is the PID that actually holds it open.
    ( exec 9<>"$fifo"; exec sleep infinity ) &
    echo "$!" > "$holder_pf"
}

# _stop_stdin_holder <fifo> <holder-pidfile>
_stop_stdin_holder() {
    local fifo="$1" holder_pf="$2"
    if [[ -f "$holder_pf" ]]; then
        kill "$(cat "$holder_pf")" 2>/dev/null || true
        rm -f "$holder_pf"
    fi
    rm -f "$fifo"
}

cmd_start() {
    header "nordrassil — Start (local)"
    _settings
    _refuse_if_managed start
    _refuse_if_remote start

    [[ -f "${ETC_DIR}/mangosd.conf" ]] || error_exit "Not configured yet — run 'configure' first."
    _ensure_local_mariadb

    if [[ ! -x "${INSTALL_DIR}/bin/mangosd" || ! -x "${INSTALL_DIR}/bin/realmd" ]]; then
        _build_native
    else
        info "Using existing build at ${INSTALL_DIR} (delete it to force a rebuild)."
    fi

    # Both binaries have their config path compiled in at build time as an
    # absolute path under CMAKE_INSTALL_PREFIX/etc (confirmed via `strings
    # install/bin/{mangosd,realmd} | grep .conf` — e.g.
    # ".../install/etc/mangosd.conf"), not the cwd they're launched from or
    # their own bin/ directory. Copying there instead of bin/ is required —
    # not a style choice.
    mkdir -p "${INSTALL_DIR}/logs" "${INSTALL_DIR}/etc"
    cp -f "${ETC_DIR}/mangosd.conf" "${INSTALL_DIR}/etc/mangosd.conf"
    cp -f "${ETC_DIR}/realmd.conf"  "${INSTALL_DIR}/etc/realmd.conf"

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"
    local realmd_fifo="${INSTALL_DIR}/bin/realmd.stdin" mangosd_fifo="${INSTALL_DIR}/bin/mangosd.stdin"

    # Both servers get a tracked FIFO + holder — see _start_stdin_holder.
    if pf_is_running "$realmd_pf"; then
        warn "realmd already running (pid file present)."
    else
        _start_stdin_holder "$realmd_fifo" "${PF_DIR}/realmd-stdin-holder.pid"
        (cd "${INSTALL_DIR}/bin" && nohup ./realmd >> "${INSTALL_DIR}/logs/realmd.out" 2>&1 < "$realmd_fifo" &
         echo "$!:${REALM_PORT}" > "$realmd_pf")
        sleep 1
        pf_is_running "$realmd_pf" && success "realmd started (port ${REALM_PORT})." || warn "realmd did not start — check ${INSTALL_DIR}/logs/realmd.out"
    fi

    if pf_is_running "$mangosd_pf"; then
        warn "mangosd already running (pid file present)."
    else
        # mangosd's FIFO is also its console channel: 'create-account' &
        # friends write command lines into it (see _send_console_cmd).
        # Unlike the container path (where entrypoint.sh's own long-lived
        # PID 1 holds the write end open for free), this command returns
        # right after backgrounding mangosd, so without the holder the FIFO
        # would report EOF on mangosd's next read.
        _start_stdin_holder "$mangosd_fifo" "${PF_DIR}/mangosd-stdin-holder.pid"

        (cd "${INSTALL_DIR}/bin" && nohup ./mangosd >> "${INSTALL_DIR}/logs/mangosd.out" 2>&1 < "$mangosd_fifo" &
         echo "$!:${WORLD_PORT}" > "$mangosd_pf")
        sleep 1
        pf_is_running "$mangosd_pf" && success "mangosd started (port ${WORLD_PORT})." || warn "mangosd did not start — check ${INSTALL_DIR}/logs/mangosd.out"
    fi

    info "Logs: ${INSTALL_DIR}/logs/{realmd,mangosd}.out"
}

cmd_stop() {
    header "nordrassil — Stop (local)"
    _settings
    _refuse_if_managed stop
    _refuse_if_remote stop

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"

    if pf_is_running "$mangosd_pf"; then pf_stop "$mangosd_pf"; else info "mangosd not running."; fi
    if pf_is_running "$realmd_pf";  then pf_stop "$realmd_pf";  else info "realmd not running.";  fi

    # The companion 'sleep infinity' holders that kept each server's stdin
    # FIFO open (see 'start') — both are killed here, and both FIFOs removed,
    # once the servers themselves are stopped. realmd's used to be an
    # untracked process substitution that 'stop' had no way to reach.
    _stop_stdin_holder "${INSTALL_DIR}/bin/mangosd.stdin" "${PF_DIR}/mangosd-stdin-holder.pid"
    _stop_stdin_holder "${INSTALL_DIR}/bin/realmd.stdin"  "${PF_DIR}/realmd-stdin-holder.pid"
}

cmd_status() {
    header "nordrassil — Status"
    _settings

    # This used to probe local docker unconditionally — `docker inspect` for
    # the database, the server container and the image — which predates
    # transports and was never migrated with the rest. The effect was that
    # status looked IDENTICAL for every profile and could never show a
    # correctly configured remote database as reachable, which reads exactly
    # like switching profiles having no effect.
    _section "Acting on"
    info "profile:  ${PROFILE:-<base config>}"

    local dbt srvt
    dbt="$(_db_transport)" || dbt=""
    srvt="$(_server_transport)" || srvt=""
    # The ssh host is only shown where it is actually used. 'tcp' connects
    # straight to DB_HOST:DB_PORT and 'local' runs here, so naming an ssh
    # host alongside either would claim a hop that does not happen — and a
    # leftover *_SSH_HOST from an earlier transport is worth pointing out
    # rather than displaying as if it were in effect.
    local db_via="" srv_via=""
    case "$dbt" in docker|podman|kubectl) [[ -n "$DB_SSH_HOST" ]] && db_via=" on ${DB_SSH_HOST} (ssh)" ;; esac
    case "$srvt" in docker|podman|kubectl) [[ -n "$SERVER_SSH_HOST" ]] && srv_via=" on ${SERVER_SSH_HOST} (ssh)" ;; esac
    info "database: ${dbt:-<unresolved>}${db_via}"
    info "server:   ${srvt:-<unresolved>}${srv_via}"
    [[ "$dbt" == tcp && -n "$DB_SSH_HOST" ]] \
        && info "          (DB_SSH_HOST=${DB_SSH_HOST} is unused by the tcp transport)"
    [[ "$srvt" == local && -n "$SERVER_SSH_HOST" ]] \
        && info "          (SERVER_SSH_HOST=${SERVER_SSH_HOST} is unused by the local transport)"

    _section "Database"
    case "$dbt" in
        docker|podman) info "${dbt} container '${DB_CONTAINER_NAME}': $(_container_state "$dbt" "$DB_SSH_HOST" "$DB_CONTAINER_NAME")" ;;
        kubectl)       info "pod '${DB_POD_SELECTOR}' in ${K8S_NAMESPACE}: $(_kube_pick_pod "$DB_POD_SELECTOR" "$DB_SSH_HOST" 2>/dev/null || echo 'none Running')" ;;
        tcp)           info "endpoint ${DB_HOST}:${DB_PORT}" ;;
        *)             warn "No database transport resolved (see above)." ;;
    esac
    if [[ -n "$dbt" ]]; then
        # The actual test. Everything above only says whether the thing
        # HOLDING the database can be reached; this says whether the database
        # answers as this user, which is what a wrong connection gets wrong.
        local ver
        if ver="$(_db_query_raw 'SELECT VERSION();' 2>/dev/null)" && [[ -n "$ver" ]]; then
            success "connected as '${DB_USER}' — MariaDB ${ver}"
            local present=""
            local d
            for d in "${NORDRASSIL_DBS[@]}"; do
                [[ -n "$(_db_query_raw "SHOW DATABASES LIKE '$(_sql_escape "$d")';" 2>/dev/null)" ]] \
                    && present+="${d} " || present+="${d}(missing) "
            done
            info "databases: ${present}"
        else
            warn "could NOT query the database as '${DB_USER}'."
            warn "  DB_TRANSPORT=${DB_TRANSPORT} DB_SSH_HOST=${DB_SSH_HOST:-<local>} DB_USER=${DB_USER}"
            warn "  tcp also needs DB_HOST/DB_PORT; docker/podman need DB_CONTAINER_NAME."
        fi
    fi

    _section "Server"
    case "$srvt" in
        local)
            pf_is_running "${PF_DIR}/realmd.pid"  && success "realmd running (port $(pf_port "${PF_DIR}/realmd.pid"))"  || info "realmd not running."
            pf_is_running "${PF_DIR}/mangosd.pid" && success "mangosd running (port $(pf_port "${PF_DIR}/mangosd.pid"))" || info "mangosd not running."
            ;;
        docker|podman)
            info "${srvt} container '${SERVER_CONTAINER_NAME}': $(_container_state "$srvt" "$SERVER_SSH_HOST" "$SERVER_CONTAINER_NAME")"
            ;;
        kubectl)
            local pod
            if pod="$(_kube_pick_pod "$SERVER_POD_SELECTOR" "$SERVER_SSH_HOST" 2>/dev/null)"; then
                success "pod ${pod} Running in ${K8S_NAMESPACE}"
            else
                warn "no Running pod matching '${SERVER_POD_SELECTOR}' in ${K8S_NAMESPACE}"
            fi
            ;;
        *) warn "No server transport resolved (see above)." ;;
    esac

    # Only meaningful for a server this host builds and runs itself.
    if [[ -z "$SERVER_SSH_HOST" && "$srvt" != "kubectl" ]]; then
        _section "Local docker image"
        docker image inspect "$IMAGE_TAG" --format='{{.Id}}' 2>/dev/null || info "Not built."
    fi

    # realmlist.wtf syntax: 'set realmlist <address>[:<port>]' — the port
    # suffix is only needed when it's non-standard, the client already
    # assumes 3724 if omitted.
    _section "Client setup"
    local realmlist_value="$REALM_ADDRESS"
    [[ "$REALM_PORT" != "3724" ]] && realmlist_value+=":${REALM_PORT}"
    info "In the client's WTF/realmlist.wtf, set:"
    printf '  set realmlist %s\n' "$realmlist_value" >&2
}

# -----------------------------------------------------------------------------
# create-account / list-accounts / delete-account — accounts live in the
# realmd DB with SRP6 verifier/salt columns, not a hash that's safe to
# compute by hand, so any command that creates or removes one goes through
# mangosd's own console instead ('account create'/'account delete', same as
# the repack's own README and the source's command table use), via the FIFO
# set up in 'start'/entrypoint.sh. Listing doesn't touch credentials at all,
# so that one queries the DB directly instead — there's no console command
# for it anyway (only 'account onlinelist', currently-connected accounts
# only, confirmed by checking the source's command table directly rather
# than guessing).
# -----------------------------------------------------------------------------

# _server_transport — echoes "local"/"docker"/"kubectl" on stdout for the
# deployment whose mangosd console this script should talk to: the
# SERVER_TRANSPORT setting if it names one, otherwise whichever is actually
# running, prompting (via --where) if more than one qualifies. warn+return 1
# if none does. Shared by every command that needs a live mangosd console.
#
# This is the SERVER half of the transport split — reaching the database is
# _db_transport's problem and resolves separately, because the two need not
# live in the same place.
_server_transport() {
    # An explicit setting wins outright. Probing can only see what this host
    # happens to reach, and "where is mangosd running" is not the same
    # question as "which deployment am I administering".
    case "$SERVER_TRANSPORT" in
        local|docker|podman|kubectl) printf '%s' "$SERVER_TRANSPORT"; return 0 ;;
        auto) ;;
        *) error_exit "SERVER_TRANSPORT must be auto|local|docker|podman|kubectl (got '${SERVER_TRANSPORT}')." ;;
    esac

    [[ -z "$SERVER_SSH_HOST" ]] || error_exit \
        "SERVER_TRANSPORT=auto cannot probe a remote host; set it to docker|podman|kubectl for SERVER_SSH_HOST=${SERVER_SSH_HOST}."

    local -a targets=()
    pf_is_running "${PF_DIR}/mangosd.pid" && targets+=("local")
    [[ "$(docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        && targets+=("docker")
    [[ "$(podman inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        && targets+=("podman")
    if command -v kubectl &>/dev/null; then
        # Same --context/--kind target as the exec path, otherwise detection
        # looks at the ambient context while the command goes to another.
        local ctx_flags; ctx_flags="$(kubectl_context_flag)"
        # shellcheck disable=SC2086
        kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l "$SERVER_POD_SELECTOR" --no-headers 2>/dev/null | grep -q Running \
            && targets+=("kubectl")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "mangosd doesn't appear to be running anywhere."
        warn "  checked: local pidfile, container '${SERVER_CONTAINER_NAME}' (docker, podman), pods '${SERVER_POD_SELECTOR}' in ${K8S_NAMESPACE}"
        warn "  set SERVER_TRANSPORT (local|docker|podman|kubectl) to name it explicitly."
        return 1
    fi

    local chosen="${targets[0]}"
    if [[ ${#targets[@]} -gt 1 ]]; then
        if [[ -n "${WHERE:-}" ]]; then
            # 'k8s' is still accepted: --where predates the transport split
            # and the gum front-end still offers that spelling.
            local w="$WHERE"; [[ "$w" == "k8s" ]] && w="kubectl"
            printf '%s\n' "${targets[@]}" | grep -qx "$w" \
                || { warn "--where '${WHERE}' isn't among the running targets: ${targets[*]}"; return 1; }
            chosen="$w"
        else
            warn "mangosd is running in more than one place (${targets[*]}). Pass --where <${targets[0]}|...> to choose."
            return 1
        fi
    fi

    # Confirm a pod is addressable before the caller commits to it.
    if [[ "$chosen" == "kubectl" ]]; then
        _kube_pick_pod "$SERVER_POD_SELECTOR" "$SERVER_SSH_HOST" >/dev/null || return 1
    fi

    printf '%s' "$chosen"
}

# Escapes a value for embedding inside a single-quoted SQL string literal
# (backslash first, so it isn't double-escaped by the quote pass after it).
_sql_escape() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g"; }

# _kube_mariadb <mariadb args...> — runs the mariadb client in the cluster's
# MariaDB pod. 'kubectl exec' has no --env of its own, so the password is
# piped in on stdin and exported inside the pod instead: passing it as an
# argument would put it right back in this host's 'ps' output (see the note
# above _db_exec). None of the callers need stdin for anything else.
_kube_mariadb() {
    local want_stdin="$1" pw="$2" client="$3"; shift 3
    local pod; pod="$(_kube_pick_pod "$DB_POD_SELECTOR" "$DB_SSH_HOST")" || return 1
    # The password is the first line of stdin, consumed inside the pod by one
    # POSIX `read` — specified not to read past the newline, so anything
    # after it is still intact for the client. The previous version piped the
    # password as the WHOLE of stdin, which silently left _db_import with no
    # kubectl path at all. Not in argv, which is the point.
    local inner='IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec "$@"'
    local -a cmd=( exec -i -n "$K8S_NAMESPACE" "$pod" --
                   sh -c "$inner" _ "$client" -u"$DB_USER" "$@" )
    if [[ -n "$want_stdin" ]]; then
        { printf '%s\n' "$pw"; cat; } | _kube "$DB_SSH_HOST" "${cmd[@]}"
    else
        printf '%s\n' "$pw" | _kube "$DB_SSH_HOST" "${cmd[@]}"
    fi
}

# _db_report <what> <sql> — run a human-facing query and SAY SO when it
# matches nothing.
#
# The mariadb client prints absolutely nothing for an empty result set — no
# header, no empty table — so a search with no matches produced only this
# script's own banner and exited 0, which is indistinguishable from the
# command having failed. That is the bug class this script keeps tripping
# over: success that looks like nothing happened.
#
# The result is captured rather than streamed so it can be tested for
# emptiness. Rows still go to stdout and diagnostics to stderr, as everywhere.
_db_report() {
    local what="$1" sql="$2" out
    out="$(_db_query "$sql")" || return 1
    if [[ -z "${out//[[:space:]]/}" ]]; then
        info "No ${what}."
        return 0
    fi
    printf '%s\n' "$out"
}

# _db_query <target: local|docker|k8s> <sql> — local/docker share the same
# local MariaDB container (_db_exec); k8s has its own separate MariaDB pod
# in the cluster (see the architecture note on templates/k8s/mariadb.yaml),
# so that one needs its own kubectl exec instead of _db_exec's docker exec.
_db_query() {
    _db_client -t -e "$1"
}

# _db_query_raw <target> <sql> — like _db_query, but -N -B (no column
# headers, tab-separated, no ASCII table borders) for callers that need to
# actually parse a single value out of the result, not display it.
_db_query_raw() {
    _db_client -N -B -e "$1"
}

# _send_console_cmd <local|docker|kubectl> <single console command line>
_send_console_cmd() {
    local tgt="$1" line="$2"
    case "$tgt" in
        local)
            local fifo="${INSTALL_DIR}/bin/mangosd.stdin"
            if [[ ! -p "$fifo" ]]; then
                warn "mangosd's console FIFO isn't there (${fifo}). Was it started via this script's 'start'?"
                return 1
            fi
            printf '%s\n' "$line" > "$fifo"
            ;;
        docker|podman)
            if [[ -z "$SERVER_SSH_HOST" ]]; then
                # The path is an ARGUMENT to sh, not spliced into its script:
                # interpolated, a FIFO path containing a space or a shell
                # metacharacter was re-parsed by the shell inside the
                # container. 'sh' is the conventional $0 placeholder.
                printf '%s\n' "$line" | "$tgt" exec -i "$SERVER_CONTAINER_NAME" sh -c 'cat > "$1"' sh "$SERVER_FIFO" \
                    || { warn "Failed to reach the container's console FIFO (${SERVER_FIFO})."; return 1; }
            else
                printf '%s\n' "$line" | _remote_run "$SERVER_SSH_HOST" \
                    "$tgt" exec -i "$SERVER_CONTAINER_NAME" sh -c 'cat > "$1"' sh "$SERVER_FIFO" \
                    || { warn "Failed to reach the container's console FIFO (${SERVER_FIFO}) on ${SERVER_SSH_HOST}."; return 1; }
            fi
            ;;
        kubectl)
            local pod
            pod="$(_kube_pick_pod "$SERVER_POD_SELECTOR" "$SERVER_SSH_HOST")" || return 1
            printf '%s\n' "$line" | _kube "$SERVER_SSH_HOST" \
                exec -i -n "$K8S_NAMESPACE" ${SERVER_K8S_CONTAINER:+-c "$SERVER_K8S_CONTAINER"} "$pod" -- sh -c 'cat > "$1"' sh "$SERVER_FIFO" \
                || { warn "Failed to reach the pod's console FIFO (${SERVER_FIFO})."; return 1; }
            ;;
    esac
}

# _validate_console_arg <label> <value> — gate for anything that ends up as a
# word in a mangosd console line ('account create NAME PASS', 'account set
# gmlevel NAME N'). The console splits on whitespace and takes one command
# per line, so a space would shift the arguments and an embedded newline
# would inject a second command. Printable only, no whitespace/control
# characters, 1-16 chars (MAX_ACCOUNT_STR/MAX_PASSWORD_STR in the source).
_validate_console_arg() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[[:graph:]]{1,16}$ ]] \
        || error_exit "${label} must be 1-16 printable characters with no whitespace or control characters."
}

cmd_create_account() {
    header "nordrassil — Create account"
    _settings

    local user_input="" pass_input="" gm_num=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)  user_input="$2"; shift 2 ;;
        --pass)  pass_input="$2"; shift 2 ;;
        --level) gm_num="$2"; shift 2 ;;
        --where) WHERE="$2"; shift 2 ;;
        *) error_exit "create-account: unknown flag: $1" ;;
    esac; done
    [[ -n "$user_input" ]] || error_exit "create-account: --name is required."
    [[ -n "$pass_input" ]] || error_exit "create-account: --pass is required."
    _validate_console_arg "create-account: --name" "$user_input"
    _validate_console_arg "create-account: --pass" "$pass_input"
    [[ "$gm_num" =~ ^[0-6]$ ]] || error_exit "create-account: --level must be 0-6 (see the GM-level scale)."

    local target
    target=$(_server_transport) || return 1

    # 'account create' and 'account set gmlevel' can't be sent as one burst:
    # live-tested, sending both in a single write reliably fails the gmlevel
    # half with "Account not exist" — the newly created account isn't visible
    # to the very next console command yet (an in-memory cache/registration
    # lag, not a DB write issue, the account itself is created correctly
    # either way). A few seconds between the two is enough.
    _send_console_cmd "$target" "account create ${user_input} ${pass_input}" || return 1

    if [[ "$gm_num" != "0" ]]; then
        sleep 3
        _send_console_cmd "$target" "account set gmlevel ${user_input} ${gm_num}" || return 1
    fi

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        kubectl) info "Check: kubectl -n ${K8S_NAMESPACE} logs -l ${SERVER_POD_SELECTOR}" ;;
    esac

    success "Account '${user_input}' created (GM level: ${gm_num})."
}

# _print_accounts_table <target> — shared by list-accounts and
# delete-account (as a courtesy display before prompting for a username),
# so delete-account doesn't need to run _server_transport a second time
# (and risk a second "which target?" prompt) just to show the same list.
_print_accounts_table() {
    # GM level lives in account_access (per-realm), not account.gmlevel,
    # which is vestigial (see create-account's notes). LEFT JOIN so an
    # account with no account_access row still shows up, as GM level 0.
    _db_report "accounts on this realm" \
        "SELECT a.id, a.username, COALESCE(aa.gmlevel, 0) AS gmlevel, a.online, a.locked, a.last_login
         FROM realmd.account a LEFT JOIN realmd.account_access aa ON aa.id = a.id AND aa.RealmID = ${REALM_ID}
         ORDER BY a.username;"
}

cmd_list_accounts() {
    header "nordrassil — List accounts"
    _settings
    while [[ $# -gt 0 ]]; do case "$1" in
        --where) WHERE="$2"; shift 2 ;;
        *) error_exit "list-accounts: unknown flag: $1" ;;
    esac; done

    local target
    target=$(_server_transport) || return 1

    _print_accounts_table || return 1
}

cmd_delete_account() {
    header "nordrassil — Delete account"
    _settings

    local user_input=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)  user_input="$2"; shift 2 ;;
        --where) WHERE="$2"; shift 2 ;;
        *) error_exit "delete-account: unknown flag: $1" ;;
    esac; done
    [[ -n "$user_input" ]] || error_exit "delete-account: --name is required."
    _validate_console_arg "delete-account: --name" "$user_input"

    # Destructive (also removes the account's characters). The front-end confirms
    # before calling; the engine executes the named deletion directly.
    local target
    target=$(_server_transport) || return 1

    # Needed for the account_access cleanup below: that row can only be
    # looked up by account id, and 'account delete' removes the account row
    # itself, so the id has to be captured before the console command runs.
    # stderr muted (the mariadb client's password-on-command-line notice), so
    # a failed query must be reported here — under set -e a bare failing
    # assignment would otherwise end the script with no message at all.
    local acc_id user_sql; user_sql="$(_sql_escape "${user_input^^}")"
    acc_id=$(_db_query_raw "SELECT id FROM realmd.account WHERE username='${user_sql}';" 2>/dev/null) \
        || { warn "Account id lookup failed (is MariaDB reachable with DB_USER/DB_PASS?) — the account_access cleanup below will be skipped."; acc_id=""; }

    _send_console_cmd "$target" "account delete ${user_input}" || return 1

    # AccountMgr::DeleteAccount (confirmed directly in the source) cleans up
    # characters/character_tutorial/account/realmcharacters, but never
    # account_access — a real, if harmless, upstream gap (an orphaned row
    # can never rejoin a real account again, ids aren't reused). Sweep it
    # here so repeated create/delete cycles don't quietly accumulate junk.
    if [[ "$acc_id" =~ ^[0-9]+$ ]]; then
        sleep 2
        _db_query "DELETE FROM realmd.account_access WHERE id=${acc_id};" &>/dev/null || true
    fi

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        kubectl) info "Check: kubectl -n ${K8S_NAMESPACE} logs -l ${SERVER_POD_SELECTOR}" ;;
    esac

    success "Delete command sent for '${user_input}'."
}

cmd_set_account_level() {
    header "nordrassil — Set account GM level"
    _settings

    local user_input="" gm_num=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)  user_input="$2"; shift 2 ;;
        --level) gm_num="$2"; shift 2 ;;
        --where) WHERE="$2"; shift 2 ;;
        *) error_exit "set-account-level: unknown flag: $1" ;;
    esac; done
    [[ -n "$user_input" ]] || error_exit "set-account-level: --name is required."
    _validate_console_arg "set-account-level: --name" "$user_input"
    [[ "$gm_num" =~ ^[0-6]$ ]] || error_exit "set-account-level: --level must be 0-6."

    local target
    target=$(_server_transport) || return 1

    _send_console_cmd "$target" "account set gmlevel ${user_input} ${gm_num}" || return 1

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        kubectl) info "Check: kubectl -n ${K8S_NAMESPACE} logs -l ${SERVER_POD_SELECTOR}" ;;
    esac

    success "GM level command sent for '${user_input}' (level: ${gm_num})."
}

# rename-character — a direct, immediate rename, not the server's own
# 'character rename <name>' console command. That command (confirmed in
# CharacterCommands.cpp) only flags the character; the actual new name gets
# picked through the client's own name-picker UI at next login, which
# re-enforces the same server-side naming rules this exists to deliberately
# sidestep for a specific character on a case-by-case basis, without
# touching those rules for everyone else. This is a pure database
# operation, not a console command, so it works even if mangosd isn't
# running at all (_db_require, not _server_transport) — but the
# character must be offline: mangosd only reads a character's row from the
# database at login, an online character's data lives in memory and a
# logout would overwrite this change with whatever's already loaded there.
cmd_rename_character() {
    header "nordrassil — Rename character"
    _settings

    local old_name="" new_name=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --from) old_name="$2"; shift 2 ;;
        --to)   new_name="$2"; shift 2 ;;
        *) error_exit "rename-character: unknown flag: $1" ;;
    esac; done
    [[ -n "$old_name" ]] || error_exit "rename-character: --from is required (the current name; use 'search' to find it)."
    [[ -n "$new_name" ]] || error_exit "rename-character: --to is required (the new name)."

    local target
    _db_require || return 1

    local old_name_escaped; old_name_escaped="$(_sql_escape "$old_name")"
    local row guid online
    # See delete-account: stderr is muted, so a failed query is reported here
    # rather than silently ending the script under set -e.
    row=$(_db_query_raw "SELECT guid, online FROM characters.characters WHERE name='${old_name_escaped}';" 2>/dev/null) \
        || { warn "Character lookup failed (is MariaDB reachable with DB_USER/DB_PASS?)."; return 1; }
    if [[ -z "$row" ]]; then
        warn "No character named '${old_name}' found."
        return 1
    fi
    guid="${row%%$'\t'*}"
    online="${row##*$'\t'}"

    if [[ "$online" != "0" ]]; then
        warn "'${old_name}' is currently online — log them out first. A live session holds its own copy of the name in memory, and logging out afterward would overwrite this change with the old one."
        return 1
    fi

    if [[ ${#new_name} -gt 12 ]]; then
        warn "'${new_name}' is ${#new_name} characters — the characters.name column allows at most 12."
        return 1
    fi

    local new_name_escaped; new_name_escaped="$(_sql_escape "$new_name")"
    local existing
    existing=$(_db_query_raw "SELECT guid FROM characters.characters WHERE name='${new_name_escaped}';" 2>/dev/null) \
        || { warn "Name availability check failed (is MariaDB reachable with DB_USER/DB_PASS?)."; return 1; }
    if [[ -n "$existing" && "$existing" != "$guid" ]]; then
        warn "'${new_name}' is already taken by another character."
        return 1
    fi

    # & ~0x4000 clears CHARACTER_FLAG_RENAME (Player.h) alongside the name
    # itself — found live: a character renamed this way still hit the
    # client's own "you must rename" prompt on login, because that flag
    # was already set (from an earlier attempt, or any other GM action)
    # and this UPDATE only ever touched the name column, never the flag
    # that actually drives the client's rename prompt.
    _db_query "UPDATE characters.characters SET name='${new_name_escaped}', character_flags = character_flags & ~0x4000 WHERE guid=${guid};" &>/dev/null || return 1
    success "'${old_name}' renamed to '${new_name}'."
}

# -----------------------------------------------------------------------------
# search — name lookup for items, NPCs, GM teleport locations, and player
# characters. All four are plain reference-data reads (no SRP6/console
# involved, unlike the account commands), so this goes straight to the
# database via _db_query, and works even if mangosd itself isn't running —
# only the database needs to be up (_db_require, not _server_transport).
# -----------------------------------------------------------------------------

cmd_search() {
    header "nordrassil — Search"
    _settings

    local kind="" term=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --term) term="$2"; shift 2 ;;
        *) error_exit "search: unknown flag: $1" ;;
    esac; done
    [[ "$kind" =~ ^(items|npcs|teleports|characters)$ ]] || error_exit "search: --kind must be items|npcs|teleports|characters."
    [[ -n "$term" ]] || error_exit "search: --term is required."

    local target
    _db_require || return 1
    local term_escaped; term_escaped="$(_sql_escape "$term")"

    case "$kind" in
        items)
            # item_template/creature_template key on (entry, patch) — the
            # same entry can have a different row per patch it changed in.
            # Without filtering, a search can show stale/duplicate rows for
            # an item that changed since; the correlated subquery picks the
            # latest row at or before the configured WOW_PATCH, matching
            # what's actually loaded on this server.
            _db_report "items matching '${term}'" \
                "SELECT it.entry, it.name, it.quality FROM mangos.item_template it
                 WHERE it.name LIKE '%${term_escaped}%' AND it.patch = (
                     SELECT MAX(patch) FROM mangos.item_template it2 WHERE it2.entry = it.entry AND it2.patch <= ${WOW_PATCH}
                 ) ORDER BY it.name LIMIT 50;" || return 1
            ;;
        npcs)
            _db_report "NPCs matching '${term}'" \
                "SELECT ct.entry, ct.name, ct.subname FROM mangos.creature_template ct
                 WHERE ct.name LIKE '%${term_escaped}%' AND ct.patch = (
                     SELECT MAX(patch) FROM mangos.creature_template ct2 WHERE ct2.entry = ct.entry AND ct2.patch <= ${WOW_PATCH}
                 ) ORDER BY ct.name LIMIT 50;" || return 1
            ;;
        teleports)
            # game_tele — the table the '.tele <name>' GM command itself
            # searches, no patch column here.
            _db_report "teleport locations matching '${term}'" \
                "SELECT id, name, map, ROUND(position_x,1) AS x, ROUND(position_y,1) AS y
                 FROM mangos.game_tele WHERE name LIKE '%${term_escaped}%' ORDER BY name LIMIT 50;" || return 1
            ;;
        characters)
            _db_report "characters matching '${term}'" \
                "SELECT guid, name, race, class, level FROM characters.characters
                 WHERE name LIKE '%${term_escaped}%' ORDER BY name LIMIT 50;" || return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# edit — escape hatch for anything 'configure' doesn't take from the config
# store. Opens the already-configured conf files (not the repack's pristine
# copies) in $EDITOR (default vim). Picked up automatically by run-docker/
# run-k8s afterward via _effective_conf_source; 'start' just needs a restart.
# Note that a later 'configure' re-renders these from the pristine copies and
# discards the edits.
# -----------------------------------------------------------------------------

cmd_edit() {
    header "nordrassil — Edit conf files"
    _settings
    _refuse_if_managed edit
    _refuse_if_remote edit

    local file=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) file="$2"; shift 2 ;;
        *) error_exit "edit: unknown flag: $1" ;;
    esac; done
    [[ "$file" =~ ^(mangosd|realmd)$ ]] || error_exit "edit: --file must be mangosd or realmd."

    if [[ ! -f "${ETC_DIR}/mangosd.conf" ]]; then
        warn "Not configured yet — run 'configure' first."
        return 1
    fi
    local editor="${EDITOR:-vim}"
    if ! command -v "$editor" &>/dev/null; then
        warn "'$editor' not found — set \$EDITOR, or edit these files with any editor: ${ETC_DIR}"
        return 1
    fi

    "$editor" "${ETC_DIR}/${file}.conf"

    success "Saved. Restart 'start' for the local process, or re-run 'run-docker'/'run-k8s' to apply it to a container/pod (conf files are mounted at runtime, not baked into the image — no need to 'build-image' again)."
}

# -----------------------------------------------------------------------------
# build-image — multi-stage Dockerfile, builder compiles inside Ubuntu
# regardless of host OS, runtime stage is slim.
# -----------------------------------------------------------------------------

cmd_build_image() {
    header "nordrassil — Build Docker image"
    _settings
    _refuse_if_managed build-image
    _refuse_if_remote build-image
    _check_docker

    [[ -d "$SOURCE_DIR" ]] || error_exit "SOURCE_DIR not set or missing — run 'configure' first."
    _unpack_source

    info "Preparing build context..."
    rm -rf "$IMAGE_BUILD_CONTEXT"
    mkdir -p "$IMAGE_BUILD_CONTEXT"
    cp -r "$SRC_UNPACK_DIR" "${IMAGE_BUILD_CONTEXT}/src"
    cp "${TEMPLATES_DIR}/Dockerfile"    "${IMAGE_BUILD_CONTEXT}/Dockerfile"
    cp "${TEMPLATES_DIR}/entrypoint.sh" "${IMAGE_BUILD_CONTEXT}/entrypoint.sh"

    # Warden anti-cheat modules — small and static like the binaries, baked
    # into the image (see the Dockerfile's own note). Without them, Warden
    # still runs (it's enabled by default in the repack's stock conf) but
    # has nothing to actually scan with, which surfaces as players getting
    # kicked for "Client response timeout" during normal play, not just a
    # log warning at startup. Not every repack/fork ships this directory,
    # so an empty one here is a soft warning, not a hard failure.
    if [[ -d "${SOURCE_DIR}/warden_modules" ]]; then
        cp -r "${SOURCE_DIR}/warden_modules" "${IMAGE_BUILD_CONTEXT}/warden_modules"
    else
        warn "No warden_modules/ found under SOURCE_DIR — Warden anti-cheat will run with no modules loaded, which can kick players unexpectedly. Building an empty directory instead."
        mkdir -p "${IMAGE_BUILD_CONTEXT}/warden_modules"
    fi

    info "Building image '${IMAGE_TAG}' (client build ${CLIENT_BUILD})..."
    docker build \
        --build-arg "SUPPORTED_CLIENT_BUILD=${CLIENT_BUILD}" \
        -t "$IMAGE_TAG" \
        "$IMAGE_BUILD_CONTEXT" \
        || error_exit "docker build failed. See compiler output above."

    success "Image built: ${IMAGE_TAG}"
}

# -----------------------------------------------------------------------------
# run-docker — LAN-exposed via host networking; server reaches the DB via
# 127.0.0.1 on the published MariaDB port (host networking bypasses Docker's
# embedded DNS, so container-name resolution isn't available here).
# -----------------------------------------------------------------------------

cmd_run_docker() {
    header "nordrassil — Run (Docker, LAN)"
    _settings
    _refuse_if_managed run-docker
    _refuse_if_remote run-docker
    _check_docker

    local force=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --force) force=1; shift ;;
        *) error_exit "run-docker: unknown flag: $1" ;;
    esac; done

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first."
    _ensure_local_mariadb
    _db_bootstrap

    # --type container avoids docker inspect's fallback-to-image lookup —
    # without it, "vanilla-wow-server" (no tag) ambiguously matches the
    # "vanilla-wow-server:latest" image too, since they share a base name.
    if docker inspect --type container "$SERVER_CONTAINER_NAME" &>/dev/null; then
        [[ "$force" -eq 1 ]] || error_exit "Container '${SERVER_CONTAINER_NAME}' already exists. Re-run with --force to remove and recreate it."
        docker rm -f "$SERVER_CONTAINER_NAME" &>/dev/null || true
    fi

    # /app/bin/warden_modules — baked into the image at build time (see
    # cmd_build_image/Dockerfile), mangosd's cwd is /app/bin at runtime.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.docker.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.docker.conf"  "/app/logs"

    # :Z (private SELinux relabel) is required on Fedora/RHEL hosts with
    # SELinux enforcing — without it the container's unprivileged user gets
    # "Permission denied" reading these bind mounts, since host files default
    # to a context (e.g. config_home_t) containers aren't allowed to read.
    # First run relabels the whole data/ tree (3.2GB, one-time cost).
    # -i keeps stdin open (even detached) — mangosd/realmd run an interactive
    # console reader on stdin, and without it Docker delivers an immediate
    # EOF, which the console reads as an implicit quit: the server would
    # otherwise fully start (DB connected, world initialized, ports bound)
    # and then shut itself down cleanly seconds later.
    info "Starting server container (host networking — realm ${REALM_PORT}, world ${WORLD_PORT})..."
    docker run -d -i \
        --name "$SERVER_CONTAINER_NAME" \
        --network host \
        -v "${SOURCE_DIR}/data:/app/data:ro,Z" \
        -v "${ETC_DIR}/mangosd.docker.conf:/app/etc/mangosd.conf:ro,Z" \
        -v "${ETC_DIR}/realmd.docker.conf:/app/etc/realmd.conf:ro,Z" \
        --restart unless-stopped \
        "$IMAGE_TAG" \
        || error_exit "Failed to start container '${SERVER_CONTAINER_NAME}'."

    success "Server running: realm port ${REALM_PORT}, world port ${WORLD_PORT} (host network — reachable on your LAN IP)."
    info "Logs: docker logs -f ${SERVER_CONTAINER_NAME}"
}

# Stops the server container only — never the DB container, and never
# `docker rm`/the Docker daemon itself (same "stop the server, leave
# everything else alone" contract as cmd_stop for the local path). The
# container has --restart unless-stopped (set in cmd_run_docker), which
# specifically means "restart automatically after a daemon/host restart,
# unless a human stopped it" — so a plain 'docker stop' here is exactly
# enough to keep it down; no need to touch the restart policy.
cmd_stop_docker() {
    header "nordrassil — Stop (Docker)"
    _settings
    _refuse_if_managed stop-docker
    _refuse_if_remote stop-docker

    docker inspect --type container "$SERVER_CONTAINER_NAME" &>/dev/null \
        || { info "Container '${SERVER_CONTAINER_NAME}' not found — nothing to stop."; return; }

    [[ "$(docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        || { info "Container '${SERVER_CONTAINER_NAME}' is not running."; return; }

    docker stop "$SERVER_CONTAINER_NAME" &>/dev/null \
        && success "Container '${SERVER_CONTAINER_NAME}' stopped (Docker itself keeps running)." \
        || error_exit "Failed to stop container '${SERVER_CONTAINER_NAME}'."
    info "Container kept, not removed — resume it with: docker start ${SERVER_CONTAINER_NAME} (re-running 'run-docker' instead will remove and recreate it fresh)."
}

# -----------------------------------------------------------------------------
# run-k8s — hostNetwork so the fixed client-expected ports work without a
# LoadBalancer controller. Target comes from the global --context/--kind flags;
# storage backend (hostPath vs StorageClass) and paths come from config.
# -----------------------------------------------------------------------------

# Escapes a value for embedding inside a double-quoted YAML scalar
# ("__TOKEN__" in the templates): backslash first, then the quote itself.
_yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# render_template <template-file> <token1=value1> [...]
# Single-line token substitution only — do not pass multi-line values (sed
# can't do that safely). Use inject_block below for multi-line content.
render_template() {
    local tpl="$1"; shift
    local content; content="$(cat "$tpl")"
    local pair token value escaped
    for pair in "$@"; do
        token="${pair%%=*}"
        value="${pair#*=}"
        escaped="$(_sed_escape "$value")"
        content="$(printf '%s' "$content" | sed "s|__${token}__|${escaped}|g")"
    done
    printf '%s\n' "$content"
}

# inject_block <template-file> <token> <replacement-file>
# Splices the full multi-line content of <replacement-file> in place of a
# line that is exactly "__<token>__" — for content sed's single-line 's'
# command can't hold (e.g. the hostPath-vs-PVC volume source block, whose
# line count varies). Same pattern dozzle.sh uses for the same reason.
inject_block() {
    local tpl="$1" token="$2" block_file="$3"
    # Matches on the trimmed line so an indented "          __TOKEN__"
    # placeholder (kept indented in the template for YAML readability) still
    # matches — unlike a bare $0 == token check, which only fires on an
    # unindented, column-0 placeholder.
    awk -v token="__${token}__" '
        { trimmed = $0; sub(/^[ \t]+/, "", trimmed) }
        trimmed == token { while ((getline line < block_file) > 0) print line; next }
        { print }
    ' block_file="$block_file" "$tpl"
}

cmd_run_k8s() {
    header "nordrassil — Run (Kubernetes, LAN via hostNetwork)"
    _settings
    _refuse_if_managed run-k8s
    _refuse_if_remote run-k8s
    _announce_kube_target

    # Storage backend, namespace and realm address come from config (set them
    # with 'set K8S_STORAGE_TYPE hostpath|storageclass', 'set K8S_DATA_HOSTPATH',
    # 'set K8S_DB_HOSTPATH', 'set K8S_STORAGECLASS'); --namespace/--address are
    # one-shot overrides that also persist. The kube target is the global
    # --context/--kind (see kubectl_context_flag).
    local namespace="" address=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --namespace) namespace="$2"; shift 2 ;;
        --address)   address="$2"; shift 2 ;;
        *) error_exit "run-k8s: unknown flag: $1" ;;
    esac; done

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first (kind: also 'kind load docker-image')."

    # Target: --kind <name> ⇒ a kind cluster (context kind-<name>, and the
    # image is side-loaded with 'kind load'); --context <name> ⇒ a plain k8s
    # context; neither ⇒ the current kube context.
    local target_type target_context
    if [[ -n "$KIND_CLUSTER" ]]; then
        target_type="kind"; target_context="$KIND_CLUSTER"
    else
        target_type="k8s";  target_context="$KUBE_CONTEXT"
    fi

    [[ -n "$namespace" ]] && K8S_NAMESPACE="$namespace"
    cfg_set K8S_NAMESPACE "$K8S_NAMESPACE"

    [[ -n "$address" ]] && REALM_ADDRESS="$address"
    cfg_set REALM_ADDRESS "$REALM_ADDRESS"

    [[ "$K8S_STORAGE_TYPE" == "storageclass" ]] && \
        warn "StorageClass-backed game data still needs the 3.2GB data/ directory copied into the PVC once — this script does not automate that copy (no assumptions about how the target cluster reaches this host's filesystem). hostPath is the zero-copy option for a single-node cluster."

    if [[ "$target_type" == "kind" ]]; then
        info "kind target — loading image into the cluster (kind can't pull local-only images)..."
        info "kind load docker-image..."
            kind load docker-image "$IMAGE_TAG" --name "$target_context" \
            || error_exit "kind load docker-image failed."
    fi

    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    local k8s_tpl="${TEMPLATES_DIR}/k8s"
    local manifest; manifest="$(mktemp /tmp/vanilla-wow-k8s-XXXXXX.yaml)"
    local storage_type; storage_type="$K8S_STORAGE_TYPE"
    local data_source_file db_source_file job_manifest
    data_source_file="$(mktemp /tmp/vanilla-wow-data-src-XXXXXX)"
    db_source_file="$(mktemp /tmp/vanilla-wow-db-src-XXXXXX)"
    job_manifest="$(mktemp /tmp/vanilla-wow-db-init-XXXXXX.yaml)"
    # One trap for all four temp files — a second trap on the same signal
    # would silently replace the first rather than adding to it. EXIT, not
    # RETURN: error_exit's 'exit 1' never runs a RETURN trap, which used to
    # leave the rendered manifests (the DB password among them) in /tmp.
    # All four are mktemp-created, i.e. 0600.
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}' '${data_source_file}' '${db_source_file}' '${job_manifest}'" EXIT

    # inject_block splices these lines in VERBATIM (no reindentation) in place
    # of the "__DATA_SOURCE__"/"__DB_SOURCE__" placeholder line in the
    # templates below — the indentation here (10 spaces for the key, 12 for
    # its children) must match where that placeholder sits: nested under
    # spec.template.spec.volumes[].<key>, both templates use the same depth.
    if [[ "$storage_type" == "hostpath" ]]; then
        printf '          hostPath:\n            path: %s\n            type: Directory\n' \
            "$K8S_DATA_HOSTPATH" > "$data_source_file"
        printf '          hostPath:\n            path: %s\n            type: DirectoryOrCreate\n' \
            "$K8S_DB_HOSTPATH" > "$db_source_file"
    else
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-data\n' > "$data_source_file"
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-db\n' > "$db_source_file"
        warn "StorageClass path selected — remember to copy game data into the vanilla-wow-data PVC before the server pod will start cleanly."
    fi

    render_template "${k8s_tpl}/namespace.yaml" "NAMESPACE=${K8S_NAMESPACE}" > "$manifest"

    # DB root password as a Secret (referenced via secretKeyRef by mariadb.yaml
    # and db-init-job.yaml below) — right after the namespace so it exists
    # before anything that mounts it. base64 output is [A-Za-z0-9+/=] only,
    # so it needs no YAML quoting and is safe for render_template's sed.
    # Resolved, not $DB_PASS: the Secret used to carry base64("ask").
    local db_pass_new; db_pass_new="$(_db_password_new)" || return 1
    local db_pass_b64; db_pass_b64="$(printf '%s' "$db_pass_new" | base64 | tr -d '\n')"
    echo "---" >> "$manifest"
    render_template "${k8s_tpl}/db-secret.yaml" "NAMESPACE=${K8S_NAMESPACE}" "DB_PASS_B64=${db_pass_b64}" >> "$manifest"

    if [[ "$storage_type" != "hostpath" ]]; then
        local sc; sc="$K8S_STORAGECLASS"
        local sc_line=""
        [[ -n "$sc" ]] && sc_line="  storageClassName: ${sc}"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-data" "SIZE=5Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-db" "SIZE=10Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
    fi

    echo "---" >> "$manifest"
    inject_block "${k8s_tpl}/mariadb.yaml" "DB_SOURCE" "$db_source_file" \
        | render_template /dev/stdin "NAMESPACE=${K8S_NAMESPACE}" >> "$manifest"

    # server.yaml is deliberately NOT part of this manifest — it's applied
    # last, after the db-init Job has completed (see below). entrypoint.sh
    # has no DB-wait of its own, so a server pod started alongside the Job
    # crash-loops for the whole world-dump import on a first deploy.
    info "Applying manifests (namespace, storage, mariadb)..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "$manifest" || error_exit "kubectl apply failed."

    # ConfigMap for the server's conf files, DB host pointed at the in-cluster
    # mariadb Service (hostNetworked pods can still reach ClusterIP services;
    # DNS resolution for that needs dnsPolicy: ClusterFirstWithHostNet, set in
    # server.yaml). --from-file avoids hand-escaping a 3000+ line conf file
    # as an inline YAML string.
    local saved_db_host="$DB_HOST"
    DB_HOST="mariadb.${K8S_NAMESPACE}.svc.cluster.local"
    # /app/bin/warden_modules — same image as run-docker, same baked-in path.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.k8s.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.k8s.conf"  "/app/logs"
    DB_HOST="$saved_db_host"

    info "Creating server config ConfigMap..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" create configmap vanilla-wow-conf \
        --from-file=mangosd.conf="${ETC_DIR}/mangosd.k8s.conf" \
        --from-file=realmd.conf="${ETC_DIR}/realmd.k8s.conf" \
        --dry-run=client -o yaml | kubectl $ctx_flags apply -f - \
        || error_exit "Failed to create the server ConfigMap."

    info "Running DB bootstrap Job (schemas + world dump + migrations)..."
    # A Job's pod template is immutable once created, so re-applying it with
    # anything changed (realm address, password, sql path) fails — delete
    # any previous run first (also drops its completed/failed pods).
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" delete job vanilla-wow-db-init --ignore-not-found \
        || error_exit "Failed to remove the previous db-init Job."
    render_template "${k8s_tpl}/db-init-job.yaml" \
        "NAMESPACE=${K8S_NAMESPACE}" \
        "REALM_ID=${REALM_ID}" "REALM_NAME=$(_yaml_escape "$REALM_NAME")" "REALM_ADDRESS=$(_yaml_escape "$REALM_ADDRESS")" \
        "WORLD_PORT=${WORLD_PORT}" "CLIENT_BUILD=${CLIENT_BUILD}" \
        "CUSTOM_SQL=$(_yaml_escape "${CUSTOM_SQL:-}")" \
        "SQL_HOSTPATH=${SOURCE_DIR}/sql" > "$job_manifest"
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "$job_manifest" || error_exit "db-init Job apply failed."
    # shellcheck disable=SC2086
    info "Waiting for db-init Job to complete (world dump import can take a while)..."
        kubectl $ctx_flags -n "$K8S_NAMESPACE" wait --for=condition=complete job/vanilla-wow-db-init --timeout=900s \
        || warn "db-init Job did not complete in time — deploying the server anyway (it restarts until the DB is ready). Check: kubectl -n ${K8S_NAMESPACE} logs job/vanilla-wow-db-init"

    # Only now that the DB is bootstrapped: the server Deployment.
    info "Applying server deployment..."
    # shellcheck disable=SC2086
    inject_block "${k8s_tpl}/server.yaml" "DATA_SOURCE" "$data_source_file" \
        | render_template /dev/stdin \
            "NAMESPACE=${K8S_NAMESPACE}" "IMAGE_TAG=${IMAGE_TAG}" \
            "REALM_PORT=${REALM_PORT}" "WORLD_PORT=${WORLD_PORT}" \
        | kubectl $ctx_flags apply -f - || error_exit "server deployment apply failed."

    # shellcheck disable=SC2086
    info "Waiting for server rollout..."
        kubectl $ctx_flags -n "$K8S_NAMESPACE" rollout status deployment/vanilla-wow-server --timeout=120s \
        || warn "Server rollout did not complete. Check: kubectl -n ${K8S_NAMESPACE} get pods"

    success "Deployed. hostNetwork pod — reachable on the node's LAN IP: realm ${REALM_PORT}, world ${WORLD_PORT}."
}

# Scales the server Deployment to 0 — never touches mariadb, the PVCs, or
# the ConfigMap (same "stop the server, leave everything else alone"
# contract as cmd_stop/cmd_stop_docker). Uses the global --context/--kind
# target (or the ambient kube context when neither is given) rather than
# forcing a re-selection just to stop something.
cmd_stop_k8s() {
    header "nordrassil — Stop (Kubernetes)"
    _settings
    _refuse_if_managed stop-k8s
    _refuse_if_remote stop-k8s
    _announce_kube_target

    command -v kubectl &>/dev/null || error_exit "kubectl not found."

    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    # shellcheck disable=SC2086
    kubectl $ctx_flags get deployment vanilla-wow-server -n "$K8S_NAMESPACE" &>/dev/null \
        || { info "No 'vanilla-wow-server' deployment found in namespace '${K8S_NAMESPACE}' — nothing to stop."; return; }

    # shellcheck disable=SC2086
    kubectl $ctx_flags scale deployment/vanilla-wow-server -n "$K8S_NAMESPACE" --replicas=0 \
        && success "Server deployment scaled to 0 replicas in namespace '${K8S_NAMESPACE}' (mariadb, PVCs, and the ConfigMap are untouched)." \
        || error_exit "Failed to scale down the server deployment."
    info "Resume it with: kubectl scale deployment/vanilla-wow-server -n ${K8S_NAMESPACE} --replicas=1 (or re-run 'run-k8s')."
}

# -----------------------------------------------------------------------------
# Config subcommands — the front-end (scomp-link's wow-nordrassil TUI) collects
# values with gum and pushes them here; the engine itself only ever reads/writes
# the flat key=value config file. 'set'/'get' expose that store directly so the
# TUI (or a script) can persist any setting before running build/run commands.
# -----------------------------------------------------------------------------

cmd_set() {
    _settings
    [[ $# -eq 2 ]] || error_exit "set: usage: set KEY VALUE"
    cfg_set "$1" "$2"
    success "Set ${1}."
}

cmd_get() {
    _settings
    [[ $# -eq 1 ]] || error_exit "get: usage: get KEY"
    # Return the EFFECTIVE value: for a known setting _settings has already
    # resolved it (config value or its default), so echo that global; for a
    # key that is only in the config store, echo what is stored. This lets the
    # front-end pre-fill its prompts with real defaults, not blanks.
    #
    # Scope matters here: the test used to be 'declare -p "$key"', i.e. "is
    # there a shell variable by that name", so 'get PATH', 'get HOME' or
    # 'get BASH_VERSINFO' happily printed this shell's own state — and a key
    # colliding with an internal (CONFIG_FILE, DB_CONTAINER_NAME's neighbours,
    # PF_DIR...) would answer from the script instead of the config. The
    # config store is the only thing this command speaks for.
    local key="$1" k
    # The key is spliced into a regex below — same rule as cfg_set's.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error_exit "get: invalid key '${key}' (letters, digits, underscore)."
    for k in "${SETTING_KEYS[@]}"; do
        [[ "$k" == "$key" ]] || continue
        printf '%s\n' "${!key}"
        return 0
    done
    grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null \
        || error_exit "get: unknown key '${key}' — not a nordrassil setting and not in ${CONFIG_FILE} ('config' dumps what is stored)."
    cfg_get "$key"
}

# Dumps the whole persisted config (key="value" per line) — the front-end reads
# this to pre-fill its prompts with the current values.
cmd_config() {
    _settings
    # Both layers, separately rather than merged: when a value is surprising
    # the useful question is which file it came from.
    if [[ -n "$PROFILE" ]]; then
        info "profile: ${PROFILE}  (${PROFILE_FILE})"
        if [[ -f "$PROFILE_FILE" ]]; then cat "$PROFILE_FILE"; else info "  (empty)"; fi
        info "base: ${CONFIG_FILE}"
    fi
    [[ -f "$CONFIG_FILE" ]] && cat "$CONFIG_FILE" || info "No config yet at ${CONFIG_FILE}."
}

# Drops the cached database password for the active profile (all of them
# with --all), so the next command prompts again.
cmd_forget() {
    local all=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --all) all=1; shift ;;
        *) error_exit "forget: unknown flag: $1" ;;
    esac; done
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] || { info "Nothing cached (no XDG_RUNTIME_DIR)."; return; }
    local dir="${XDG_RUNTIME_DIR}/nordrassil"
    if [[ "$all" -eq 1 ]]; then
        rm -f "${dir}"/*.dbpass 2>/dev/null || true
        success "Forgot every cached database password."
    else
        rm -f "${dir}/${PROFILE:-default}.dbpass" 2>/dev/null || true
        success "Forgot the cached database password for ${PROFILE:-default}."
    fi
}

# -----------------------------------------------------------------------------
# apply-sql — run a .sql file against one of the server's databases.
#
# The thing 'configure' cannot do: apply a customization to a server that is
# already running, wherever it runs. It goes through _db_client_stdin, so it
# works over every transport and across ssh without knowing which is in use.
#
# Tracked by CONTENT, not by filename: the record is
# sql:<basename>@<sha256 prefix>, so re-running an unchanged file is a no-op
# while an edited one applies again on its own. Name-only tracking would mean
# passing --force after every edit, which for a file being iterated on is the
# wrong default.
#
# NOT atomic. DDL in MySQL/MariaDB is not transactional, so a file that fails
# halfway leaves whatever ran before the failure in place. The client stops at
# the first error and the applied record is only written on success, so a
# failed run is never recorded as done.
# -----------------------------------------------------------------------------

cmd_apply_sql() {
    header "nordrassil — Apply SQL"
    _settings

    local file="" db="" force=0 record=1
    while [[ $# -gt 0 ]]; do case "$1" in
        --file)      file="$2"; shift 2 ;;
        --db)        db="$2"; shift 2 ;;
        --force)     force=1; shift ;;
        --no-record) record=0; shift ;;
        *) error_exit "apply-sql: unknown flag: $1" ;;
    esac; done

    [[ -n "$file" ]] || error_exit "apply-sql: --file is required."
    file="${file/#\~/$HOME}"
    [[ -f "$file" && -r "$file" ]] || error_exit "apply-sql: cannot read ${file}."
    [[ -s "$file" ]] || error_exit "apply-sql: ${file} is empty."
    [[ -n "$db" ]] || error_exit "apply-sql: --db is required (mangos|characters|realmd|logs)."
    # Spliced into SQL as an identifier, where quoting would not help, so the
    # name is restricted instead.
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "apply-sql: --db '${db}' is not a valid database name."

    local dbt
    dbt="$(_db_transport)" || return 1
    _announce_db_target "$dbt"

    local sum name st
    sum="$(sha256sum "$file" | cut -c1-12)"
    name="sql:$(basename "$file")@${sum}"

    info "file:     ${file}"
    info "database: ${db}"
    info "record:   ${name}"

    # Checked up front: a missing database makes the client report "Unknown
    # database" once per statement, which reads like a problem with the file.
    local exists
    exists="$(_db_query_raw "SHOW DATABASES LIKE '$(_sql_escape "$db")';" 2>/dev/null)" || exists=""
    [[ -n "$exists" ]] || error_exit "apply-sql: database '${db}' does not exist on this server."

    if [[ "$record" -eq 1 ]]; then
        # The tracking table belongs to 'configure', but a server bootstrapped
        # by something else (kuat's own db-init, say) will not have it, and
        # apply-sql is exactly the command such a server needs.
        _db_exec "CREATE TABLE IF NOT EXISTS realmd.nordrassil_applied (name VARCHAR(255) PRIMARY KEY, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" >/dev/null \
            || error_exit "apply-sql: could not create the tracking table realmd.nordrassil_applied."
        st=0; _db_is_applied "$name" || st=$?
        [[ $st -ne 2 ]] || error_exit "apply-sql: could not read the import state of '${name}' from realmd.nordrassil_applied — refusing to apply blind (--no-record skips the check)."
        if [[ $st -eq 0 ]]; then
            if [[ "$force" -eq 0 ]]; then
                success "Already applied, identical content — nothing to do (--force applies it again)."
                return 0
            fi
            warn "Already applied; --force given, applying again."
        fi
    fi

    _db_import "$db" "$file" || error_exit "apply-sql: ${file} failed against ${db} — nothing recorded."
    [[ "$record" -eq 1 ]] && _db_mark_applied "$name"
    success "Applied $(basename "$file") to ${db}."
}

# -----------------------------------------------------------------------------
# restart — bring the server back, wherever it runs.
#
# Two ways, because they fail differently:
#
#   default      restart at the orchestrator (container restart, or deleting
#                the pod). Deterministic: it does not need mangosd to be
#                healthy enough to read its console.
#   --graceful   ask mangosd itself to restart in N seconds. Players are
#                warned and the world is saved, but it needs a working
#                console, and nothing happens if the server is already wedged.
#
# Either way nothing here starts it again: the container's restart policy
# does that (a Deployment's is always Always; run-docker uses
# --restart unless-stopped).
#
# N IS NOT HOW LONG THE RESTART TAKES. It is how long mangosd waits before
# stopping; coming back then depends on the supervisor noticing it stopped.
# Measured on a k8s deployment where mangosd and realmd share a container:
# mangosd stopped on schedule, but the container kept running until the
# liveness probe failed three times (30s period => ~90s) and kubelet sent
# TERM, so a 15s graceful restart took about 95s end to end. The default
# path has no such dependency, which is why it is the default.
# -----------------------------------------------------------------------------

cmd_restart() {
    header "nordrassil — Restart"
    _settings

    local graceful=0 delay=30
    while [[ $# -gt 0 ]]; do case "$1" in
        --graceful) graceful=1; shift
                    # An optional count follows: 'restart --graceful 60'.
                    if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then delay="$1"; shift; fi ;;
        --where)    WHERE="$2"; shift 2 ;;
        *) error_exit "restart: unknown flag: $1" ;;
    esac; done

    local target
    target=$(_server_transport) || return 1

    if [[ "$graceful" -eq 1 ]]; then
        info "Asking mangosd to restart in ${delay}s; players are warned and the world is saved."
        _send_console_cmd "$target" "server restart ${delay}" || return 1
        success "Restart scheduled (${target}): mangosd stops in ${delay}s."
        info "It comes back when the supervisor notices it stopped — with probes in"
        info "front of it that can be well after ${delay}s. 'server shutdown cancel'"
        info "on the console aborts the scheduled stop."
        return 0
    fi

    case "$target" in
        local)
            cmd_stop
            cmd_start
            ;;
        docker|podman)
            if [[ -z "$SERVER_SSH_HOST" ]]; then
                "$target" restart "$SERVER_CONTAINER_NAME" >/dev/null \
                    || error_exit "restart: '${target} restart ${SERVER_CONTAINER_NAME}' failed."
            else
                _remote_run "$SERVER_SSH_HOST" "$target" restart "$SERVER_CONTAINER_NAME" </dev/null >/dev/null \
                    || error_exit "restart: '${target} restart ${SERVER_CONTAINER_NAME}' failed on ${SERVER_SSH_HOST}."
            fi
            success "Restarted container ${SERVER_CONTAINER_NAME}."
            ;;
        kubectl)
            local pod
            pod="$(_kube_pick_pod "$SERVER_POD_SELECTOR" "$SERVER_SSH_HOST")" || return 1
            # Deleting the pod, NOT `kubectl rollout restart`.
            #
            # Deleting a pod changes no manifest, so a GitOps controller has
            # nothing to disagree with: the ReplicaSet simply makes another
            # one. Verified against Argo CD with selfHeal enabled — the
            # Application stayed Synced/Healthy across the restart and no
            # annotation was left on the pod template.
            #
            # rollout restart would instead stamp
            # kubectl.kubernetes.io/restartedAt into the Deployment's pod
            # template, i.e. change the live object away from git. The
            # expectation is that self-healing then reverts it and each write
            # rolls the pods again — but that is reasoning about selfHeal, NOT
            # something measured here, so it is a reason to prefer the delete
            # rather than a documented failure.
            info "Deleting pod ${pod}; its controller replaces it (no manifest change, so GitOps has nothing to revert)."
            _kube "$SERVER_SSH_HOST" delete pod -n "$K8S_NAMESPACE" "$pod" </dev/null \
                || error_exit "restart: deleting pod ${pod} failed."
            success "Pod ${pod} deleted; its replacement is starting."
            ;;
    esac
}

# -----------------------------------------------------------------------------
# dump / restore — back up and put back, over whatever transport is in use.
#
# Both go through the same client machinery as everything else, so a dump of a
# remote cluster's database and a dump of a local container are the same
# command with a different profile.
#
# The dump carries CREATE DATABASE/USE (mariadb-dump --databases), so it is
# self-describing and restore does not have to be told where it goes.
# -----------------------------------------------------------------------------

cmd_dump() {
    header "nordrassil — Dump"
    _settings

    local db="" all=0 out="" gz=1 tables=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --db)      db="$2"; shift 2 ;;
        --tables)  tables="$2"; shift 2 ;;
        --all)     all=1; shift ;;
        --out)     out="$2"; shift 2 ;;
        --no-gzip) gz=0; shift ;;
        *) error_exit "dump: unknown flag: $1" ;;
    esac; done

    [[ "$all" -eq 1 || -n "$db" ]] || error_exit "dump: pass --all or --db NAME (${NORDRASSIL_DBS[*]})."
    [[ "$all" -eq 1 && -n "$db" ]] && error_exit "dump: --all and --db are mutually exclusive."
    [[ -n "$tables" && "$all" -eq 1 ]] && error_exit "dump: --tables needs a single --db, not --all."
    [[ -n "$tables" && -z "$db" ]] && error_exit "dump: --tables also needs --db NAME."

    local -a dbs
    if [[ "$all" -eq 1 ]]; then
        dbs=( "${NORDRASSIL_DBS[@]}" )
    else
        [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "dump: --db '${db}' is not a valid database name."
        dbs=( "$db" )
    fi

    local dbt
    dbt="$(_db_transport)" || return 1
    _announce_db_target "$dbt"

    # Each database is checked before anything is written: mariadb-dump on a
    # missing one fails only after emitting part of its output, which would
    # leave a file that looks like a dump and is not one.
    local d exists
    for d in "${dbs[@]}"; do
        exists="$(_db_query_raw "SHOW DATABASES LIKE '$(_sql_escape "$d")';" 2>/dev/null)" || exists=""
        [[ -n "$exists" ]] || error_exit "dump: database '${d}' does not exist on this server."
    done

    # Named tables are checked to exist for the same reason the databases are:
    # mariadb-dump on a missing one fails only after emitting output.
    local -a tbl=()
    if [[ -n "$tables" ]]; then
        local t
        # shellcheck disable=SC2206
        for t in $tables; do
            [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "dump: '${t}' is not a valid table name."
            [[ -n "$(_db_query_raw "SHOW TABLES FROM \`${db}\` LIKE '$(_sql_escape "$t")';" 2>/dev/null)" ]] \
                || error_exit "dump: table '${db}.${t}' does not exist."
            tbl+=( "$t" )
        done
        [[ ${#tbl[@]} -gt 0 ]] || error_exit "dump: --tables was empty."
    fi

    if [[ -z "$out" ]]; then
        local what; if [[ "$all" -eq 1 ]]; then what="all"; elif [[ -n "$tables" ]]; then what="${db}-tables"; else what="$db"; fi
        out="${DUMP_DIR}/${PROFILE:-default}-${what}-$(date +%Y%m%d-%H%M%S).sql"
        [[ "$gz" -eq 1 ]] && out="${out}.gz"
        # Only the default location is tightened. An explicit --out is the
        # caller's directory and not this script's business to re-mode.
        _mkdir_private "$DUMP_DIR"
    fi
    out="${out/#\~/$HOME}"
    mkdir -p "$(dirname "$out")"

    info "databases: ${dbs[*]}"
    info "output:    ${out}"

    # --single-transaction: a consistent snapshot without locking out writers.
    # --events --routines: realmd ships an event, and a backup that silently
    #   drops schema objects is not a backup. Restoring them can need
    #   elevated privileges — see restore.
    local -a dargs
    if [[ ${#tbl[@]} -gt 0 ]]; then
        # A table list means no --databases, so the dump carries no CREATE
        # DATABASE or USE and is NOT self-describing: restore has to be told
        # --db. That is the point of it — the whole reason to dump a subset is
        # usually to leave the rest of the target database alone, and a dump
        # that named its own database could not do that.
        #
        # --events/--routines are database-level and meaningless here.
        dargs=( --single-transaction --quick --default-character-set=utf8mb4 "$db" "${tbl[@]}" )
        info "tables:    ${tbl[*]}"
        info "note:      a table dump names no database — restore it with --db ${db}"
    else
        dargs=( --single-transaction --quick --default-character-set=utf8mb4 --events --routines --databases "${dbs[@]}" )
    fi

    # Written to .partial and renamed only on success, so a dump that fails
    # halfway is never left looking like a usable backup. pipefail (set at the
    # top of this script) is what makes the gzip branch notice a mariadb-dump
    # failure instead of reporting gzip's own happy exit.
    local tmp="${out}.partial"
    rm -f "$tmp"
    # Created 0600 before the write rather than chmod'ed after, so it is never
    # briefly world-readable: a realmd dump carries every account row. The
    # redirections below truncate this file, which keeps its mode, and the mv
    # keeps it too.
    ( umask 077; : >"$tmp" )
    if [[ "$gz" -eq 1 ]]; then
        _db_dump "${dargs[@]}" | gzip -c >"$tmp" || { rm -f "$tmp"; error_exit "dump: failed — nothing written."; }
    else
        _db_dump "${dargs[@]}" >"$tmp" || { rm -f "$tmp"; error_exit "dump: failed — nothing written."; }
    fi
    [[ -s "$tmp" ]] || { rm -f "$tmp"; error_exit "dump: produced an empty file."; }

    # The output is believed only if it reads like a dump. For every transport
    # but tcp the stream crosses docker/podman/kubectl exec or ssh, and
    # anything else that writes to that stdout — an rc file's echo, a banner,
    # a "Defaulted container" notice — lands in the file AHEAD of the dump and
    # makes it unrestorable. The first line is the test, not a match anywhere
    # in the head, because prepended noise is exactly the failure: mariadb-dump
    # opens with '-- MariaDB dump ...'. restore applies the same test on the
    # way back in; catching it here means finding out now rather than during a
    # recovery.
    local first=""
    if [[ "$gz" -eq 1 ]]; then
        first="$(gzip -dc "$tmp" 2>/dev/null | head -1)" || true
    else
        first="$(head -1 "$tmp")" || true
    fi
    [[ "$first" == --* || "$first" == /\** ]] || {
        rm -f "$tmp"
        warn "first line: ${first}"
        error_exit "dump: the output does not start like a SQL dump — something else wrote to the stream (a login shell on ${DB_SSH_HOST:-this host}?). Nothing written."
    }
    mv -f "$tmp" "$out"

    success "Dumped ${dbs[*]} to ${out} ($(du -h "$out" | cut -f1))."
}

cmd_restore() {
    header "nordrassil — Restore"
    _settings

    local file="" db="" yes=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) file="$2"; shift 2 ;;
        --db)   db="$2"; shift 2 ;;
        --yes)  yes=1; shift ;;
        *) error_exit "restore: unknown flag: $1" ;;
    esac; done

    [[ -n "$file" ]] || error_exit "restore: --file is required."
    file="${file/#\~/$HOME}"
    [[ -f "$file" && -r "$file" ]] || error_exit "restore: cannot read ${file}."
    [[ -s "$file" ]] || error_exit "restore: ${file} is empty."
    [[ -z "$db" || "$db" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "restore: --db '${db}' is not a valid database name."

    # gzip detected by CONTENT, not by extension: a .sql that is really
    # gzipped, or a .gz that is not, would otherwise be fed to the client as
    # garbage and fail with a parse error halfway through.
    local reader=cat
    if [[ "$(head -c2 "$file" | od -An -tx1 | tr -d ' \n')" == "1f8b" ]]; then
        command -v gzip &>/dev/null || error_exit "restore: ${file} is gzipped and gzip is not installed."
        reader="gzip -dc"
    fi

    # Checked before handing the file to a client that can write everywhere.
    local head_txt
    # shellcheck disable=SC2086
    head_txt="$($reader "$file" 2>/dev/null | head -40)" || true
    grep -qiE 'mysql dump|mariadb dump|^CREATE |^INSERT |^USE ' <<<"$head_txt" \
        || error_exit "restore: ${file} does not look like a SQL dump (no header, CREATE, INSERT or USE in its first 40 lines)."

    # Which databases this will overwrite, read out of the dump itself rather
    # than assumed, so the warning names what actually happens.
    local named
    # shellcheck disable=SC2086
    named="$($reader "$file" 2>/dev/null \
             | grep -oiE '^(CREATE DATABASE[^`]*`|USE `)[^`]+`' \
             | grep -oE '`[^`]+`$' | tr -d '`' | sort -u | tr '\n' ' ')" || named=""

    local overwrites=""
    if [[ -n "$db" ]]; then
        # --db names the connection's DEFAULT database. It does NOT confine
        # the stream: every USE and CREATE DATABASE in the dump still applies,
        # so '--db mangos' on a full dump wrote characters, realmd and logs
        # as well while the warning named only mangos. Refused rather than
        # explained, because the request cannot be honoured as meant — and
        # this is the exact shape of the accident that put corelia's
        # realmlist into meksha's realmd.
        if [[ -n "${named// /}" ]]; then
            warn "This dump names its own databases: ${named}"
            warn "--db sets the default database for the connection; it does not confine the"
            warn "dump. Every USE in the file still applies, so --db ${db} would overwrite"
            warn "all of the above and report only ${db}."
            error_exit "restore: refusing --db on a self-describing dump. Drop --db to restore it as it is, or dump just the part you want: dump --db ${db} --tables 'name ...'."
        fi
        overwrites="$db (forced with --db)"
    else
        overwrites="$named"
    fi
    # Named overwrites, not targets: 'targets' is a local ARRAY in cmd_dump
    # and _db_run's helpers, and shellcheck reads the reuse across the file as
    # one variable (SC2178).
    [[ -n "${overwrites// /}" ]] || error_exit "restore: the dump names no database — pass --db NAME to say where it goes."

    # Resolved before the --yes gate, not after it, so the machine is named in
    # the same breath as the databases it would overwrite.
    local dbt
    dbt="$(_db_transport)" || return 1

    info "file:   ${file}"
    info "reader: ${reader}"
    _announce_db_target "$dbt"
    warn "OVERWRITES: ${overwrites}"

    [[ "$yes" -eq 1 ]] || error_exit "restore: refusing without --yes. This REPLACES the data in: ${overwrites} — on ${PROFILE:-<base config>} (${dbt})."

    # A running mangosd caches world data and holds character state in
    # memory, so after a restore it disagrees with its own database until it
    # is restarted. Not fatal, and some restores are deliberately done live,
    # but it is never not worth saying.
    warn "A running server caches world and character data — run 'restart' afterwards."

    # shellcheck disable=SC2086
    if [[ -n "$db" ]]; then
        $reader "$file" | _db_client_stdin "$db" || error_exit "restore: failed applying ${file} to ${db}."
    else
        $reader "$file" | _db_client_stdin || error_exit "restore: failed applying ${file}."
    fi
    success "Restored ${file} into ${overwrites}"
    info "Now: nordrassil.sh ${PROFILE:+--profile ${PROFILE} }restart"
}

# Lists the profiles in PROFILE_DIR, marking the active one.
cmd_profiles() {
    [[ -d "$PROFILE_DIR" ]] || { info "No profiles yet. Create one with: --profile NAME set KEY VALUE"; return; }
    local f name found=0
    for f in "$PROFILE_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .conf)"
        if [[ "$name" == "$PROFILE" ]]; then
            printf '* %s\n' "$name"
        else
            printf '  %s\n' "$name"
        fi
        found=1
    done
    [[ "$found" -eq 1 ]] || info "No profiles yet. Create one with: --profile NAME set KEY VALUE"
}

# Lists the Custom SQL files available to 'configure --custom' (basenames, no
# extension) — sql/Custom/*.sql under the configured SOURCE_DIR.
cmd_list_custom() {
    _settings
    local dir="${SOURCE_DIR}/sql/Custom"
    [[ -d "$dir" ]] || { info "No Custom SQL directory at ${dir}."; return; }
    local f found=0
    for f in "$dir"/*.sql; do
        [[ -e "$f" ]] || continue
        basename "$f" .sql
        found=1
    done
    [[ "$found" -eq 1 ]] || info "No Custom SQL files in ${dir}."
}

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

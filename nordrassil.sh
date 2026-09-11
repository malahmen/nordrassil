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
BUILD_DIR="${CONFIG_DIR}/build"
INSTALL_DIR="${CONFIG_DIR}/install"
SRC_UNPACK_DIR="${CONFIG_DIR}/src"
ETC_DIR="${CONFIG_DIR}/etc"
PF_DIR="${CONFIG_DIR}/pf"
MIGRATIONS_MARKER_DIR="${CONFIG_DIR}/applied-migrations"
IMAGE_BUILD_CONTEXT="${CONFIG_DIR}/image-build-context"

mkdir -p "$CONFIG_DIR" "$ETC_DIR" "$PF_DIR" "$MIGRATIONS_MARKER_DIR"

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

cfg_get() {
    grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true
}
cfg_set() {
    local key="$1" val="$2" quoted
    # The key is spliced into a regex and the value into a sed replacement;
    # the file is one key=value per line, so neither may carry a newline.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error_exit "set: invalid key '${key}' (letters, digits, underscore)."
    [[ "$val" != *$'\n'* ]] || error_exit "set: ${key}: value must not contain a newline."
    quoted="\"${val}\""
    touch "$CONFIG_FILE"
    if grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=$(_sed_escape "$quoted")|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    else
        echo "${key}=${quoted}" >> "$CONFIG_FILE"
    fi
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

_db_exec() {
    # _db_exec <sql>
    docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -e "$1"
}

_db_import() {
    # _db_import <database> <file>
    local db="$1" file="$2"
    [[ -f "$file" ]] || { warn "Missing SQL file, skipping: ${file}"; return 0; }
    docker exec -i "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" "$db" < "$file"
}

_ensure_local_mariadb() {
    if docker inspect --type container "$DB_CONTAINER_NAME" &>/dev/null; then
        docker start "$DB_CONTAINER_NAME" &>/dev/null || true
    else
        info "Starting local MariaDB container '${DB_CONTAINER_NAME}'..."
        docker run -d \
            --name "$DB_CONTAINER_NAME" \
            -e MARIADB_ROOT_PASSWORD="$DB_PASS" \
            -p "127.0.0.1:${DB_PORT}:3306" \
            -v "${DB_VOLUME}:/var/lib/mysql" \
            --restart unless-stopped \
            mariadb:11 &>/dev/null \
            || error_exit "Failed to start MariaDB container '${DB_CONTAINER_NAME}'."
    fi

    info "Waiting for MariaDB to accept connections..."
    local attempts=0
    until docker exec "$DB_CONTAINER_NAME" mariadb-admin ping -u"$DB_USER" -p"$DB_PASS" --silent &>/dev/null; do
        attempts=$((attempts + 1))
        [[ $attempts -ge 40 ]] && error_exit "Timed out waiting for MariaDB. Check: docker logs ${DB_CONTAINER_NAME}"
        sleep 1
    done
    success "MariaDB ready."
}

# _db_bootstrap — creates schemas, imports Base + world dump + Migrations
# (idempotent via marker files), optionally applies sql/Custom/*.sql.
_db_bootstrap() {
    local sql_dir="${SOURCE_DIR}/sql"
    [[ -d "$sql_dir" ]] || error_exit "sql/ directory not found under SOURCE_DIR: ${sql_dir}"

    info "Creating databases (realmd, mangos, characters, logs) if missing..."
    _db_exec "CREATE DATABASE IF NOT EXISTS realmd; CREATE DATABASE IF NOT EXISTS mangos; CREATE DATABASE IF NOT EXISTS characters; CREATE DATABASE IF NOT EXISTS logs;"

    if [[ ! -f "${MIGRATIONS_MARKER_DIR}/.base-imported" ]]; then
        info "Importing base schemas (sql/Base/*.sql)..."
        info "Importing sql/Base/logon.sql -> realmd..."
            bash -c "_db_import() { docker exec -i '${DB_CONTAINER_NAME}' mariadb -u'${DB_USER}' -p'${DB_PASS}' \"\$1\" < \"\$2\"; }; _db_import realmd '${sql_dir}/Base/logon.sql'" \
            || error_exit "Failed to import Base/logon.sql"
        _db_import mangos     "${sql_dir}/Base/world.sql"
        _db_import characters "${sql_dir}/Base/characters.sql"
        _db_import logs       "${sql_dir}/Base/logs.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.base-imported"
        success "Base schemas imported."
    else
        info "Base schemas already imported (marker present) — skipping."
    fi

    # sql/Anticheat/*.sql — despite living next to the optional Custom/
    # content, this is REQUIRED: the repack's Anticheat/Warden/antispam
    # features are always compiled in and mangosd hard-crashes at startup
    # (uncaught C++ exception) if e.g. realmd.antispam_blacklist doesn't
    # exist. Same per-database file naming as Base/.
    if [[ -d "${sql_dir}/Anticheat" ]] && [[ ! -f "${MIGRATIONS_MARKER_DIR}/.anticheat-imported" ]]; then
        info "Importing anticheat schemas (sql/Anticheat/*.sql) — required, not optional..."
        _db_import realmd     "${sql_dir}/Anticheat/realmd.sql"
        _db_import mangos     "${sql_dir}/Anticheat/world.sql"
        _db_import characters "${sql_dir}/Anticheat/characters.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.anticheat-imported"
        success "Anticheat schemas imported."
    else
        info "Anticheat schemas already imported (marker present) — skipping."
    fi

    if [[ ! -f "${MIGRATIONS_MARKER_DIR}/.world-full-imported" ]]; then
        local dump="${sql_dir}/world_full_14_june_2021.sql"
        [[ -f "$dump" ]] || error_exit "World dump not found: ${dump}"
        warn "Importing the full world dump (~250MB) — this can take several minutes."
        info "Importing world_full_14_june_2021.sql..."
            docker exec -i "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" mangos < "$dump" \
            || error_exit "Failed to import world_full_14_june_2021.sql"
        touch "${MIGRATIONS_MARKER_DIR}/.world-full-imported"
        success "World dump imported."
    else
        info "World dump already imported (marker present) — skipping."
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
        if [[ -f "${MIGRATIONS_MARKER_DIR}/${mname}.done" ]]; then
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
        touch "${MIGRATIONS_MARKER_DIR}/${mname}.done"
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
    # skipped; files already applied (marker present) are never re-applied.
    if [[ -d "${sql_dir}/Custom" && -n "${CUSTOM_SQL:-}" ]]; then
        local want cfile applied_custom=0
        local wanted="${CUSTOM_SQL//,/ }"
        for want in $wanted; do
            want="${want%.sql}"
            cfile="${sql_dir}/Custom/${want}.sql"
            [[ -f "$cfile" ]] || { warn "Custom script not found, skipping: ${want}.sql"; continue; }
            [[ -f "${MIGRATIONS_MARKER_DIR}/custom-${want}.sql.done" ]] && { info "Custom already applied: ${want}.sql"; continue; }
            _db_import mangos "$cfile" || warn "Custom script failed (continuing): ${want}.sql"
            touch "${MIGRATIONS_MARKER_DIR}/custom-${want}.sql.done"
            info "Applied: ${want}.sql"; applied_custom=$((applied_custom + 1))
        done
        [[ $applied_custom -gt 0 ]] && success "Custom content applied (${applied_custom})."
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
    local db_conn; db_conn="$(_sed_escape "${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS}")"
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
    local db_conn; db_conn="$(_sed_escape "${DB_HOST};${DB_PORT};${DB_USER};${DB_PASS}")"
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

cmd_start() {
    header "nordrassil — Start (local)"
    _settings

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

    # < <(sleep infinity): mangosd/realmd run an interactive console reader
    # on stdin. A backgrounded process normally inherits this shell's stdin,
    # which under nohup/non-interactive invocation delivers an immediate
    # EOF — the console reads that as an implicit quit, so the server fully
    # starts and then shuts itself down seconds later. Feeding stdin from a
    # process substitution that never writes and never exits keeps it open
    # without ever producing EOF (the container path hits the same issue —
    # fixed there with 'docker run -i' / pod stdin: true).
    if pf_is_running "$realmd_pf"; then
        warn "realmd already running (pid file present)."
    else
        (cd "${INSTALL_DIR}/bin" && nohup ./realmd >> "${INSTALL_DIR}/logs/realmd.out" 2>&1 < <(sleep infinity) &
         echo "$!:${REALM_PORT}" > "$realmd_pf")
        sleep 1
        pf_is_running "$realmd_pf" && success "realmd started (port ${REALM_PORT})." || warn "realmd did not start — check ${INSTALL_DIR}/logs/realmd.out"
    fi

    if pf_is_running "$mangosd_pf"; then
        warn "mangosd already running (pid file present)."
    else
        # mangosd gets a real FIFO instead of the sleep-infinity trick, so
        # 'create-account' can still reach its console. Unlike the container
        # path (where entrypoint.sh's own long-lived PID 1 process holds the
        # FIFO's write end open for free), this command returns immediately
        # after backgrounding mangosd, so nothing would otherwise keep a
        # writer attached — the FIFO would report EOF to mangosd on its next
        # read and trigger the same implicit-quit bug this whole thing exists
        # to avoid. A small detached 'sleep infinity' holds fd 9 open on the
        # FIFO for as long as mangosd itself is meant to run; 'stop' kills it
        # alongside mangosd.
        local mangosd_fifo="${INSTALL_DIR}/bin/mangosd.stdin"
        rm -f "$mangosd_fifo"
        mkfifo "$mangosd_fifo"
        ( exec 9<>"$mangosd_fifo"; exec sleep infinity ) &
        echo "$!" > "${PF_DIR}/mangosd-stdin-holder.pid"

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

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"
    local holder_pf="${PF_DIR}/mangosd-stdin-holder.pid"

    if pf_is_running "$mangosd_pf"; then pf_stop "$mangosd_pf"; else info "mangosd not running."; fi
    if pf_is_running "$realmd_pf";  then pf_stop "$realmd_pf";  else info "realmd not running.";  fi

    # Companion 'sleep infinity' that kept mangosd's console FIFO writable
    # (see 'start') — no longer needed once mangosd itself is stopped.
    if [[ -f "$holder_pf" ]]; then
        kill "$(cat "$holder_pf")" 2>/dev/null || true
        rm -f "$holder_pf"
    fi
    rm -f "${INSTALL_DIR}/bin/mangosd.stdin"
}

cmd_status() {
    header "nordrassil — Status"
    _settings

    _section "Local MariaDB"
    docker inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null || warn "Not created."

    _section "Local native processes"
    pf_is_running "${PF_DIR}/realmd.pid"  && success "realmd running (port $(pf_port "${PF_DIR}/realmd.pid"))"  || info "realmd not running."
    pf_is_running "${PF_DIR}/mangosd.pid" && success "mangosd running (port $(pf_port "${PF_DIR}/mangosd.pid"))" || info "mangosd not running."

    # --type container: SERVER_CONTAINER_NAME and IMAGE_TAG share a base
    # name ("vanilla-wow-server"), and plain 'docker inspect' falls back to
    # matching images when no container matches — without this it would
    # always report the image's (unrelated) state here instead of "Not created".
    _section "Server container"
    docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null || info "Not created."

    _section "Docker image"
    docker image inspect "$IMAGE_TAG" --format='{{.Id}}' 2>/dev/null || info "Not built."

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

# _detect_running_target — echoes "local"/"docker"/"k8s" on stdout for
# whichever deployment mangosd is actually running in right now, prompting
# if more than one qualifies. warn+return 1 if none does. Shared by every
# command below that needs to reach a live mangosd console.
_detect_running_target() {
    local -a targets=()
    pf_is_running "${PF_DIR}/mangosd.pid" && targets+=("local")
    [[ "$(docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        && targets+=("docker")
    # Same --context/--kind target as the exec path below — otherwise the
    # detection looks at the ambient kube context while the console command
    # goes to the requested one.
    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    if command -v kubectl &>/dev/null; then
        # shellcheck disable=SC2086
        kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-server --no-headers 2>/dev/null | grep -q Running \
            && targets+=("k8s")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "mangosd doesn't appear to be running anywhere (checked local, docker, k8s). Start it first."
        return 1
    fi

    # WHERE (from --where local|docker|k8s) disambiguates when mangosd is running
    # in more than one place; with a single target it's optional. The front-end
    # asks the operator only when needed and passes --where.
    local chosen="${targets[0]}"
    if [[ ${#targets[@]} -gt 1 ]]; then
        if [[ -n "${WHERE:-}" ]]; then
            printf '%s\n' "${targets[@]}" | grep -qx "$WHERE" \
                || { warn "--where '${WHERE}' isn't among the running targets: ${targets[*]}"; return 1; }
            chosen="$WHERE"
        else
            warn "mangosd is running in more than one place (${targets[*]}). Pass --where <${targets[0]}|...> to choose."
            return 1
        fi
    fi

    # k8s only: make sure a pod is actually addressable. Callers run this
    # function in a $(...) subshell, so nothing assigned here survives —
    # _send_console_cmd/_db_query resolve the context flags and pod name
    # themselves for the k8s case.
    if [[ "$chosen" == "k8s" ]]; then
        local pod
        # '|| pod=""': a failing kubectl must fall through to the warn below,
        # not kill the script silently under set -e (stderr is muted).
        # shellcheck disable=SC2086
        pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || pod=""
        if [[ -z "$pod" ]]; then
            warn "No running vanilla-wow-server pod found in namespace ${K8S_NAMESPACE}."
            return 1
        fi
    fi

    echo "$chosen"
}

# _detect_db_target — like _detect_running_target, but for queries that only
# need the database, not mangosd itself (e.g. search, which reads static
# reference tables that don't require the server to be up at all). Local
# native and Docker share the exact same local MariaDB container, so unlike
# _detect_running_target there's nothing to disambiguate between them —
# echoes "docker" for that shared container, "k8s" for the cluster's own
# separate MariaDB pod.
_detect_db_target() {
    if [[ "$(docker inspect --type container "$DB_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]]; then
        echo "docker"
        return 0
    fi
    if command -v kubectl &>/dev/null; then
        # Same --context/--kind target _db_query uses for the k8s case.
        local ctx_flags; ctx_flags="$(kubectl_context_flag)"
        # shellcheck disable=SC2086
        if kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb --no-headers 2>/dev/null | grep -q Running; then
            echo "k8s"
            return 0
        fi
    fi
    warn "No reachable database found (checked the local MariaDB container and K8s). Run 'configure' or 'run-k8s' first."
    return 1
}

# Escapes a value for embedding inside a single-quoted SQL string literal
# (backslash first, so it isn't double-escaped by the quote pass after it).
_sql_escape() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g"; }

# _db_query <target: local|docker|k8s> <sql> — local/docker share the same
# local MariaDB container (_db_exec); k8s has its own separate MariaDB pod
# in the cluster (see the architecture note on templates/k8s/mariadb.yaml),
# so that one needs its own kubectl exec instead of _db_exec's docker exec.
_db_query() {
    local tgt="$1" sql="$2"
    case "$tgt" in
        local|docker)
            # -t (table format), not _db_exec's plain tab-separated output —
            # every _db_query caller is a human-facing read, not the DB
            # bootstrap machinery _db_exec also serves.
            docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -t -e "$sql"
            ;;
        k8s)
            local ctx_flags pod
            ctx_flags="$(kubectl_context_flag)"
            pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -z "$pod" ]]; then
                warn "No running vanilla-wow-mariadb pod found in namespace ${K8S_NAMESPACE}."
                return 1
            fi
            kubectl $ctx_flags exec -n "$K8S_NAMESPACE" "$pod" -- mariadb -u"$DB_USER" -p"$DB_PASS" -t -e "$sql"
            ;;
    esac
}

# _db_query_raw <target> <sql> — like _db_query, but -N -B (no column
# headers, tab-separated, no ASCII table borders) for callers that need to
# actually parse a single value out of the result, not display it.
_db_query_raw() {
    local tgt="$1" sql="$2"
    case "$tgt" in
        local|docker)
            docker exec "$DB_CONTAINER_NAME" mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "$sql"
            ;;
        k8s)
            local ctx_flags pod
            ctx_flags="$(kubectl_context_flag)"
            pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -z "$pod" ]]; then
                warn "No running vanilla-wow-mariadb pod found in namespace ${K8S_NAMESPACE}."
                return 1
            fi
            kubectl $ctx_flags exec -n "$K8S_NAMESPACE" "$pod" -- mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "$sql"
            ;;
    esac
}

# _send_console_cmd <local|docker|k8s> <single console command line>
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
        docker)
            printf '%s\n' "$line" | docker exec -i "$SERVER_CONTAINER_NAME" sh -c "cat > /app/mangosd.stdin" \
                || { warn "Failed to reach the container's console FIFO."; return 1; }
            ;;
        k8s)
            # Same --context/--kind resolution as _db_query's k8s case.
            local ctx_flags pod
            ctx_flags="$(kubectl_context_flag)"
            # shellcheck disable=SC2086
            pod=$(kubectl $ctx_flags get pods -n "$K8S_NAMESPACE" -l app=vanilla-wow-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -z "$pod" ]]; then
                warn "No running vanilla-wow-server pod found in namespace ${K8S_NAMESPACE}."
                return 1
            fi
            # shellcheck disable=SC2086
            printf '%s\n' "$line" | kubectl $ctx_flags exec -i -n "$K8S_NAMESPACE" "$pod" -- sh -c "cat > /app/mangosd.stdin" \
                || { warn "Failed to reach the pod's console FIFO."; return 1; }
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
    target=$(_detect_running_target) || return 1

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
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs deployment/vanilla-wow-server" ;;
    esac

    success "Account '${user_input}' created (GM level: ${gm_num})."
}

# _print_accounts_table <target> — shared by list-accounts and
# delete-account (as a courtesy display before prompting for a username),
# so delete-account doesn't need to run _detect_running_target a second time
# (and risk a second "which target?" prompt) just to show the same list.
_print_accounts_table() {
    local target="$1"
    # GM level lives in account_access (per-realm), not account.gmlevel,
    # which is vestigial (see create-account's notes). LEFT JOIN so an
    # account with no account_access row still shows up, as GM level 0.
    _db_query "$target" \
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
    target=$(_detect_running_target) || return 1

    _print_accounts_table "$target" || return 1
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
    target=$(_detect_running_target) || return 1

    # Needed for the account_access cleanup below: that row can only be
    # looked up by account id, and 'account delete' removes the account row
    # itself, so the id has to be captured before the console command runs.
    # stderr muted (the mariadb client's password-on-command-line notice), so
    # a failed query must be reported here — under set -e a bare failing
    # assignment would otherwise end the script with no message at all.
    local acc_id user_sql; user_sql="$(_sql_escape "${user_input^^}")"
    acc_id=$(_db_query_raw "$target" "SELECT id FROM realmd.account WHERE username='${user_sql}';" 2>/dev/null) \
        || { warn "Account id lookup failed (is MariaDB reachable with DB_USER/DB_PASS?) — the account_access cleanup below will be skipped."; acc_id=""; }

    _send_console_cmd "$target" "account delete ${user_input}" || return 1

    # AccountMgr::DeleteAccount (confirmed directly in the source) cleans up
    # characters/character_tutorial/account/realmcharacters, but never
    # account_access — a real, if harmless, upstream gap (an orphaned row
    # can never rejoin a real account again, ids aren't reused). Sweep it
    # here so repeated create/delete cycles don't quietly accumulate junk.
    if [[ "$acc_id" =~ ^[0-9]+$ ]]; then
        sleep 2
        _db_query "$target" "DELETE FROM realmd.account_access WHERE id=${acc_id};" &>/dev/null || true
    fi

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs deployment/vanilla-wow-server" ;;
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
    target=$(_detect_running_target) || return 1

    _send_console_cmd "$target" "account set gmlevel ${user_input} ${gm_num}" || return 1

    case "$target" in
        local)  info "Check ${INSTALL_DIR}/logs/mangosd.out to confirm." ;;
        docker) info "Check: docker logs ${SERVER_CONTAINER_NAME}" ;;
        k8s)    info "Check: kubectl -n ${K8S_NAMESPACE} logs deployment/vanilla-wow-server" ;;
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
# running at all (_detect_db_target, not _detect_running_target) — but the
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
    target=$(_detect_db_target) || return 1

    local old_name_escaped; old_name_escaped="$(_sql_escape "$old_name")"
    local row guid online
    # See delete-account: stderr is muted, so a failed query is reported here
    # rather than silently ending the script under set -e.
    row=$(_db_query_raw "$target" "SELECT guid, online FROM characters.characters WHERE name='${old_name_escaped}';" 2>/dev/null) \
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
    existing=$(_db_query_raw "$target" "SELECT guid FROM characters.characters WHERE name='${new_name_escaped}';" 2>/dev/null) \
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
    _db_query "$target" "UPDATE characters.characters SET name='${new_name_escaped}', character_flags = character_flags & ~0x4000 WHERE guid=${guid};" &>/dev/null || return 1
    success "'${old_name}' renamed to '${new_name}'."
}

# -----------------------------------------------------------------------------
# search — name lookup for items, NPCs, GM teleport locations, and player
# characters. All four are plain reference-data reads (no SRP6/console
# involved, unlike the account commands), so this goes straight to the
# database via _db_query, and works even if mangosd itself isn't running —
# only the database needs to be up (_detect_db_target, not
# _detect_running_target).
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
    target=$(_detect_db_target) || return 1
    local term_escaped; term_escaped="$(_sql_escape "$term")"

    case "$kind" in
        items)
            # item_template/creature_template key on (entry, patch) — the
            # same entry can have a different row per patch it changed in.
            # Without filtering, a search can show stale/duplicate rows for
            # an item that changed since; the correlated subquery picks the
            # latest row at or before the configured WOW_PATCH, matching
            # what's actually loaded on this server.
            _db_query "$target" \
                "SELECT it.entry, it.name, it.quality FROM mangos.item_template it
                 WHERE it.name LIKE '%${term_escaped}%' AND it.patch = (
                     SELECT MAX(patch) FROM mangos.item_template it2 WHERE it2.entry = it.entry AND it2.patch <= ${WOW_PATCH}
                 ) ORDER BY it.name LIMIT 50;" || return 1
            ;;
        npcs)
            _db_query "$target" \
                "SELECT ct.entry, ct.name, ct.subname FROM mangos.creature_template ct
                 WHERE ct.name LIKE '%${term_escaped}%' AND ct.patch = (
                     SELECT MAX(patch) FROM mangos.creature_template ct2 WHERE ct2.entry = ct.entry AND ct2.patch <= ${WOW_PATCH}
                 ) ORDER BY ct.name LIMIT 50;" || return 1
            ;;
        teleports)
            # game_tele — the table the '.tele <name>' GM command itself
            # searches, no patch column here.
            _db_query "$target" \
                "SELECT id, name, map, ROUND(position_x,1) AS x, ROUND(position_y,1) AS y
                 FROM mangos.game_tele WHERE name LIKE '%${term_escaped}%' ORDER BY name LIMIT 50;" || return 1
            ;;
        characters)
            _db_query "$target" \
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
    local db_pass_b64; db_pass_b64="$(printf '%s' "$DB_PASS" | base64 | tr -d '\n')"
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
    [[ -f "$CONFIG_FILE" ]] && cat "$CONFIG_FILE" || info "No config yet at ${CONFIG_FILE}."
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

Usage: nordrassil.sh [--context CTX | --kind CLUSTER] <command> [flags]

Global flags (kube target for run-k8s/stop-k8s):
  --context CTX        use kube-context CTX
  --kind CLUSTER       use kind cluster CLUSTER (context kind-CLUSTER; side-loads the image)

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

Search:
  search --kind items|npcs|teleports|characters --term TERM

Config store (used by the scomp-link front-end):
  set KEY VALUE | get KEY | config | list-custom

  help | -h | --help
EOF
}

main() {
    # Global flags first (kube target), then the subcommand.
    while [[ $# -gt 0 ]]; do case "$1" in
        --context) KUBE_CONTEXT="$2"; shift 2 ;;
        --kind)    KIND_CLUSTER="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) error_exit "Unknown global flag: $1" ;;
        *) break ;;
    esac; done

    [[ $# -gt 0 ]] || { usage; exit 2; }

    local cmd="$1"; shift
    case "$cmd" in
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
        build-image)        cmd_build_image "$@" ;;
        run-docker)         cmd_run_docker "$@" ;;
        stop-docker)        cmd_stop_docker "$@" ;;
        run-k8s)            cmd_run_k8s "$@" ;;
        stop-k8s)           cmd_stop_k8s "$@" ;;
        set)                cmd_set "$@" ;;
        get)                cmd_get "$@" ;;
        config)             cmd_config "$@" ;;
        list-custom)        cmd_list_custom "$@" ;;
        -h|--help|help)     usage ;;
        *) error_exit "Unknown command: $cmd (run with --help for usage)" ;;
    esac
}

main "$@"

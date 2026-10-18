# shellcheck shell=bash
# lib/common.sh — Logging, package and pidfile helpers, the kube target flags, and the
# escaping every other file uses. Sourced first.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

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

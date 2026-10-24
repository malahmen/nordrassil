# shellcheck shell=bash
# lib/config.sh — Paths, the key=value config store and profiles, the resolved settings,
# and the commands that read or change them (set, get, config, forget, profiles).
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

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
    _setting_problem "$key" "$val" || error_exit "set: ${key} must be ${_why} (got '${val}')."
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

# _setting_problem <key> <value> — for a numeric setting, sets _why to what
# the value must be and returns 1 when it is not that; any other key passes.
# These go unquoted into SQL (realmlist, the search queries), into sed
# replacements over the conf files and into the k8s YAML, so a typo there
# breaks the server's config instead of being refused. A global, not $(...):
# _require_valid_settings runs it for every key on every command.
_setting_problem() {
    local key="$1" val="$2"
    _why=""
    case "$key" in
        DB_PORT|REALM_PORT|WORLD_PORT)
            [[ "$val" =~ ^[0-9]{1,5}$ ]] && (( 10#$val >= 1 && 10#$val <= 65535 )) \
                || _why="a port, 1-65535" ;;
        REALM_ID|REALM_ZONE|GAME_TYPE|WOW_PATCH|CLIENT_BUILD|WRONG_PASS_MAX_COUNT|WRONG_PASS_BAN_TIME|WRONG_PASS_BAN_TYPE)
            [[ "$val" =~ ^[0-9]{1,9}$ ]] || _why="a whole number, 0 or more" ;;
        # mangosd.conf: 0 = no limit, -1/-2/-3 = staff only.
        PLAYER_LIMIT)
            [[ "$val" =~ ^(-[1-3]|[0-9]{1,9})$ ]] || _why="a whole number, or -1, -2 or -3 for staff only" ;;
        REQ_EMAIL_VERIFICATION|STRICT_VERSION_CHECK|WARDEN_ENABLED)
            [[ "$val" =~ ^[01]$ ]] || _why="0 or 1" ;;
        STRICT_PLAYER_NAMES)
            [[ "$val" =~ ^[0-3]$ ]] || _why="0, 1, 2 or 3" ;;
        XP_RATE|DROP_RATE)
            [[ "$val" =~ ^[0-9]{1,6}(\.[0-9]{1,6})?$ ]] || _why="a number such as 1, 2 or 0.5" ;;
    esac
    [[ -z "$_why" ]]
}

# A bad value already stored - by hand, or before cfg_set checked - stops
# every command that would write it somewhere. Not the ones that read or fix
# the config: MANAGED_EXTERNALLY showed what a fatal check in _settings does
# when 'set' itself cannot run past it.
_require_valid_settings() {
    case "${SUBCMD:-}" in set|get|config|profiles|forget) return 0 ;; esac
    local k bad=0
    for k in "${SETTING_KEYS[@]}"; do
        _setting_problem "$k" "${!k}" && continue
        warn "${k}='${!k}' is not ${_why}."
        bad=1
    done
    (( bad == 0 )) || error_exit "Not using a setting that would break the conf files, SQL or manifests. Fix it with: ${0##*/} ${PROFILE:+--profile ${PROFILE} }set KEY VALUE"
}

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
    _require_valid_settings
}

# -----------------------------------------------------------------------------
# Config subcommands — the front-end (scomp-link's wow-vmangos-nordrassil TUI) collects
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

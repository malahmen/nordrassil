# shellcheck shell=bash
# lib/provision.sh — The gate in front of every command that provisions (local, and owned by
# this script), the local MariaDB, the conf files, configure and edit.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

# _require_owned_target <command> — the one gate in front of every command
# that provisions, stops or re-bootstraps a server: configure, edit, start,
# stop, build-image, run-docker, stop-docker, run-k8s, stop-k8s. It passes
# only a target this script owns (not MANAGED_EXTERNALLY) on this machine
# (no profile pointing elsewhere). Administration does not go through it: it
# reaches the server through the transports, wherever that is.
_require_owned_target() {
    _refuse_if_managed "$1"
    _refuse_if_remote "$1"
}

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
# kubectl and docker over ssh; refusing costs a few lines and closes the hole. The commands that ADMINISTER a remote
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
_refuse_if_managed() {
    [[ "$MANAGED_EXTERNALLY" == "1" ]] || return 0
    warn "'${1}' provisions or re-bootstraps a server, and this profile${PROFILE:+ (${PROFILE})} is marked"
    warn "MANAGED_EXTERNALLY=1 — something else owns it (Ansible, a GitOps controller, CI)."
    warn "Administration still works: accounts, characters, search, apply-sql, dump, restore, restart, status."
    error_exit "Refusing to run '${1}' against an externally managed server."
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
    _require_owned_target configure
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
    _require_owned_target edit

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

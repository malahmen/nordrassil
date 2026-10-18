# shellcheck shell=bash
# lib/admin.sh — Administering a running server, wherever it is: status, accounts,
# characters, search and restart.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

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

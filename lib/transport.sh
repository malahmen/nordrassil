# shellcheck shell=bash
# lib/transport.sh — How this script reaches the database and the server: ssh, kubectl,
# docker/podman exec, the password, and the console FIFO.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

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

# Escapes a value for embedding inside a single-quoted SQL string literal.
# lib/bootstrap.sh's, so the engine and the k8s Job escape the same way.
_sql_escape() { bs_sql_escape "$1"; }

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

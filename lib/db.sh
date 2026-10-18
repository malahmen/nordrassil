# shellcheck shell=bash
# lib/db.sh — The database's contents: the bootstrap and its bookkeeping, realmlist,
# apply-sql, dump, restore and list-custom.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

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

# shellcheck shell=bash
# lib/bootstrap.sh — the database bootstrap: schemas, Base + Anticheat, the
# world dump, Migrations, the selected Custom scripts, the realmlist row, and
# the bookkeeping table that makes every step idempotent.
#
# ONE copy, run in two places. nordrassil.sh sources it for 'configure' and
# 'run-docker'; run-k8s ships it to the db-init Job in a ConfigMap, next to
# templates/k8s/db-init.sh. There used to be two: _db_bootstrap here and a
# bash script inlined in db-init-job.yaml, and they had drifted (which
# failures stopped the run, what an untracked database was seeded with, the
# Job's password on argv).
#
# So nothing in here may use the engine: no _db_*, no info/warn, no settings.
# What differs between the two places is passed in as these functions, which
# the caller defines before calling bs_run:
#
#   bs_sql_exec <sql>             run statements, no default database
#   bs_sql_query <sql>            one result, no headers (-N -B); non-zero on error
#   bs_sql_import <db> <file>     feed a file to the client against <db>
#   bs_info / bs_ok / bs_warn <msg>
#   bs_die <msg>                  report and stop the whole run
#   bs_seed_untracked             the tracking table was missing on a database
#                                 that is already bootstrapped: record what an
#                                 older run imported (the engine reads its old
#                                 marker files; the Job marks everything)
#
# and these variables: CUSTOM_SQL, REALM_ID, REALM_NAME, REALM_ADDRESS,
# WORLD_PORT, CLIENT_BUILD.
#
# Row names in realmd.nordrassil_applied: "base", "anticheat", "world-full",
# "migration:<file>.sql", "custom:<file>.sql".

# bs_sql_escape <string> — for a single-quoted SQL literal: backslash first,
# then the quote.
bs_sql_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }

# bs_table_exists <database> <table> — a failed query reads as "no".
bs_table_exists() {
    local out
    out="$(bs_sql_query "SHOW TABLES FROM ${1} LIKE '$(bs_sql_escape "$2")';" 2>/dev/null)" || out=""
    [[ -n "$out" ]]
}

# bs_applied <name> — 0 applied, 1 not applied, 2 cannot tell.
#
# The third state is the point. A failed query used to read as "not
# applied", so an unreachable database or a failed login made every import
# look pending and the next step imported the world dump on top of live data.
bs_applied() {
    local out rc=0
    out="$(bs_sql_query "SELECT 1 FROM realmd.nordrassil_applied WHERE name='$(bs_sql_escape "$1")' LIMIT 1;" 2>/dev/null)" || rc=$?
    [[ $rc -eq 0 ]] || return 2
    [[ -n "$out" ]]
}

# bs_applied_or_die <name> — bs_applied, with "cannot tell" fatal: for the
# bootstrap imports the alternative to knowing is writing over what is there.
bs_applied_or_die() {
    local st=0
    bs_applied "$1" || st=$?
    [[ $st -ne 2 ]] || bs_die "Could not read the import state of '${1}' from realmd.nordrassil_applied. Refusing to continue — the next step would import on top of whatever is already in the database."
    return $st
}

# bs_mark <name> — INSERT IGNORE, so a re-run after a partial failure does
# not trip over the primary key.
bs_mark() {
    bs_sql_exec "INSERT IGNORE INTO realmd.nordrassil_applied (name) VALUES ('$(bs_sql_escape "$1")');" >/dev/null \
        || bs_warn "Could not record '${1}' as applied — it will be imported again on the next run."
}

# bs_import <db> <file> — a file the bootstrap needs. Missing is fatal: an
# import skipped and then recorded as done would never be retried.
bs_import() {
    [[ -f "$2" ]] || bs_die "Missing SQL file: ${2}"
    bs_sql_import "$1" "$2" || bs_die "Failed to import ${2##*/} into ${1}."
}

# bs_run <sql dir> — the whole bootstrap, in order.
bs_run() {
    local sql_dir="$1"
    [[ -d "$sql_dir" ]] || bs_die "sql/ directory not found: ${sql_dir}"

    bs_info "Creating databases (realmd, mangos, characters, logs) if missing..."
    bs_sql_exec "CREATE DATABASE IF NOT EXISTS realmd; CREATE DATABASE IF NOT EXISTS mangos; CREATE DATABASE IF NOT EXISTS characters; CREATE DATABASE IF NOT EXISTS logs;" \
        || bs_die "Failed to create the databases."

    # Whether the tracking table existed has to be known BEFORE creating it:
    # absent on a database that already has realmd.account means an older
    # version did the importing, and what it imported must be recorded rather
    # than imported again.
    local had_tracking=0
    bs_table_exists realmd nordrassil_applied && had_tracking=1
    bs_sql_exec "CREATE TABLE IF NOT EXISTS realmd.nordrassil_applied (name VARCHAR(255) PRIMARY KEY, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" \
        || bs_die "Failed to create realmd.nordrassil_applied (the import bookkeeping table)."
    if [[ $had_tracking -eq 0 ]] && bs_table_exists realmd account; then
        bs_info "Existing bootstrapped database without import state — recording what is already imported."
        bs_seed_untracked
    fi

    if bs_applied_or_die base; then
        bs_info "Base schemas already imported (recorded in the database) — skipping."
    else
        bs_info "Importing base schemas (sql/Base/*.sql)..."
        bs_import realmd     "${sql_dir}/Base/logon.sql"
        bs_import mangos     "${sql_dir}/Base/world.sql"
        bs_import characters "${sql_dir}/Base/characters.sql"
        bs_import logs       "${sql_dir}/Base/logs.sql"
        bs_mark base
        bs_ok "Base schemas imported."
    fi

    # sql/Anticheat — required, not optional, despite living next to Custom/:
    # the Anticheat/Warden/antispam features are always compiled in, and
    # mangosd hard-crashes at startup if e.g. realmd.antispam_blacklist does
    # not exist.
    if [[ -d "${sql_dir}/Anticheat" ]]; then
        if bs_applied_or_die anticheat; then
            bs_info "Anticheat schemas already imported (recorded in the database) — skipping."
        else
            bs_info "Importing anticheat schemas (sql/Anticheat/*.sql) — required, not optional..."
            bs_import realmd     "${sql_dir}/Anticheat/realmd.sql"
            bs_import mangos     "${sql_dir}/Anticheat/world.sql"
            bs_import characters "${sql_dir}/Anticheat/characters.sql"
            bs_mark anticheat
            bs_ok "Anticheat schemas imported."
        fi
    fi

    if bs_applied_or_die world-full; then
        bs_info "World dump already imported (recorded in the database) — skipping."
    else
        bs_warn "Importing the full world dump (~250MB) — this can take several minutes."
        bs_import mangos "${sql_dir}/world_full_14_june_2021.sql"
        bs_mark world-full
        bs_ok "World dump imported."
    fi

    # Migrations/ holds one file per migration for all four databases, routed
    # by suffix, each with a numeric timestamp prefix. It also holds four
    # pre-merged "*_db_updates.sql" aggregates and merge.bat/merge.sh/README,
    # none with a numeric prefix: applying the aggregates on top of the
    # individual files would apply the same changes twice, so only
    # [0-9]*.sql is used. A glob, not `find | while read`: a transport that
    # forwards stdin would swallow the rest of the file list.
    local mfile mname target_db applied=0 skipped=0
    for mfile in "${sql_dir}"/Migrations/[0-9]*.sql; do
        [[ -e "$mfile" ]] || continue
        mname="${mfile##*/}"
        if bs_applied_or_die "migration:${mname}"; then
            skipped=$((skipped + 1)); continue
        fi
        case "$mname" in
            *_world.sql)      target_db=mangos ;;
            *_characters.sql) target_db=characters ;;
            *_logon.sql)      target_db=realmd ;;
            *_logs.sql)       target_db=logs ;;
            *) bs_warn "Skipping migration with unrecognized suffix: ${mname}"; continue ;;
        esac
        bs_import "$target_db" "$mfile"
        bs_mark "migration:${mname}"
        applied=$((applied + 1))
    done
    bs_info "Migrations: ${applied} applied, ${skipped} already up to date."

    # Custom/ is a grab-bag, not one feature: it holds both
    # ADD_GM_ISLAND_VENDORS.sql and REMOVE_GM_ISLAND_VENDORS.sql, and
    # START_ON_GM_ISLAND.sql, an UPDATE with no WHERE that spawns every new
    # character on GM Island. So only the scripts named in CUSTOM_SQL (comma-
    # or space-separated basenames, without .sql) are applied, each once.
    local want cfile st applied_custom=0 failed_custom=0
    for want in ${CUSTOM_SQL//,/ }; do
        want="${want%.sql}"
        [[ -n "$want" ]] || continue
        cfile="${sql_dir}/Custom/${want}.sql"
        [[ -f "$cfile" ]] || { bs_warn "Custom script not found, skipping: ${want}.sql"; continue; }
        st=0; bs_applied "custom:${want}.sql" || st=$?
        if [[ $st -eq 0 ]]; then
            bs_info "Custom already applied: ${want}.sql"; continue
        elif [[ $st -eq 2 ]]; then
            # Not fatal, unlike the imports above: one Custom script can be
            # skipped and the rest still finished. Skipped, not applied,
            # because applying it twice is the direction that cannot be undone.
            bs_warn "Cannot tell whether ${want}.sql was already applied (the tracking query failed) — skipping it."
            failed_custom=$((failed_custom + 1)); continue
        fi
        if bs_sql_import mangos "$cfile"; then
            bs_mark "custom:${want}.sql"
            bs_info "Applied: ${want}.sql"; applied_custom=$((applied_custom + 1))
        else
            # NOT marked: a script recorded as applied after a failed import
            # could never run again, including after it was fixed.
            bs_warn "Custom script FAILED and was NOT recorded as applied: ${want}.sql"
            bs_warn "  Fix it and run the bootstrap again; a partial import may need undoing by hand."
            failed_custom=$((failed_custom + 1))
        fi
    done
    [[ $applied_custom -eq 0 ]] || bs_ok "Custom content applied (${applied_custom})."
    [[ $failed_custom -eq 0 ]] || bs_warn "Custom scripts not applied: ${failed_custom} (see above)."

    bs_realmlist
}

# bs_realmlist — no SQL dump seeds realmlist: the realm's reachable address is
# deployment-specific, and mangosd refuses to start without the row ("Config
# contains invalid realmID"). An upsert, not tracked, so it follows the
# current REALM_ADDRESS / WORLD_PORT / CLIENT_BUILD on every run.
bs_realmlist() {
    bs_info "Ensuring realmlist row (id=${REALM_ID}, name=${REALM_NAME}, address=${REALM_ADDRESS}:${WORLD_PORT})..."
    local name_sql addr_sql
    name_sql="$(bs_sql_escape "$REALM_NAME")"; addr_sql="$(bs_sql_escape "$REALM_ADDRESS")"
    bs_sql_exec "INSERT INTO realmd.realmlist (id, name, address, localAddress, localSubnetMask, port, gamebuild_min, gamebuild_max)
        VALUES (${REALM_ID}, '${name_sql}', '${addr_sql}', '127.0.0.1', '255.255.255.0', ${WORLD_PORT}, ${CLIENT_BUILD}, ${CLIENT_BUILD})
        ON DUPLICATE KEY UPDATE name='${name_sql}', address='${addr_sql}', port=${WORLD_PORT}, gamebuild_min=${CLIENT_BUILD}, gamebuild_max=${CLIENT_BUILD};" \
        || bs_die "Failed to write the realmlist row."
    bs_ok "realmlist ready."
}

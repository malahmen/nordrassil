#!/usr/bin/env bash
# The k8s db-init Job's entry point: lib/bootstrap.sh, the same bootstrap
# 'configure' runs, over the mariadb client in the Job's own container.
# run-k8s ships both files in the vanilla-wow-db-init ConfigMap, mounted at
# /bootstrap; the repack's sql/ is mounted at /sql.
#
# The password is in MYSQL_PWD, which the client reads when no -p is given:
# it used to be -p"${DB_PASS}", on the argv of every client call.
set -euo pipefail

: "${DB_PASS:?DB_PASS is not set (it comes from the vanilla-wow-db Secret)}"
export MYSQL_PWD="$DB_PASS"
DB_INIT_HOST="${DB_INIT_HOST:-mariadb}"   # the in-cluster Service
SQL_DIR="${SQL_DIR:-/sql}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_mysql() { mariadb -h "$DB_INIT_HOST" -uroot "$@"; }
bs_sql_exec()   { _mysql -e "$1"; }
bs_sql_query()  { _mysql -N -B -e "$1"; }
bs_sql_import() { _mysql "$1" < "$2"; }
bs_info()       { echo "$*"; }
bs_ok()         { echo "$*"; }
bs_warn()       { echo "WARNING: $*" >&2; }
bs_die()        { echo "FATAL: $*" >&2; exit 1; }

# An older version of this Job imported everything mounted at /sql,
# Custom/ included, before the tracking table existed. So everything is
# recorded - only the current selection would re-import the rest.
bs_seed_untracked() {
    local f
    bs_mark base
    [[ -d "${SQL_DIR}/Anticheat" ]] && bs_mark anticheat
    bs_mark world-full
    for f in "${SQL_DIR}"/Migrations/[0-9]*.sql; do [[ -e "$f" ]] && bs_mark "migration:${f##*/}"; done
    for f in "${SQL_DIR}"/Custom/*.sql;          do [[ -e "$f" ]] && bs_mark "custom:${f##*/}"; done
    return 0
}

# shellcheck source=../../lib/bootstrap.sh
source "${HERE}/bootstrap.sh"

# A query, not mariadb-admin ping: ping reports a server that refused the
# login as alive, and the bootstrap would then fail on its first statement.
# Bounded, so a wrong password fails the Job instead of waiting forever.
tries=0
until bs_sql_query "SELECT 1;" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ $tries -lt 150 ]] || bs_die "mariadb at ${DB_INIT_HOST} did not accept a login in 5 minutes."
    echo "Waiting for mariadb..."; sleep 2
done

bs_run "$SQL_DIR"
echo "DB bootstrap complete."

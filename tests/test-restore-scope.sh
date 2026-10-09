#!/usr/bin/env bash
# N4: --db must not be accepted on a dump that names its own databases.
# shellcheck disable=SC2034
# The globals below and the `out`/`rc` captures are consumed by engine
# functions pulled in with eval, and by the single-quoted assertions chk
# evaluates — neither of which shellcheck can see from here.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${NORDRASSIL:-${TEST_DIR}/../nordrassil.sh}"
[ -f "$ENG" ] || { echo "nordrassil.sh not found at $ENG" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Stubs shadow the real clients and orchestrators: no test here may reach a
# database, a docker socket or a cluster.
export PATH="${TEST_DIR}/stubs:$PATH"
export XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T/run"
mkdir -p "$T/config" "$T/run"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for kv in "DB_TRANSPORT tcp" "DB_HOST 127.0.0.1" "DB_PORT 3306" "DB_USER mangos" "DB_PASS 8charsec"; do
    bash "$ENG" --profile p set $kv >/dev/null
done

# A full dump: self-describing, writes the databases it names.
cat > "$T/full.sql" <<'SQL'
-- MariaDB dump 10.19  Distrib 10.11.6-MariaDB
CREATE DATABASE IF NOT EXISTS `mangos`;
USE `mangos`;
INSERT INTO `creature` VALUES (1);
CREATE DATABASE IF NOT EXISTS `realmd`;
USE `realmd`;
INSERT INTO `realmlist` VALUES (1,'x','192.168.3.46');
SQL
# A table dump: names no database, so --db is how it is aimed. The designed use.
cat > "$T/tables.sql" <<'SQL'
-- MariaDB dump 10.19  Distrib 10.11.6-MariaDB
INSERT INTO `account` VALUES (1);
SQL

echo "== a full dump with --db"
out="$(bash "$ENG" --profile p restore --file "$T/full.sql" --db mangos --yes 2>&1)"; rc=$?
chk "refused"                               '[[ $rc -ne 0 ]]'
chk "names the databases the dump writes"   'grep -q "names its own databases: mangos realmd" <<<"$out"'
chk "explains --db does not confine it"     'grep -q "does not confine" <<<"$out"'
chk "suggests the table dump instead"       'grep -q -- "--tables" <<<"$out"'

echo "== the two cases that must still work"
out="$(bash "$ENG" --profile p restore --file "$T/tables.sql" --db mangos --yes 2>&1)"; rc=$?
chk "a table dump with --db still restores" '[[ $rc -eq 0 ]] && grep -q "OVERWRITES: mangos (forced" <<<"$out"'
out="$(bash "$ENG" --profile p restore --file "$T/full.sql" --yes 2>&1)"; rc=$?
chk "a full dump with no --db still restores" '[[ $rc -eq 0 ]]'
chk "  and names both databases"             'grep -q "OVERWRITES: mangos realmd" <<<"$out"'
out="$(bash "$ENG" --profile p restore --file "$T/tables.sql" --yes 2>&1)"; rc=$?
chk "a table dump with no --db is refused"   '[[ $rc -ne 0 ]] && grep -q "names no database" <<<"$out"'

printf '\n  pass=%s fail=%s\n' "$pass" "$fail"; [[ $fail -eq 0 ]]

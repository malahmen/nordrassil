#!/usr/bin/env bash
# items 3b (target banner) and 7 (dump charset, mode, stream guard).
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
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr() { printf '\n\033[36m== %s\033[0m\n' "$1"; }

newenv() {
    E="$T/env$RANDOM$RANDOM"; mkdir -p "$E/config" "$E/run"
    export STUB_ARGV_LOG="$E/argv.log" STUB_DUMP_MODE=good
    # tcp needs no probe and no container; the stubs stand in for the client.
    bash "$ENG" --profile meksha set DB_TRANSPORT tcp   >/dev/null
    bash "$ENG" --profile meksha set DB_HOST 192.168.3.52 >/dev/null
    bash "$ENG" --profile meksha set DB_PORT 3306       >/dev/null
    bash "$ENG" --profile meksha set DB_USER mangos     >/dev/null
    bash "$ENG" --profile meksha set DB_PASS 8charsec   >/dev/null
}
d()  { bash "$ENG" --profile meksha "$@" 2>&1; }

hdr "item 7 — dump: charset, mode, stream"
newenv
out="$(d dump --db mangos --no-gzip --out "$E/d.sql")"; rc=$?
chk "a good dump succeeds"                  '[[ $rc -eq 0 ]] && [[ -s "$E/d.sql" ]]'
chk "utf8mb4 is on the command line"        'grep -q -- "--default-character-set=utf8mb4" "$E/argv.log"'
chk "the dump file is 0600"                 '[[ "$(stat -c %a "$E/d.sql")" == 600 ]]'
chk "no .partial left behind"               '[[ ! -e "$E/d.sql.partial" ]]'

STUB_DUMP_MODE=chatty
out="$(d dump --db mangos --no-gzip --out "$E/c.sql")"; rc=$?
chk "a prefixed banner is refused"          '[[ $rc -ne 0 ]]'
chk "  and says what it saw"                'grep -q "Welcome to meksha" <<<"$out"'
chk "  and names the cause"                 'grep -q "does not start like a SQL dump" <<<"$out"'
chk "  and leaves nothing behind"           '[[ ! -e "$E/c.sql" && ! -e "$E/c.sql.partial" ]]'
out="$(d dump --db mangos --out "$E/g.sql.gz")"; rc=$?
chk "the gzip path checks it too"           '[[ $rc -ne 0 ]] && [[ ! -e "$E/g.sql.gz" ]]'

STUB_DUMP_MODE=good
chk "and a good dump still passes after"  'd dump --db mangos --no-gzip --out "$E/d2.sql" >/dev/null && head -1 "$E/d2.sql" | grep -q "MariaDB dump"'
STUB_DUMP_MODE=empty
out="$(d dump --db mangos --no-gzip --out "$E/e.sql")"; rc=$?
chk "an empty dump is still refused"         '[[ $rc -ne 0 ]] && [[ ! -e "$E/e.sql" ]]'

hdr "item 3b — the target banner"
newenv
out="$(d dump --db mangos --no-gzip --out "$E/b.sql")"
chk "dump names profile+transport+host"      'grep -qE "target: +meksha — tcp 192.168.3.52:3306, as mangos" <<<"$out"'
printf 'SELECT 1;\n' > "$E/x.sql"
out="$(d apply-sql --file "$E/x.sql" --db mangos --no-record)"
chk "apply-sql names it"                     'grep -q "target:   meksha — tcp 192.168.3.52:3306" <<<"$out"'
out="$(d restore --file "$E/b.sql" --db mangos --yes)"
chk "restore names it"                       'grep -q "target:   meksha — tcp 192.168.3.52:3306" <<<"$out"'
out="$(d restore --file "$E/b.sql" --db mangos)"; rc=$?
chk "restore without --yes names the profile" '[[ $rc -ne 0 ]] && grep -q "on meksha (tcp)" <<<"$out"'
chk "  and the banner came BEFORE the gate"  '[[ "$(grep -n "target:" <<<"$out" | cut -d: -f1)" -lt "$(grep -n "refusing without --yes" <<<"$out" | cut -d: -f1)" ]]'
# Pinned to the stub before this runs. Left on its default the base config
# resolved DB_TRANSPORT=auto, found the REAL local container and dumped 135 MB
# of live data into the temp tree. A test must not be able to reach a server.
bash "$ENG" --no-profile set DB_TRANSPORT tcp >/dev/null
bash "$ENG" --no-profile set DB_HOST 127.0.0.1 >/dev/null
bash "$ENG" --no-profile set DB_PASS 8charsec >/dev/null
out="$(bash "$ENG" --no-profile dump --db mangos --no-gzip --out "$E/n.sql" 2>&1)"; rc=$?
chk "base config says so by name"            'grep -q "<base config>" <<<"$out"'
# The ssh hop must be shown where it is used. A deliberately bogus host: the
# point is the printed line, and no real server may be touched by a test.
bash "$ENG" --profile meksha set DB_TRANSPORT podman >/dev/null
bash "$ENG" --profile meksha set DB_SSH_HOST nordrassil.invalid >/dev/null
out="$(d dump --db mangos --no-gzip --out "$E/s.sql" 2>&1)"; rc=$?
chk "ssh hop shown for a container transport" 'grep -q "podman container .* on nordrassil.invalid (ssh)" <<<"$out"'
chk "  and that run failed, not silently ok"  '[[ $rc -ne 0 ]] && [[ ! -e "$E/s.sql" ]]'

printf '\n\033[36m== totals\033[0m\n  pass=%s fail=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

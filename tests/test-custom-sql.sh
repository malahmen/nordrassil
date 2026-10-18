#!/usr/bin/env bash
# P1-7: the bootstrap's Custom selection and error handling, run the two ways
# it runs - by the engine, and by the k8s Job - which are now one script,
# lib/bootstrap.sh.
# shellcheck disable=SC2034
# The globals below and the `out`/`rc` captures are consumed by engine
# functions pulled in with source, and by the single-quoted assertions chk
# evaluates — neither of which shellcheck can see from here.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${NORDRASSIL:-${TEST_DIR}/../nordrassil.sh}"
[ -f "$ENG" ] || { echo "nordrassil.sh not found at $ENG" >&2; exit 1; }
R="$(dirname "$ENG")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The engine is nordrassil.sh and the lib/ files it sources: functions and
# source checks are read from all of them, in one file.
SRC="$T/engine-src.sh"; cat "$ENG" "$(dirname "$ENG")"/lib/*.sh > "$SRC" 2>/dev/null
# Stubs shadow the real clients and orchestrators: no test here may reach a
# database, a docker socket or a cluster.
export PATH="${TEST_DIR}/stubs:$PATH"
export XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T/run"
mkdir -p "$T/config" "$T/run"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- the engine
# _db_bootstrap runs lib/bootstrap.sh through the hooks in lib/db.sh. Both
# are loaded for real; only the transport under them (_db_exec,
# _db_query_raw, _db_import) is replaced, so what is under test is the
# bootstrap's logic and the engine's wiring of it.
mktree() {
  local r="$1"; mkdir -p "$r/sql/Base" "$r/sql/Custom" "$r/sql/Migrations"
  for f in logon world characters logs; do echo "-- $f" > "$r/sql/Base/$f.sql"; done
  echo "-- world" > "$r/sql/world_full_14_june_2021.sql"
  for n in GOOD BREAKS UNSELECTED UNREADABLE START_ON_GM_ISLAND; do echo "-- $n" > "$r/sql/Custom/$n.sql"; done
}
bootstrap() {   # bootstrap <CUSTOM_SQL> -> prints a call log
  local csql="$1" r; r="$(mktemp -d "$T/tree.XXXXXX")"; mktree "$r"
  (
    # shellcheck source=../lib/bootstrap.sh
    source "$R/lib/bootstrap.sh"
    # shellcheck source=../lib/db.sh
    source "$R/lib/db.sh"
    SOURCE_DIR="$r"; CUSTOM_SQL="$csql"
    REALM_ID=1 REALM_NAME=r REALM_ADDRESS=a WORLD_PORT=8085 CLIENT_BUILD=5875
    info(){ :; }; success(){ :; }; warn(){ printf 'warn: %s\n' "$*"; }
    error_exit(){ printf 'died: %s\n' "$*"; exit 1; }
    # The tracking table exists; TRACKED.sql is recorded, UNREADABLE.sql's
    # state cannot be read, nothing else is applied yet.
    _db_query_raw(){ case "$1" in
        *"SHOW TABLES FROM realmd LIKE 'nordrassil_applied'"*) echo nordrassil_applied ;;
        *"name='custom:TRACKED.sql'"*) echo 1 ;;
        *"name='custom:UNREADABLE.sql'"*) return 1 ;;
        esac; return 0; }
    # To stderr: bs_mark discards the client's stdout, as it should.
    _db_exec(){ case "$1" in
        "INSERT IGNORE INTO realmd.nordrassil_applied"*) printf 'mark %s\n' "$(sed -n "s/.*VALUES ('\(.*\)');/\1/p" <<<"$1")" >&2 ;;
        esac; return 0; }
    # BREAKS.sql fails to import; everything else succeeds.
    _db_import(){ case "$2" in *BREAKS.sql) printf 'import-FAILED %s\n' "$(basename "$2")"; return 1 ;; esac
                  printf 'import %s\n' "$(basename "$2")"; }
    _db_bootstrap
  ) 2>&1
}
hdr "P1-7 — the engine applies only what was selected, and marks only what worked"
log="$(bootstrap "GOOD,BREAKS")"
chk "the selected script is imported"        'grep -q "^import GOOD.sql" <<<"$log"'
chk "  and marked applied"                   'grep -q "^mark custom:GOOD.sql" <<<"$log"'
chk "a FAILED script is not marked"          'grep -q "import-FAILED BREAKS.sql" <<<"$log" && ! grep -q "mark custom:BREAKS.sql" <<<"$log"'
chk "  and says so"                          'grep -q "FAILED and was NOT recorded" <<<"$log"'
chk "an unselected script is left alone"     '! grep -qE "(import|mark).*UNSELECTED" <<<"$log"'
chk "START_ON_GM_ISLAND is never applied"    '! grep -q "START_ON_GM_ISLAND" <<<"$log"'
chk "Base goes first, the world dump is recorded" '[[ "$(grep -m1 "^import" <<<"$log")" == "import logon.sql" ]] && grep -q "^mark world-full" <<<"$log"'

hdr "P1-7 — 'cannot tell' skips rather than re-imports"
log2="$(bootstrap "UNREADABLE,GOOD")"
chk "the unreadable-state script is skipped" '! grep -qE "(import|mark).*UNREADABLE" <<<"$log2"'
chk "  and reported"                         'grep -q "Cannot tell whether UNREADABLE.sql" <<<"$log2"'
chk "the other script still applies"         'grep -q "^import GOOD.sql" <<<"$log2"'

# --------------------------------------------------------------- the k8s Job
# templates/k8s/db-init.sh with lib/bootstrap.sh next to it, as the
# ConfigMap mounts them, against a stand-in mariadb client.
hdr "P1-7 — the Job runs the same bootstrap and honours CUSTOM_SQL"
S="$T/job"; mkdir -p "$S/sql/Base" "$S/sql/Custom" "$S/sql/Migrations" "$S/bin" "$S/bootstrap"
for f in logon world characters logs; do echo "-- $f" > "$S/sql/Base/$f.sql"; done
for n in GOOD UNSELECTED START_ON_GM_ISLAND; do echo "-- $n" > "$S/sql/Custom/$n.sql"; done
echo "-- world dump" > "$S/sql/world_full_14_june_2021.sql"
cp "$R/lib/bootstrap.sh" "$R/templates/k8s/db-init.sh" "$S/bootstrap/"
cat > "$S/bin/mariadb" <<'STUB'
#!/usr/bin/env bash
q=""; prev=""; for a in "$@"; do [[ "$prev" == "-e" ]] && q="$a"; prev="$a"; done
printf 'mariadb pwd=%s args=%s\n' "${MYSQL_PWD:+set}" "$*" >> "$MLOG"
case "$q" in
  *"SHOW TABLES FROM realmd LIKE 'nordrassil_applied'"*) echo nordrassil_applied ;;
  *"SHOW TABLES"*) ;;
  *"SELECT 1 FROM realmd.nordrassil_applied"*) [[ "$STUB_APPLIED_FAILS" == 1 ]] && exit 1 ;;
esac
cat >/dev/null 2>&1 || true
exit 0
STUB
chmod +x "$S/bin/mariadb"
run_job() { MLOG="$S/m.log" STUB_APPLIED_FAILS="${2:-0}" CUSTOM_SQL="$1" DB_PASS=s3cret \
            REALM_ID=1 REALM_NAME=r REALM_ADDRESS=a WORLD_PORT=8085 CLIENT_BUILD=5875 \
            SQL_DIR="$S/sql" PATH="$S/bin:$PATH" bash "$S/bootstrap/db-init.sh" </dev/null 2>&1; }
: > "$S/m.log"; out="$(run_job "GOOD")" ; rc=$?
chk "the Job completes"                      '[[ $rc -eq 0 ]] && grep -q "DB bootstrap complete" <<<"$out"'
chk "it applies the selected script"         'grep -q "Applied: GOOD.sql" <<<"$out"'
chk "it does NOT apply an unselected one"    '! grep -q "UNSELECTED" <<<"$out"'
chk "it does NOT apply START_ON_GM_ISLAND"   '! grep -q "START_ON_GM_ISLAND" <<<"$out"'
chk "the password is in MYSQL_PWD, never argv" '[[ -s "$S/m.log" ]] && ! grep -q "s3cret" "$S/m.log" && ! grep -q "pwd= " "$S/m.log"'
out2="$(run_job "")"
chk "an empty CUSTOM_SQL applies none"       '! grep -q "Applied:" <<<"$out2"'
out3="$(run_job "NOSUCH")"
chk "a typo in the selection is reported"    'grep -q "Custom script not found, skipping: NOSUCH.sql" <<<"$out3"'
out4="$(run_job "GOOD" 1)"; rc4=$?
chk "a failed tracking query aborts the Job" '[[ $rc4 -ne 0 ]] && grep -q "FATAL: Could not read the import state" <<<"$out4"'

hdr "the Job is wired to that script"
chk "run-k8s ships bootstrap.sh and db-init.sh" 'grep -qF "from-file=bootstrap.sh=\"\${SCRIPT_DIR}/lib/bootstrap.sh\"" "$SRC" && grep -qF "from-file=db-init.sh=" "$SRC"'
chk "no second copy of the bootstrap in the manifest" '! grep -qE "CREATE (TABLE|DATABASE)|INSERT |mariadb -h" "$R/templates/k8s/db-init-job.yaml"'
# The manifest's own structure needs PyYAML; skipped where it is missing.
if python3 -c 'import yaml' 2>/dev/null; then
    wiring="$(python3 -c '
import yaml,sys,pathlib
d=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
p=d["spec"]["template"]["spec"]; c=p["containers"][0]
mounts={m["name"]:m["mountPath"] for m in c["volumeMounts"]}
cms={v["name"]:v["configMap"]["name"] for v in p["volumes"] if "configMap" in v}
print(" ".join(c["command"]), mounts.get("bootstrap"), cms.get("bootstrap"))
' "$R/templates/k8s/db-init-job.yaml")"
    chk "the Job runs /bootstrap/db-init.sh from the ConfigMap" '[[ "$wiring" == "bash /bootstrap/db-init.sh /bootstrap vanilla-wow-db-init" ]]'
else
    printf '  \033[33mSKIP\033[0m the manifest structure check (no PyYAML: pip install pyyaml)\n'
fi

printf '\n  pass=%s fail=%s\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

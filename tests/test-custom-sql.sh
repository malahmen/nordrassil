#!/usr/bin/env bash
# P1-7: the engine's Custom loop, and the k8s Job's selection + error handling.
# shellcheck disable=SC2034
# The globals below and the `out`/`rc` captures are consumed by engine
# functions pulled in with eval, and by the single-quoted assertions chk
# evaluates — neither of which shellcheck can see from here.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${NORDRASSIL:-${TEST_DIR}/../nordrassil.sh}"
[ -f "$ENG" ] || { echo "nordrassil.sh not found at $ENG" >&2; exit 1; }
R="$(dirname "$ENG")"
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
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------- the engine's Custom loop
# _db_bootstrap is run for real, with everything that reaches a database
# replaced by harness functions, so what is under test is the loop's logic.
mktree() {
  local r="$1"; mkdir -p "$r/sql/Base" "$r/sql/Custom" "$r/sql/Migrations"
  for f in logon world characters logs; do echo "-- $f" > "$r/sql/Base/$f.sql"; done
  echo "-- world" > "$r/sql/world_full_14_june_2021.sql"
  for n in GOOD BREAKS UNSELECTED UNREADABLE START_ON_GM_ISLAND; do echo "-- $n" > "$r/sql/Custom/$n.sql"; done
}
bootstrap() {   # bootstrap <CUSTOM_SQL> <engine-path>  -> prints a call log
  local csql="$1" eng="$2" r; r="$(mktemp -d "$T/tree.XXXXXX")"; mktree "$r"
  (
    eval "$(sed -n '/^_db_bootstrap() {/,/^}/p;/^_db_applied_or_die() {/,/^}/p' "$eng")"
    SOURCE_DIR="$r"; CUSTOM_SQL="$csql"
    info(){ :; }; success(){ :; }; warn(){ printf 'warn: %s\n' "$*"; }
    error_exit(){ printf 'died: %s\n' "$*"; exit 1; }
    _db_exec(){ :; }; _db_table_exists(){ return 0; }; _ensure_realmlist(){ :; }
    _db_seed_applied_from_markers(){ :; }
    # BREAKS.sql fails to import; everything else succeeds.
    _db_import(){ case "$2" in *BREAKS.sql) printf 'import-FAILED %s\n' "$(basename "$2")"; return 1 ;; esac
                  printf 'import %s\n' "$(basename "$2")"; }
    _db_mark_applied(){ printf 'mark %s\n' "$1"; }
    # Nothing is applied yet, except that TRACKED.sql is already recorded.
    _db_is_applied(){ case "$1" in
        custom:TRACKED.sql) return 0 ;;
        custom:UNREADABLE.sql) return 2 ;;
        *) return 1 ;; esac; }
    _db_bootstrap
  )
}
hdr "P1-7 — the engine applies only what was selected, and marks only what worked"
log="$(bootstrap "GOOD,BREAKS" "$ENG")"
chk "the selected script is imported"        'grep -q "^import GOOD.sql" <<<"$log"'
chk "  and marked applied"                   'grep -q "^mark custom:GOOD.sql" <<<"$log"'
chk "a FAILED script is not marked"          'grep -q "import-FAILED BREAKS.sql" <<<"$log" && ! grep -q "mark custom:BREAKS.sql" <<<"$log"'
chk "  and says so"                          'grep -q "FAILED and was NOT recorded" <<<"$log"'
chk "an unselected script is left alone"     '! grep -qE "(import|mark).*UNSELECTED" <<<"$log"'
chk "START_ON_GM_ISLAND is never applied"    '! grep -q "START_ON_GM_ISLAND" <<<"$log"'

hdr "P1-7 — 'cannot tell' skips rather than re-imports"
log2="$(bootstrap "UNREADABLE,GOOD" "$ENG")"
chk "the unreadable-state script is skipped" '! grep -qE "(import|mark).*UNREADABLE" <<<"$log2"'
chk "  and reported"                         'grep -q "Cannot tell whether UNREADABLE.sql" <<<"$log2"'
chk "the other script still applies"         'grep -q "^import GOOD.sql" <<<"$log2"'

# --------------------------------------------------------------- the k8s Job
hdr "P1-7 — the Job honours CUSTOM_SQL"
# The Job's script is extracted from the YAML, so this half needs PyYAML.
# Skipped rather than failed where it is missing: the engine half above is the
# part every machine can check.
if ! python3 -c 'import yaml' 2>/dev/null; then
    printf '  \033[33mSKIP\033[0m the k8s Job checks (no PyYAML: pip install pyyaml)\n'
    printf '\n  pass=%s fail=%s\n' "$pass" "$fail"
    [[ $fail -eq 0 ]]
    exit $?
fi
S="$T/job"; mkdir -p "$S/sql/Base" "$S/sql/Custom" "$S/sql/Migrations" "$S/bin"
for f in logon world characters logs; do echo "-- $f" > "$S/sql/Base/$f.sql"; done
for n in GOOD UNSELECTED START_ON_GM_ISLAND; do echo "-- $n" > "$S/sql/Custom/$n.sql"; done
echo "-- world dump" > "$S/sql/world_full_14_june_2021.sql"
python3 - "$S" "$R/templates/k8s/db-init-job.yaml" <<'PY'
import yaml,sys,pathlib
d=yaml.safe_load(pathlib.Path(sys.argv[2]).read_text())
s=d["spec"]["template"]["spec"]["containers"][0]["command"][2]
# /sql is a mount point in the cluster; point it at the fixture tree instead.
s=s.replace("/sql/", sys.argv[1]+"/sql/").replace('-d /sql', '-d '+sys.argv[1]+'/sql')
pathlib.Path(sys.argv[1]+"/job.sh").write_text(s)
PY
cat > "$S/bin/mariadb" <<'EOF'
#!/usr/bin/env bash
q=""; prev=""; for a in "$@"; do [[ "$prev" == "-e" ]] && q="$a"; prev="$a"; done
printf 'mariadb %s\n' "${q:-<stdin>}" >> "$MLOG"
case "$q" in
  *"SHOW TABLES FROM realmd LIKE 'nordrassil_applied'"*) echo nordrassil_applied ;;
  *"SHOW TABLES"*) ;;
  *"SELECT 1 FROM nordrassil_applied"*) [[ "$STUB_APPLIED_FAILS" == 1 ]] && exit 1 ;;
esac
exit 0
EOF
cat > "$S/bin/mariadb-admin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$S/bin"/*
run_job() { MLOG="$S/m.log" STUB_APPLIED_FAILS="${2:-0}" CUSTOM_SQL="$1" DB_PASS=p \
            REALM_ID=1 REALM_NAME=r REALM_ADDRESS=a WORLD_PORT=8085 CLIENT_BUILD=5875 \
            PATH="$S/bin:$PATH" bash "$S/job.sh" </dev/null 2>&1; }
: > "$S/m.log"; out="$(run_job "GOOD")" ; rc=$?
chk "the Job completes"                      '[[ $rc -eq 0 ]]'
chk "it applies the selected script"         'grep -q "Applying custom content: .*GOOD.sql" <<<"$out"'
chk "it does NOT apply an unselected one"    '! grep -q "UNSELECTED" <<<"$out"'
chk "it does NOT apply START_ON_GM_ISLAND"   '! grep -q "START_ON_GM_ISLAND" <<<"$out"'
out2="$(run_job "")"
chk "an empty CUSTOM_SQL applies none"       '! grep -q "Applying custom content" <<<"$out2"'
out3="$(run_job "NOSUCH")"
chk "a typo in the selection is reported"    'grep -q "custom script not found, skipping: NOSUCH.sql" <<<"$out3"'
out4="$(run_job "GOOD" 1)"; rc4=$?
chk "a failed tracking query aborts the Job" '[[ $rc4 -ne 0 ]] && grep -q "FATAL: could not read the import state" <<<"$out4"'

printf '\n  pass=%s fail=%s\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

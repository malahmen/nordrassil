#!/usr/bin/env bash
# N3 and P1-7, driven by eval'ing the real functions out of nordrassil.sh with
# the database and the orchestrators stubbed. Nothing here touches a server.
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
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }

# Pull named functions out of the engine without running it.
grab() { local f; for f in "$@"; do sed -n "/^${f}() {/,/^}/p" "$ENG"; done; }

# ---------------------------------------------------------------- N3: conf files
hdr "N3 — DB_PASS=ask must not reach a conf file"
(
  eval "$(grab _sed_escape _db_password _db_password_new _render_realmd_conf)"
  info(){ :; }; warn(){ printf 'WARN %s\n' "$*" >> "$T/warn.log"; }; success(){ :; }
  error_exit(){ printf 'ERR %s\n' "$*"; exit 1; }
  DB_HOST=192.168.3.52 DB_PORT=3306 DB_USER=root DB_PASS=ask PROFILE=meksha
  REALM_PORT=3724 WRONG_PASS_MAX_COUNT=0 WRONG_PASS_BAN_TIME=0 WRONG_PASS_BAN_TYPE=0
  REQ_EMAIL_VERIFICATION=0 STRICT_VERSION_CHECK=1
  export XDG_RUNTIME_DIR="$T/run"; install -d -m 0700 "$T/run/nordrassil"
  printf '%s' 'Xpto123!' > "$T/run/nordrassil/meksha.dbpass"   # as if already prompted
  printf 'LogsDir = ""\nLoginDatabaseInfo = "x"\nRealmServerPort = 1\n' > "$T/realmd.conf.dist"
  _render_realmd_conf "$T/realmd.conf.dist" "$T/realmd.conf" "/logs"
) || echo "(render returned non-zero)"
chk "the resolved password is in the conf"   'grep -q "root;Xpto123!;realmd" "$T/realmd.conf"'
chk "the literal 'ask' is NOT"               '! grep -q ";ask;" "$T/realmd.conf"'
# _db_password_new tested directly, and the assertion is able to fail: the
# earlier version of this check ended in '|| true; true'.
pwnew() {
  (
    eval "$(grab _db_password _db_password_new)"
    warn(){ printf 'WARN %s\n' "$*" >&2; }
    DB_PASS="$1" PROFILE=meksha
    export XDG_RUNTIME_DIR="$T/run"
    _db_password_new
  ) 2>"$T/pwnew.err"
}
chk "ask: returns the resolved password"      '[[ "$(pwnew ask)" == "Xpto123!" ]]'
chk "ask: warns that it is being SET"         'grep -q "being SET on a database being created" "$T/pwnew.err"'
chk "ask: names the cache file"               'grep -q "meksha.dbpass" "$T/pwnew.err"'
chk "a stored password returns as-is"         '[[ "$(pwnew "8charsec")" == "8charsec" ]]'
chk "  and warns about nothing"               '[[ ! -s "$T/pwnew.err" ]]'

# ---------------------------------------------------------- P1-7(3): three states
hdr "P1-7 — a query error is not 'not applied'"
state() {  # state <stub-behaviour> -> prints the rc of _db_is_applied
  (
    eval "$(grab _sql_escape _db_is_applied _db_applied_or_die)"
    warn(){ :; }; error_exit(){ printf 'DIED\n'; exit 9; }
    case "$1" in
      hit)   _db_query_raw(){ echo 1; } ;;
      miss)  _db_query_raw(){ :; } ;;
      error) _db_query_raw(){ return 1; } ;;
    esac
    _db_is_applied x; echo "rc=$?"
  )
}
chk "a row found  -> 0 (applied)"            '[[ "$(state hit)"   == "rc=0" ]]'
chk "no row       -> 1 (not applied)"        '[[ "$(state miss)"  == "rc=1" ]]'
chk "query failed -> 2 (cannot tell)"        '[[ "$(state error)" == "rc=2" ]]'
die() {
  (
    eval "$(grab _sql_escape _db_is_applied _db_applied_or_die)"
    warn(){ :; }; error_exit(){ printf 'DIED'; exit 9; }
    case "$1" in miss) _db_query_raw(){ :; } ;; error) _db_query_raw(){ return 1; } ;; esac
    _db_applied_or_die x && echo APPLIED || echo "NOT(rc=$?)"
  )
}
chk "_db_applied_or_die aborts on an error"  '[[ "$(die error)" == DIED* ]]'
chk "  and still reports a plain miss"       '[[ "$(die miss)"  == "NOT(rc=1)" ]]'
printf '\n  pass=%s fail=%s\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

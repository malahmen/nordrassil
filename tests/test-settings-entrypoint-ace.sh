#!/usr/bin/env bash
# Kamino items 46, 47 and 49. Each guard is checked both ways (it fires, and
# a good value still passes), and the entrypoint and the ACE download are also
# run as they were before the fix, to show the bug was real.
# shellcheck disable=SC2034
# `out`/`rc` and the ACE globals are read by the single-quoted assertions chk
# evaluates, and by engine functions pulled in with eval.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${NORDRASSIL:-${TEST_DIR}/../nordrassil.sh}"
ENTRY="${TEST_DIR}/../templates/entrypoint.sh"
[ -f "$ENG" ] || { echo "nordrassil.sh not found at $ENG" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The engine is nordrassil.sh and the lib/ files it sources: functions and
# source checks are read from all of them, in one file.
SRC="$T/engine-src.sh"; cat "$ENG" "$(dirname "$ENG")"/lib/*.sh > "$SRC" 2>/dev/null
export PATH="${TEST_DIR}/stubs:$PATH"
export XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T/run"
mkdir -p "$T/config" "$T/run"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr()  { printf '\n\033[36m== %s\033[0m\n' "$1"; }
# grab <file> <fn...> — pull named functions out of a script without running it.
grab() { local file="$1" f; shift; for f in "$@"; do sed -n "/^${f}() {/,/^}/p" "$file"; done; }
run()  { bash "$ENG" "$@" 2>&1; }
# The version before the fix (fd422c6, main before #23), for the "was it
# broken before?" runs. Skipped when that commit is not there to read (a
# tarball, a shallow clone).
BEFORE=fd422c6
old() { git -C "$TEST_DIR/.." show "${BEFORE}:$1" 2>/dev/null; }

# ---------------------------------------------------------------- item 47
hdr "item 47 — numeric settings are checked on the way in"
for kv in "XP_RATE abc" "XP_RATE 1;" "DROP_RATE -1" "WORLD_PORT 70000" "REALM_PORT 0" \
          "REALM_ID 1)" "PLAYER_LIMIT -4" "WARDEN_ENABLED 2" "STRICT_PLAYER_NAMES 4" "CLIENT_BUILD 5875x"; do
    # shellcheck disable=SC2086
    out="$(run set $kv)"; rc=$?
    chk "set ${kv} refused"                    '[[ $rc -ne 0 ]] && grep -q "must be" <<<"$out"'
done
chk "  and none of it was stored"              '! grep -qE "^(XP_RATE|DROP_RATE|WORLD_PORT|REALM_PORT|REALM_ID|PLAYER_LIMIT|WARDEN_ENABLED|STRICT_PLAYER_NAMES|CLIENT_BUILD)=" "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf" 2>/dev/null'
for kv in "XP_RATE 1.5" "DROP_RATE 2" "WORLD_PORT 8085" "REALM_PORT 65535" "PLAYER_LIMIT -3" \
          "PLAYER_LIMIT 0" "STRICT_PLAYER_NAMES 3" "WARDEN_ENABLED 0" "GAME_TYPE 16" "WOW_PATCH 10"; do
    # shellcheck disable=SC2086
    out="$(run set $kv)"; rc=$?
    chk "set ${kv} accepted"                   '[[ $rc -eq 0 ]]'
done
out="$(run set REALM_NAME 'Not a number')"; rc=$?
chk "a text setting is not checked as one"     '[[ $rc -eq 0 ]]'

hdr "item 47 — a bad value already in the file"
printf 'XP_RATE="1; DROP"\n' >> "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"
out="$(run status)"; rc=$?
chk "a command that uses it refuses"           '[[ $rc -ne 0 ]] && grep -q "XP_RATE=.1; DROP. is not a number" <<<"$out"'
chk "  and says how to fix it"                 'grep -q "set KEY VALUE" <<<"$out"'
out="$(run get XP_RATE)"; rc=$?
chk "get still answers"                        '[[ $rc -eq 0 && "$out" == "1; DROP" ]]'
out="$(run config)"; rc=$?
chk "config still answers"                     '[[ $rc -eq 0 ]]'
out="$(run set XP_RATE 2)"; rc=$?
chk "set can repair it"                        '[[ $rc -eq 0 ]]'
out="$(run status)"
chk "  after which status no longer refuses"   '! grep -q "is not a number" <<<"$out"'

# ---------------------------------------------------------------- item 46
# The entrypoint with its absolute paths moved under $T, and stand-in
# servers: realmd exits with a chosen status, mangosd records SIGTERM.
entry_run() {   # entry_run <script> <realmd status> [term] -> sets rc, D
    D="$T/e$RANDOM$RANDOM"; mkdir -p "$D/app/bin" "$D/app/etc"
    : > "$D/app/etc/mangosd.conf"; : > "$D/app/etc/realmd.conf"
    printf '#!/usr/bin/env bash\nsleep 0.3; exit %s\n' "$2" > "$D/app/bin/realmd"
    [[ "${3:-}" == term ]] && printf '#!/usr/bin/env bash\nsleep 30\n' > "$D/app/bin/realmd"
    cat > "$D/app/bin/mangosd" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$D/mangosd.pid"
trap 'echo term > "$D/mangosd.term"; exit 0' TERM
while :; do sleep 0.1; done
EOF
    chmod +x "$D/app/bin/realmd" "$D/app/bin/mangosd"
    sed -e "s|/app|$D/app|g" -e "s|/out|$D/out|g" -e 's|sleep infinity|sleep 5|' "$1" > "$D/entry.sh"
    if [[ "${3:-}" == term ]]; then
        bash "$D/entry.sh" > "$D/log" 2>&1 & local p=$!
        sleep 0.5; kill -TERM "$p"; wait "$p"; rc=$?
    else
        timeout 10 bash "$D/entry.sh" > "$D/log" 2>&1; rc=$?
    fi
    sleep 0.3   # mangosd's trap runs between its sleeps
    # A survivor the old script left behind: stop it, so the test leaves nothing.
    [[ -f "$D/mangosd.pid" ]] && kill "$(cat "$D/mangosd.pid")" 2>/dev/null
    return 0
}

hdr "item 46 — entrypoint: realmd dies non-zero"
entry_run "$ENTRY" 3
chk "exits with realmd's status"               '[[ $rc -eq 3 ]]'
chk "  after running _shutdown"                'grep -q "Shutting down" "$D/log"'
chk "  which stopped mangosd"                  '[[ -f "$D/mangosd.term" ]]'
entry_run "$ENTRY" 0
chk "a clean exit still shuts down (control)"  '[[ $rc -eq 0 && -f "$D/mangosd.term" ]]'
entry_run "$ENTRY" 0 term
chk "SIGTERM stops both, exit 0"               '[[ $rc -eq 0 && -f "$D/mangosd.term" ]]'
if old templates/entrypoint.sh > "$T/entry-old.sh"; then
    entry_run "$T/entry-old.sh" 3
    chk "before the fix: _shutdown was skipped"       '[[ $rc -eq 3 ]] && ! grep -q "Shutting down" "$D/log" && [[ ! -f "$D/mangosd.term" ]]'
fi

# ---------------------------------------------------------------- item 49
hdr "item 49 — the ACE tarball is checked before it is unpacked"
chk "the pinned digest is 8.0.7's"             'grep -q "^ACE_BUILD_SHA256=\"017fa5c7499e3c8f98921f86e007cda7c41c14a926447abbe5a7c5e7960480c7\"" "$SRC"'
# A tarball shaped like ACE's, curl that hands it over, make that "builds".
mkdir -p "$T/src/ACE_wrappers/ace" "$T/src/ACE_wrappers/include/makeinclude" "$T/bin"
: > "$T/src/ACE_wrappers/ace/ACE.h"
tar -czf "$T/ace.tar.gz" -C "$T/src" ACE_wrappers
GOOD_SHA="$(sha256sum "$T/ace.tar.gz" | cut -d' ' -f1)"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do [[ "\$1" == -o ]] && { cp "$T/ace.tar.gz" "\$2"; exit 0; }; shift; done; exit 1
EOF
cat > "$T/bin/make" <<EOF
#!/usr/bin/env bash
echo ran > "$T/make.ran"; mkdir -p ../lib; : > ../lib/libACE.so
EOF
chmod +x "$T/bin/curl" "$T/bin/make"

ace_run() {   # ace_run <engine file> <sha to pin> -> sets rc, out
    rm -rf "$T/cache" "$T/make.ran"
    out="$(
        PATH="$T/bin:$PATH"
        info() { echo "[info] $*" >&2; }; warn() { echo "[warn] $*" >&2; }; success() { echo "[ok] $*" >&2; }
        ACE_BUILD_VERSION=8.0.7 ACE_BUILD_SHA256="$2"
        ACE_DEPS_DIR="$T/cache/ace-wrappers/8.0.7/ACE_wrappers"
        eval "$(grab "$1" _build_ace_from_source)"
        _build_ace_from_source 2>&1
    )"; rc=$?
}
ace_run "$SRC" "$(printf '0%.0s' {1..64})"
chk "a mismatch is refused"                    '[[ $rc -ne 0 ]] && grep -q "does not match its pinned sha256" <<<"$out"'
chk "  nothing was unpacked"                   '[[ ! -e "$T/cache/ace-wrappers/8.0.7/ACE_wrappers" ]]'
chk "  nothing was built"                      '[[ ! -f "$T/make.ran" ]]'
chk "  the download was removed"               '[[ ! -f "$T/cache/ace-wrappers/8.0.7/ACE-8.0.7.tar.gz" ]]'
ace_run "$SRC" "$GOOD_SHA"
chk "a match builds (control)"                 '[[ $rc -eq 0 && -f "$T/cache/ace-wrappers/8.0.7/ACE_wrappers/lib/libACE.so" ]]'
if old nordrassil.sh > "$T/eng-old.sh"; then
    ace_run "$T/eng-old.sh" "$(printf '0%.0s' {1..64})"
    chk "before the fix: any tarball was built"       '[[ $rc -eq 0 && -f "$T/make.ran" ]]'
fi

echo
echo "pass=${pass} fail=${fail}"
(( fail == 0 ))

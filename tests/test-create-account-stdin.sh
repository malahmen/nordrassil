#!/usr/bin/env bash
# Kamino 233: create-account takes the password on stdin (--pass-stdin), and
# on no --where path does it end up in the argv of any command — not this
# script's, not docker's, kubectl's or ssh's. --pass keeps working; giving
# both is refused.
#
# The whole script is run, with docker, podman, kubectl and ssh replaced by
# recorders: each logs its argv (one line per call) and whatever it was fed on
# stdin, which is where the console line is meant to travel.
# shellcheck disable=SC2034
# The `out`/`rc` captures are consumed by the single-quoted assertions chk
# evaluates, which shellcheck cannot see from here.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${NORDRASSIL:-${TEST_DIR}/../nordrassil.sh}"
[ -f "$ENG" ] || { echo "nordrassil.sh not found at $ENG" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T/run"
mkdir -p "$T/config" "$T/run" "$T/rec"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }

# --- recorders. ARGV gets every call's argv; STDIN gets what each call read.
ARGV="$T/argv.log" STDIN="$T/stdin.log"
# The orchestrators are fakes: they log, answer _kube_pick_pod, and swallow
# what an exec (or ssh) is fed, which is the console line.
for tool in docker podman kubectl ssh; do
    cat > "$T/rec/$tool" <<EOF
#!/bin/sh
printf '%s' "$tool" >> "$ARGV"; for a in "\$@"; do printf ' %s' "\$a" >> "$ARGV"; done; echo >> "$ARGV"
case "$tool \$*" in
    *get*pods*) echo "wow-server-0 " ;;    # _kube_pick_pod, here or over ssh
    ssh*|*exec*) $(command -v cat) >> "$STDIN" ;;
esac
exit 0
EOF
    chmod +x "$T/rec/$tool"
done
# The usual ways a line could be handed to a helper instead of written by a
# builtin are logged too, then passed to the real command: a password given
# to 'sh -c', 'env', 'printf' or 'tee' as an argument lands in its argv just
# the same. (Only commands found through PATH can be seen this way.)
for tool in sh env printf echo tee cat dd; do
    real="$(type -P "$tool")" || continue
    cat > "$T/rec/$tool" <<EOF
#!/bin/sh
printf '%s' "$tool" >> "$ARGV"; for a in "\$@"; do printf ' %s' "\$a" >> "$ARGV"; done; echo >> "$ARGV"
exec "$real" "\$@"
EOF
    chmod +x "$T/rec/$tool"
done
# Recorders first, then the repo's stubs for anything else: no test here may
# reach a real container engine, cluster or host.
export PATH="$T/rec:${TEST_DIR}/stubs:$PATH"

set_p(){ local prof="$1"; shift; while [[ $# -gt 0 ]]; do bash "$ENG" --profile "$prof" set "$1" "$2" >/dev/null 2>&1; shift 2; done; }
set_p dock   SERVER_TRANSPORT docker
set_p dockr  SERVER_TRANSPORT docker  SERVER_SSH_HOST meksha
set_p kube   SERVER_TRANSPORT kubectl K8S_NAMESPACE azeroth
set_p kuber  SERVER_TRANSPORT kubectl K8S_NAMESPACE azeroth SERVER_SSH_HOST meksha
set_p loc    SERVER_TRANSPORT local

PW='S3cr3t!pw#9'

# The local console is a FIFO under INSTALL_DIR; a background reader stands
# in for mangosd. Killed afterwards in case nothing was ever written.
FIFO="$T/config/nordrassil/install/bin/mangosd.stdin"
mkdir -p "$(dirname "$FIFO")"

# run <profile> <where> <stdin text or -> <args...>: one create-account. Prints
# the output; rc in $T/rc. stdin '-' means /dev/null.
run() {
    local prof="$1" where="$2" in="$3"; shift 3
    : > "$ARGV"; : > "$STDIN"
    local reader=""
    if [[ "$prof" == loc ]]; then
        rm -f "$FIFO"; mkfifo "$FIFO"
        command -p cat "$FIFO" >> "$STDIN" & reader=$!
    fi
    local o rc
    if [[ "$in" == - ]]; then
        o="$(bash "$ENG" --profile "$prof" create-account --where "$where" "$@" </dev/null 2>&1)"; rc=$?
    else
        o="$(printf '%s' "$in" | bash "$ENG" --profile "$prof" create-account --where "$where" "$@" 2>&1)"; rc=$?
    fi
    if [[ -n "$reader" ]]; then
        # Let the reader drain what was written, then make sure it is gone.
        local i; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$reader" 2>/dev/null || break; sleep 0.1; done
        kill "$reader" 2>/dev/null; wait "$reader" 2>/dev/null
    fi
    echo "$rc" > "$T/rc"
    printf '%s\n' "$o" | sed 's/\x1b\[[0-9;]*m//g'
}
rc(){ cat "$T/rc"; }

for p in loc:local dock:docker dockr:docker kube:k8s kuber:k8s; do
    prof="${p%%:*}" where="${p#*:}"
    case "$prof" in
        loc)   label="local (FIFO)" ;;
        dock)  label="docker exec" ;;
        dockr) label="docker exec over ssh" ;;
        kube)  label="kubectl exec" ;;
        kuber) label="kubectl exec over ssh" ;;
    esac
    hdr "--where ${where}: ${label}"

    out="$(run "$prof" "$where" "${PW}"$'\n'"trailing junk"$'\n' --name bob --pass-stdin)"
    chk "--pass-stdin is accepted"                    '[[ "$(rc)" == 0 ]]'
    chk "  the console got 'account create bob <pw>'" 'grep -qxF "account create bob ${PW}" "$STDIN"'
    chk "  only the first line of stdin was used"     '! grep -q "trailing junk" "$STDIN"'
    if [[ "$prof" == loc ]]; then
        chk "  and no orchestrator was run"           '! grep -qE "^(docker|podman|kubectl|ssh) " "$ARGV"'
    else
        chk "  through a recorded command"            '[[ -s "$ARGV" ]]'
    fi
    # Conjoined with delivery, so an engine that never sends the line cannot
    # pass this by sending nothing at all.
    chk "  delivered, and the password is in no recorded argv" \
        'grep -qxF "account create bob ${PW}" "$STDIN" && ! grep -qF "$PW" "$ARGV"'
    chk "  nor in the output"                         '! grep -qF "$PW" <<<"$out"'

    out="$(run "$prof" "$where" "$PW"$'\n' --name bob --pass "$PW" --pass-stdin)"
    chk "--pass with --pass-stdin is refused"         '[[ "$(rc)" != 0 ]] && grep -q "mutually exclusive" <<<"$out"'
    chk "  before anything is sent"                   '[[ ! -s "$STDIN" ]] && ! grep -qE "^(docker|podman|kubectl|ssh) " "$ARGV"'
    out="$(run "$prof" "$where" "$PW"$'\n' --name bob --pass-stdin --pass "$PW")"
    chk "  in either order"                           '[[ "$(rc)" != 0 ]] && grep -q "mutually exclusive" <<<"$out"'

    out="$(run "$prof" "$where" - --name bob --pass "$PW")"
    chk "--pass still works (back-compat)"            '[[ "$(rc)" == 0 ]] && grep -qxF "account create bob ${PW}" "$STDIN"'
    chk "  and travels on stdin from there on, too"   '! grep -qF "$PW" "$ARGV"'
done

# Reading and validation happen before any transport is involved, so they are
# checked once, on the docker path, rather than five times over.
hdr "reading and validation (path-independent)"
prof=dock where=docker
out="$(run "$prof" "$where" "$PW" --name bob --pass-stdin)"
chk "a last line with no newline still counts"    '[[ "$(rc)" == 0 ]] && grep -qxF "account create bob ${PW}" "$STDIN"'
# The same gate as --pass: 1-16 printable, no whitespace.
out="$(run "$prof" "$where" 'two words'$'\n' --name bob --pass-stdin)"
chk "a password with a space is refused"          '[[ "$(rc)" != 0 ]] && grep -q -- "--pass-stdin must be 1-16" <<<"$out" && [[ ! -s "$STDIN" ]]'
out="$(run "$prof" "$where" '12345678901234567'$'\n' --name bob --pass-stdin)"
chk "17 characters are refused"                   '[[ "$(rc)" != 0 ]] && grep -q -- "--pass-stdin must be 1-16" <<<"$out" && [[ ! -s "$STDIN" ]]'
out="$(run "$prof" "$where" '1234567890123456'$'\n' --name bob --pass-stdin)"
chk "16 are accepted"                             '[[ "$(rc)" == 0 ]]'
out="$(run "$prof" "$where" - --name bob --pass-stdin)"
chk "empty stdin is refused"                      '[[ "$(rc)" != 0 && ! -s "$STDIN" ]] && grep -q "pass-stdin read nothing" <<<"$out"'

hdr "usage"
u="$(bash "$ENG" --help 2>&1)"
chk "shows --pass-stdin"                     'grep -q "create-account --name N --pass-stdin" <<<"$u"'
chk "says --pass is visible in ps"           'grep -q "visible in .ps." <<<"$u"'

printf '\n  pass=%s fail=%s\n' "$pass" "$fail"; [[ $fail -eq 0 ]]

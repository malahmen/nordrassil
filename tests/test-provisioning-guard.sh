#!/usr/bin/env bash
# R1: provisioning must refuse a target this machine does not own. docker and
# kubectl are shadowed with hard failures so no test can reach a real one.
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
set_p(){ local prof="$1"; shift; while [[ $# -gt 0 ]]; do bash "$ENG" --profile "$prof" set "$1" "$2" >/dev/null 2>&1; shift 2; done; }
runp(){ local prof="$1"; shift; bash "$ENG" --profile "$prof" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
runb(){ bash "$ENG" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

set_p remote SERVER_SSH_HOST meksha SERVER_TRANSPORT kubectl K8S_NAMESPACE azeroth
set_p dbremote DB_SSH_HOST meksha DB_TRANSPORT podman
set_p ambient SERVER_TRANSPORT kubectl K8S_NAMESPACE azeroth
set_p tcpfar DB_TRANSPORT tcp DB_HOST 192.168.3.52
set_p tcpnear DB_TRANSPORT tcp DB_HOST 127.0.0.1
set_p managed SERVER_SSH_HOST meksha MANAGED_EXTERNALLY 1

hdr "a profile that points elsewhere is refused"
for cmd in run-k8s run-docker configure build-image stop-k8s stop-docker start stop edit; do
    out="$(runp remote $cmd)"
    chk "$cmd refused" 'grep -q "Refusing to run .'"$cmd"'. locally" <<<"$out"'
done
out="$(runp remote run-k8s)"
chk "  the reason names SERVER_SSH_HOST"   'grep -q "SERVER_SSH_HOST=meksha" <<<"$out"'
chk "  and points at what still works"     'grep -q "apply-sql, dump, restore, restart, status" <<<"$out"'
out="$(runp dbremote configure)"
chk "DB_SSH_HOST alone is enough"          'grep -q "DB_SSH_HOST=meksha" <<<"$out"'
out="$(runp tcpfar run-docker)"
chk "a non-local DB_HOST is enough"        'grep -q "DB_TRANSPORT=tcp to 192.168.3.52" <<<"$out"'
out="$(runp ambient run-k8s)"
chk "kubectl with no --context is enough"  'grep -q "no --context/--kind" <<<"$out"'

hdr "what must NOT be refused"
out="$(runp ambient --kind local run-k8s)"
chk "--kind keeps the local kind workflow" '! grep -q "Refusing to run" <<<"$out"'
out="$(runp ambient --context mine run-k8s)"
chk "--context is trusted"                 '! grep -q "Refusing to run" <<<"$out"'
out="$(runp tcpnear run-docker)"
chk "a loopback DB_HOST is local"          '! grep -q "Refusing to run" <<<"$out"'
out="$(runb run-docker)"
chk "the base config is not refused"       '! grep -q "Refusing to run" <<<"$out"'
out="$(runp remote status)"
chk "status still runs"                    '! grep -q "Refusing to run" <<<"$out"'
out="$(runp remote dump --db mangos)"
chk "dump still runs"                      '! grep -q "Refusing to run" <<<"$out"'

hdr "ordering and visibility"
out="$(runp managed run-k8s)"
chk "MANAGED_EXTERNALLY is reported first" 'grep -q "externally managed" <<<"$out" && ! grep -q "points elsewhere" <<<"$out"'
out="$(runp ambient --kind local run-k8s)"
chk "the kube context is announced"        'grep -q "kube context: kind-local (--kind)" <<<"$out"'
chk "  with the namespace"                 'grep -q "namespace: azeroth" <<<"$out"'
out="$(runb --context some-eks run-k8s)"
chk "an explicit context is named"         'grep -q "kube context: some-eks (--context)" <<<"$out"'

# A real assertion, not '|| true': the base config is NOT refused, so it
# proceeds and reaches docker — which must be the shadowing stub, proving no
# test here can touch the real one.
outb="$(runb run-docker)"
# The stub exits 97 and the script swallows docker's stderr, so the proof is
# the script's own verdict: with the real docker (which IS running on this
# host) it would have proceeded instead of reporting the daemon unreachable.
chk "an unrefused run hits the stub docker"  'grep -q "docker daemon not reachable" <<<"$outb"'
chk "  so no real docker was reachable"      '! grep -qi "docker run\|container started" <<<"$outb"'

printf '\n  pass=%s fail=%s\n' "$pass" "$fail"; [[ $fail -eq 0 ]]

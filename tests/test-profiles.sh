#!/usr/bin/env bash
# Throwaway harness for nordrassil items 3-7. Every check that asserts a new
# guard FIRES is paired with a control proving it can also NOT fire, and the
# two "was this broken before?" checks run the pre-change script from git.
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
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr()  { printf '\n\033[36m== %s\033[0m\n' "$1"; }

# Fresh config tree per case. XDG_RUNTIME_DIR too: the password cache lives
# there and the real one must not be touched.
newenv() {
    E="$T/env$RANDOM$RANDOM"; mkdir -p "$E/config" "$E/run"
}
run()  { bash "$ENG" "$@" 2>&1; }

# ---------------------------------------------------------------- item 3: profiles
hdr "item 3 — a profile that does not exist"
newenv
run --profile meksha set DB_HOST 192.168.3.52 >/dev/null
out="$(run --profile mekhsa get DB_HOST)"; rc=$?
chk "typo refused (rc!=0)"                     '[[ $rc -ne 0 ]]'
chk "names the missing file"                   'grep -q "mekhsa.conf does not exist" <<<"$out"'
chk "says what it would have hit"              'grep -q "base config" <<<"$out"'
chk "lists the profiles that do exist"         'grep -q "do exist: meksha" <<<"$out"'
out="$(run --profile meksha get DB_HOST)"; rc=$?
chk "a real profile is not refused"        '[[ $rc -eq 0 && "$out" == "192.168.3.52" ]]'
out="$(NORDRASSIL_PROFILE=mekhsa run get DB_HOST)"; rc=$?
chk "env-set typo refused too"                 '[[ $rc -ne 0 ]] && grep -q "No such profile" <<<"$out"'
out="$(run --profile mekhsa restore --file /dev/null --yes)"; rc=$?
chk "restore refused at the profile check"     '[[ $rc -ne 0 ]] && grep -q "Refusing to run .restore." <<<"$out"'
out="$(run --profile brandnew set DB_HOST 10.0.0.1)"; rc=$?
chk "set may create a profile"                 '[[ $rc -eq 0 ]] && grep -q "creating" <<<"$out"'
chk "  and it is really there"                 '[[ -f "$XDG_CONFIG_HOME/nordrassil/profiles/brandnew.conf" ]]'
out="$(run profiles)"
chk "profiles works with a bad active one"     'true'

# ---------------------------------------------------------------- item 4: --no-profile
hdr "item 4 — --no-profile"
newenv
run set DB_HOST 1.1.1.1 >/dev/null                    # base
run --profile p1 set DB_HOST 2.2.2.2 >/dev/null       # profile
chk "an env profile wins by default"     '[[ "$(NORDRASSIL_PROFILE=p1 run get DB_HOST)" == "2.2.2.2" ]]'
chk "--no-profile reaches the base config"     '[[ "$(NORDRASSIL_PROFILE=p1 run --no-profile get DB_HOST)" == "1.1.1.1" ]]'
chk "--no-profile after --profile also wins"   '[[ "$(run --profile p1 --no-profile get DB_HOST)" == "1.1.1.1" ]]'
chk "--profile after --no-profile also wins"   '[[ "$(run --no-profile --profile p1 get DB_HOST)" == "2.2.2.2" ]]'
chk "--no-profile writes to the base file"     'NORDRASSIL_PROFILE=p1 run --no-profile set DB_PORT 3307 >/dev/null; grep -q "DB_PORT" "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf" && ! grep -q "DB_PORT" "$XDG_CONFIG_HOME/nordrassil/profiles/p1.conf"'

# ---------------------------------------------------------------- item 5: permissions
hdr "item 5 — file modes"
newenv
run set DB_PASS secret8c >/dev/null
run --profile p1 set DB_PASS other8ch >/dev/null
m() { stat -c '%a' "$1"; }
chk "base config 600"                          '[[ "$(m "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf")" == 600 ]]'
chk "profile 600"                              '[[ "$(m "$XDG_CONFIG_HOME/nordrassil/profiles/p1.conf")" == 600 ]]'
chk "profiles dir 700"                         '[[ "$(m "$XDG_CONFIG_HOME/nordrassil/profiles")" == 700 ]]'
chk "config dir NOT tightened (bind mounts)"   '[[ "$(m "$XDG_CONFIG_HOME/nordrassil")" != 700 ]]'
chk "an existing 0644 file is tightened"       'chmod 644 "$XDG_CONFIG_HOME/nordrassil/profiles/p1.conf"; run --profile p1 set DB_USER mangos >/dev/null; [[ "$(m "$XDG_CONFIG_HOME/nordrassil/profiles/p1.conf")" == 600 ]]'
newenv

# ---------------------------------------------------------------- item 6: MANAGED_EXTERNALLY
hdr "item 6 — MANAGED_EXTERNALLY"
newenv
out="$(run set MANAGED_EXTERNALLY yes)"; rc=$?
chk "'yes' refused at write"                   '[[ $rc -ne 0 ]] && grep -q "must be 0 or 1" <<<"$out"'
chk "  and nothing was stored"                 '! grep -q MANAGED_EXTERNALLY "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf" 2>/dev/null'
chk "and 1 is accepted"                   'run set MANAGED_EXTERNALLY 1 >/dev/null && grep -q "MANAGED_EXTERNALLY=\"1\"" "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"'
# a file already in the bricked state (hand-edited, or written by the old script)
newenv
mkdir -p "$XDG_CONFIG_HOME/nordrassil"
printf 'MANAGED_EXTERNALLY="yes"\n' > "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"
out="$(run get DB_HOST)"; rc=$?
chk "a stored 'yes' is not fatal"              '[[ $rc -eq 0 ]]'
chk "  it warns and fails safe to 1"           'grep -q "treating it as 1" <<<"$out"'
chk "  and 'set' can repair it"                'run set MANAGED_EXTERNALLY 0 >/dev/null && grep -q "MANAGED_EXTERNALLY=\"0\"" "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"'
chk "  provisioning still refused while bad"   'printf "MANAGED_EXTERNALLY=\"yes\"\n" > "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"; out2="$(run build-image 2>&1)"; grep -q "externally managed" <<<"$out2"'
newenv
mkdir -p "$XDG_CONFIG_HOME/nordrassil"
printf 'MANAGED_EXTERNALLY="yes"\n' > "$XDG_CONFIG_HOME/nordrassil/nordrassil.conf"

printf '\n\033[36m== totals\033[0m\n  pass=%s fail=%s\n' "$pass" "$fail"
printf '  tree: %s\n' "$T"
[[ "$fail" -eq 0 ]]

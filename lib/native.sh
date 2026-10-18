# shellcheck shell=bash
# lib/native.sh — The native build on this host: install-deps and ACE, the source and
# its patches, cmake, start and stop.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

# Pinned release for the from-source ACE build (dnf/rpm-ostree hosts — no
# native package exists). Bump deliberately, not casually: VMaNGOS's
# FindACE.cmake has no version floor/ceiling of its own, so an untested newer
# ACE could silently drop an API this codebase still uses.
ACE_BUILD_VERSION="8.0.7"
# The release tarball's sha256, checked before anything is extracted - bump it
# with the version. GitHub publishes it as the asset's digest:
#   curl -s https://api.github.com/repos/DOCGroup/ACE_TAO/releases/tags/ACE%2BTAO-<ver_us> | grep -A1 '"name": "ACE-<ver>.tar.gz"'
# (8.0.7's also matched the md5 in the release's ACE-8.0.7.tar.gz.md5.)
ACE_BUILD_SHA256="017fa5c7499e3c8f98921f86e007cda7c41c14a926447abbe5a7c5e7960480c7"
# Shared across projects/repos on this machine, NOT under CONFIG_DIR — ACE
# itself has nothing project-specific about it, so every fork/port of this
# script (this one included — ported from vanilla-wow-server) reuses the same
# from-source build instead of paying the multi-minute compile again just
# because CONFIG_DIR's name changed. Versioned in the path since
# _build_ace_from_source only checks for the built files' existence, not
# their version — a bump to ACE_BUILD_VERSION must land in a new directory,
# not silently reuse a stale build under the old one.
ACE_DEPS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ace-wrappers/${ACE_BUILD_VERSION}/ACE_wrappers"

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

# _resolve_ace_root — echoes a usable ACE_ROOT and returns 0, checking (in
# priority order): an already-exported ACE_ROOT, the Debian/Ubuntu package
# location, then the from-source build this script maintains under
# ACE_DEPS_DIR (see _build_ace_from_source). Echoes nothing and returns 1 if
# none are usable. No install/messaging side effects, so both install-deps
# (_ensure_ace) and the build itself (_build_native) can check without
# duplicating the lookup.
_resolve_ace_root() {
    [[ -n "${ACE_ROOT:-}" && -f "${ACE_ROOT}/ace/ACE.h" ]] && { echo "$ACE_ROOT"; return 0; }
    [[ -f /usr/include/ace/ACE.h ]] && { echo "/usr/include/ace"; return 0; }
    [[ -f "${ACE_DEPS_DIR}/ace/ACE.h" ]] && { echo "$ACE_DEPS_DIR"; return 0; }
    return 1
}

_ace_present() { _resolve_ace_root &>/dev/null; }

# _build_ace_from_source — builds ACE via its own classic Linux GNU
# makefiles (the same mechanism the official ACE-INSTALL docs describe),
# in place under ACE_DEPS_DIR — no 'make install', nothing touches the
# system outside this directory. FindACE.cmake only needs ACE_ROOT pointed at it
# (it checks "$ACE_ROOT/ace/ACE.h" for the header and "$ACE_ROOT/lib" for
# the library), which _resolve_ace_root wires up automatically once this
# has run once. Verified against this project's actual FindACE.cmake and a
# real cmake configure — ACE 8.0.7 is found and linked with no changes
# needed on the VMaNGOS side (cmake auto-bumps to C++17 for it).
_build_ace_from_source() {
    [[ -f "${ACE_DEPS_DIR}/ace/ACE.h" && -f "${ACE_DEPS_DIR}/lib/libACE.so" ]] \
        && { info "ACE ${ACE_BUILD_VERSION} already built at ${ACE_DEPS_DIR}."; return 0; }

    info "No ACE package available for this distro — building ACE ${ACE_BUILD_VERSION} from source instead (one-time, a few minutes)."

    local ver_us="${ACE_BUILD_VERSION//./_}"
    local url="https://github.com/DOCGroup/ACE_TAO/releases/download/ACE%2BTAO-${ver_us}/ACE-${ACE_BUILD_VERSION}.tar.gz"
    local deps_dir; deps_dir="$(dirname "$ACE_DEPS_DIR")"
    local tarball="${deps_dir}/ACE-${ACE_BUILD_VERSION}.tar.gz"

    mkdir -p "$deps_dir"
    rm -rf "$ACE_DEPS_DIR"

    info "Downloading ACE ${ACE_BUILD_VERSION}..."
        curl -fsSL -o "$tarball" "$url" \
        || { warn "Failed to download ACE source from ${url}."; return 1; }

    # Before tar: the build runs make in what this unpacks.
    local got; got="$(sha256sum "$tarball" | cut -d' ' -f1)"
    if [[ "$got" != "$ACE_BUILD_SHA256" ]]; then
        rm -f "$tarball"
        warn "ACE ${ACE_BUILD_VERSION} download does not match its pinned sha256 - not extracting it."
        warn "  expected ${ACE_BUILD_SHA256}"
        warn "  got      ${got}"
        return 1
    fi

    info "Extracting ACE..."
        tar -xzf "$tarball" -C "$deps_dir" \
        || { warn "Failed to extract ACE tarball."; return 1; }
    rm -f "$tarball"

    echo '#include "ace/config-linux.h"' > "${ACE_DEPS_DIR}/ace/config.h"
    echo 'include $(ACE_ROOT)/include/makeinclude/platform_linux.GNU' \
        > "${ACE_DEPS_DIR}/include/makeinclude/platform_macros.GNU"

    local jobs; jobs="$(nproc 2>/dev/null || echo 2)"
    info "Building ACE (make -j${jobs})..."
        bash -c "cd '${ACE_DEPS_DIR}/ace' && ACE_ROOT='${ACE_DEPS_DIR}' make -j${jobs}" \
        || { warn "ACE build failed. See output above."; return 1; }

    [[ -f "${ACE_DEPS_DIR}/lib/libACE.so" ]] \
        || { warn "ACE build finished but libACE.so wasn't produced — something went wrong."; return 1; }
    success "ACE ${ACE_BUILD_VERSION} built at ${ACE_DEPS_DIR}."
}

_ensure_ace() {
    _ace_present && { info "ACE toolkit found."; return 0; }

    local pm; pm="$(_pkg_manager)"
    if [[ "$pm" == "apt" ]]; then
        _require_sudo_or_instruct "Installing libace-dev" "sudo apt-get update -qq && sudo apt-get install -y libace-dev"
        sudo apt-get update -qq && sudo apt-get install -y libace-dev \
            && { success "libace-dev installed."; return 0; }
        warn "libace-dev install failed — falling back to building ACE from source."
    fi

    _build_ace_from_source && return 0

    warn "Could not get a working ACE toolkit (a hard build dependency for local native builds) on ${pm:-this distro}."
    warn "The Docker path (build-image/run-docker/run-k8s) doesn't need it at all — it always builds inside an"
    warn "Ubuntu stage regardless of host OS. Use that instead if this keeps failing."
    return 1
}

cmd_install_deps() {
    header "nordrassil — Install dependencies"

    info "Build toolchain (for the local native path)..."
    # git: _apply_source_patches (git apply); make: the cmake build and the
    # ACE from-source build; unzip: _unpack_source; curl/tar: the ACE download.
    _ensure_pkg git    git    git
    _ensure_pkg cmake  cmake  cmake
    _ensure_pkg g++    gcc-c++ g++
    _ensure_pkg make   make   make
    _ensure_pkg unzip  unzip  unzip
    _ensure_pkg curl   curl   curl
    _ensure_pkg tar    tar    tar
    _ensure_pkgs "tbb-devel mariadb-devel openssl-devel zlib-ng-compat-devel" \
                 "libtbb-dev default-libmysqlclient-dev libssl-dev zlib1g-dev"
    _layer_rpm_ostree_pending
    if [[ ${#RPM_OSTREE_PENDING[@]} -gt 0 ]]; then
        # The toolchain just layered isn't usable until the reboot, so the
        # ACE from-source build would only fail here — deferred to the re-run.
        warn "Skipping the ACE check until after the reboot."
    else
        _ensure_ace || true
    fi

    info "Docker (required for the DB container and the Docker/k8s deployment paths)..."
    _check_docker

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# start / stop — native local build (cmake+make, cached) for fast iteration
# -----------------------------------------------------------------------------

_unpack_source() {
    if [[ ! -f "${SRC_UNPACK_DIR}/CMakeLists.txt" ]]; then
        local zip="${SOURCE_DIR}/source/Repack 25 Source.zip"
        [[ -f "$zip" ]] || error_exit "Source zip not found: ${zip}"
        mkdir -p "$SRC_UNPACK_DIR"
        info "Unpacking VMaNGOS source (one-time)..."
        info "Unzipping source..."
            unzip -q -o "$zip" -d "$SRC_UNPACK_DIR" \
            || error_exit "Failed to unpack ${zip}"
    fi

    _apply_source_patches
}

# _apply_source_patches — scomp-link-maintained fixes to the repack's own
# source, layered on top of the pristine unzip. Two so far:
#   strict-player-names-gate-reserved-check.patch — gates the DBC-based
#     profanity/reserved-name check (ValidateName, in ObjectMgr.cpp's
#     CheckPlayerName) behind StrictPlayerNames, the same setting that
#     already gates the character-set check right next to it — found live,
#     with StrictPlayerNames=0 that check still ran unconditionally on every
#     login, permanently blocking any character whose name matched an entry
#     in the client's NamesReserved.dbc/NamesProfanity.dbc (Blizzard's own
#     original content filter), with no config toggle to turn it off —
#     before this fix existed, working around it meant binary-editing the
#     DBC file itself.
#   remove-dead-ace-auto-ptr-include.patch — drops two `#include
#     <ace/Auto_Ptr.h>` lines (MangosSocketImpl.h, realmd/PatchHandler.h)
#     that don't reference anything from it (verified: no ACE_Auto_Ptr/
#     Auto_Basic_Ptr/Auto_Array_Ptr symbol appears in either file). ACE
#     dropped that header in its 8.x line — it only ever wrapped
#     std::auto_ptr, itself removed in C++17 — which is what a from-source
#     ACE build on Fedora/RHEL resolves to (see _build_ace_from_source);
#     without this patch the local native build fails on those hosts with
#     "ace/Auto_Ptr.h: No such file or directory".
# Idempotent via a marker per patch, independent of whether the unzip step
# above actually ran this time — a source tree unpacked before a given fix
# existed (already has CMakeLists.txt, skips the unzip) still gets that
# patch applied on its next build.
_apply_source_patches() {
    local patch_dir="${TEMPLATES_DIR}/patches"
    [[ -d "$patch_dir" ]] || return 0

    local patch_file pname marker_dir="${SRC_UNPACK_DIR}/.scomp-link-patches-applied"
    mkdir -p "$marker_dir"
    for patch_file in "$patch_dir"/*.patch; do
        [[ -f "$patch_file" ]] || continue
        pname="$(basename "$patch_file")"
        [[ -f "${marker_dir}/${pname}" ]] && continue

        info "Applying source patch: ${pname}"
        (cd "$SRC_UNPACK_DIR" && git apply --check "$patch_file") \
            || error_exit "Patch doesn't apply cleanly: ${pname} — the repack source may have changed, or it's already partially applied outside this marker."
        (cd "$SRC_UNPACK_DIR" && git apply "$patch_file") \
            || error_exit "Failed to apply patch: ${pname}"
        touch "${marker_dir}/${pname}"
    done
}

_build_native() {
    local ace_root
    ace_root="$(_resolve_ace_root)" \
        || error_exit "ACE toolkit not found — required for the local native build. Run 'install-deps' first (it installs the package on apt-based distros, or builds ACE from source otherwise)."
    export ACE_ROOT="$ace_root"
    export TBB_ROOT_DIR="${TBB_ROOT_DIR:-/usr/include/tbb}"

    _unpack_source
    mkdir -p "$BUILD_DIR"

    info "Configuring (cmake, client build ${CLIENT_BUILD})..."
    info "cmake configure..."
        cmake -S "$SRC_UNPACK_DIR" -B "$BUILD_DIR" \
            -DDEBUG=0 -DUSE_EXTRACTORS=0 \
            -DSUPPORTED_CLIENT_BUILD="${CLIENT_BUILD}" \
            -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        || error_exit "cmake configure failed. See output above."

    local jobs; jobs="$(nproc 2>/dev/null || echo 2)"
    info "Building (make -j${jobs}) — first build compiles ~1600 files, this takes a while..."
    info "Building mangosd/realmd..."
        bash -c "make -C '${BUILD_DIR}' -j${jobs} && make -C '${BUILD_DIR}' install" \
        || error_exit "Build failed. Re-run with 'make -C ${BUILD_DIR}' to see full compiler output."

    success "Built and installed to ${INSTALL_DIR}."
}

# mangosd/realmd both run an interactive console reader on stdin. A
# backgrounded process inherits this shell's stdin, which under a
# nohup/non-interactive invocation delivers an immediate EOF — the console
# reads that as an implicit quit, so the server fully starts and then shuts
# itself down seconds later. Each one therefore gets its own FIFO with a
# small detached 'sleep infinity' holding the write end open, so stdin never
# reaches EOF for as long as the server is meant to run (the container path
# hits the same issue — solved there with 'docker run -i' / pod stdin: true).
# mangosd's FIFO doubles as its console channel (create-account & friends
# write to it); realmd's exists purely to hold stdin open.
#
# The holder PID is recorded so 'stop' can kill it. It used to be an
# anonymous '< <(sleep infinity)' process substitution for realmd, which
# nothing tracked and nothing ever killed: every 'start' left another
# orphaned 'sleep infinity' behind, surviving 'stop' and the shell itself.
#
# _start_stdin_holder <fifo> <holder-pidfile>
_start_stdin_holder() {
    local fifo="$1" holder_pf="$2"
    rm -f "$fifo"
    mkfifo "$fifo" || error_exit "Could not create the stdin FIFO: ${fifo}"
    # exec 9<>fifo: open both ends (never blocks, never sees EOF), then
    # become 'sleep infinity' so $! is the PID that actually holds it open.
    ( exec 9<>"$fifo"; exec sleep infinity ) &
    echo "$!" > "$holder_pf"
}

# _stop_stdin_holder <fifo> <holder-pidfile>
_stop_stdin_holder() {
    local fifo="$1" holder_pf="$2"
    if [[ -f "$holder_pf" ]]; then
        kill "$(cat "$holder_pf")" 2>/dev/null || true
        rm -f "$holder_pf"
    fi
    rm -f "$fifo"
}

cmd_start() {
    header "nordrassil — Start (local)"
    _settings
    _require_owned_target start

    [[ -f "${ETC_DIR}/mangosd.conf" ]] || error_exit "Not configured yet — run 'configure' first."
    _ensure_local_mariadb

    if [[ ! -x "${INSTALL_DIR}/bin/mangosd" || ! -x "${INSTALL_DIR}/bin/realmd" ]]; then
        _build_native
    else
        info "Using existing build at ${INSTALL_DIR} (delete it to force a rebuild)."
    fi

    # Both binaries have their config path compiled in at build time as an
    # absolute path under CMAKE_INSTALL_PREFIX/etc (confirmed via `strings
    # install/bin/{mangosd,realmd} | grep .conf` — e.g.
    # ".../install/etc/mangosd.conf"), not the cwd they're launched from or
    # their own bin/ directory. Copying there instead of bin/ is required —
    # not a style choice.
    mkdir -p "${INSTALL_DIR}/logs" "${INSTALL_DIR}/etc"
    cp -f "${ETC_DIR}/mangosd.conf" "${INSTALL_DIR}/etc/mangosd.conf"
    cp -f "${ETC_DIR}/realmd.conf"  "${INSTALL_DIR}/etc/realmd.conf"

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"
    local realmd_fifo="${INSTALL_DIR}/bin/realmd.stdin" mangosd_fifo="${INSTALL_DIR}/bin/mangosd.stdin"

    # Both servers get a tracked FIFO + holder — see _start_stdin_holder.
    if pf_is_running "$realmd_pf"; then
        warn "realmd already running (pid file present)."
    else
        _start_stdin_holder "$realmd_fifo" "${PF_DIR}/realmd-stdin-holder.pid"
        (cd "${INSTALL_DIR}/bin" && nohup ./realmd >> "${INSTALL_DIR}/logs/realmd.out" 2>&1 < "$realmd_fifo" &
         echo "$!:${REALM_PORT}" > "$realmd_pf")
        sleep 1
        pf_is_running "$realmd_pf" && success "realmd started (port ${REALM_PORT})." || warn "realmd did not start — check ${INSTALL_DIR}/logs/realmd.out"
    fi

    if pf_is_running "$mangosd_pf"; then
        warn "mangosd already running (pid file present)."
    else
        # mangosd's FIFO is also its console channel: 'create-account' &
        # friends write command lines into it (see _send_console_cmd).
        # Unlike the container path (where entrypoint.sh's own long-lived
        # PID 1 holds the write end open for free), this command returns
        # right after backgrounding mangosd, so without the holder the FIFO
        # would report EOF on mangosd's next read.
        _start_stdin_holder "$mangosd_fifo" "${PF_DIR}/mangosd-stdin-holder.pid"

        (cd "${INSTALL_DIR}/bin" && nohup ./mangosd >> "${INSTALL_DIR}/logs/mangosd.out" 2>&1 < "$mangosd_fifo" &
         echo "$!:${WORLD_PORT}" > "$mangosd_pf")
        sleep 1
        pf_is_running "$mangosd_pf" && success "mangosd started (port ${WORLD_PORT})." || warn "mangosd did not start — check ${INSTALL_DIR}/logs/mangosd.out"
    fi

    info "Logs: ${INSTALL_DIR}/logs/{realmd,mangosd}.out"
}

cmd_stop() {
    header "nordrassil — Stop (local)"
    _settings
    _require_owned_target stop

    local realmd_pf="${PF_DIR}/realmd.pid" mangosd_pf="${PF_DIR}/mangosd.pid"

    if pf_is_running "$mangosd_pf"; then pf_stop "$mangosd_pf"; else info "mangosd not running."; fi
    if pf_is_running "$realmd_pf";  then pf_stop "$realmd_pf";  else info "realmd not running.";  fi

    # The companion 'sleep infinity' holders that kept each server's stdin
    # FIFO open (see 'start') — both are killed here, and both FIFOs removed,
    # once the servers themselves are stopped. realmd's used to be an
    # untracked process substitution that 'stop' had no way to reach.
    _stop_stdin_holder "${INSTALL_DIR}/bin/mangosd.stdin" "${PF_DIR}/mangosd-stdin-holder.pid"
    _stop_stdin_holder "${INSTALL_DIR}/bin/realmd.stdin"  "${PF_DIR}/realmd-stdin-holder.pid"
}

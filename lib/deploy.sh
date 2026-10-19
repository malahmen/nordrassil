# shellcheck shell=bash
# lib/deploy.sh — Container deployments: build-image, run-docker / stop-docker, and
# run-k8s / stop-k8s with the templates they render.
#
# Part of nordrassil.sh, which sources it; not meant to run on its own.

# -----------------------------------------------------------------------------
# build-image — multi-stage Dockerfile, builder compiles inside Ubuntu
# regardless of host OS, runtime stage is slim.
# -----------------------------------------------------------------------------

cmd_build_image() {
    header "nordrassil — Build Docker image"
    _settings
    _require_owned_target build-image
    _check_docker

    [[ -d "$SOURCE_DIR" ]] || error_exit "SOURCE_DIR not set or missing — run 'configure' first."
    _unpack_source

    info "Preparing build context..."
    rm -rf "$IMAGE_BUILD_CONTEXT"
    mkdir -p "$IMAGE_BUILD_CONTEXT"
    cp -r "$SRC_UNPACK_DIR" "${IMAGE_BUILD_CONTEXT}/src"
    cp "${TEMPLATES_DIR}/Dockerfile"    "${IMAGE_BUILD_CONTEXT}/Dockerfile"
    cp "${TEMPLATES_DIR}/entrypoint.sh" "${IMAGE_BUILD_CONTEXT}/entrypoint.sh"

    # Warden anti-cheat modules — small and static like the binaries, baked
    # into the image (see the Dockerfile's own note). Without them, Warden
    # still runs (it's enabled by default in the repack's stock conf) but
    # has nothing to actually scan with, which surfaces as players getting
    # kicked for "Client response timeout" during normal play, not just a
    # log warning at startup. Not every repack/fork ships this directory,
    # so an empty one here is a soft warning, not a hard failure.
    if [[ -d "${SOURCE_DIR}/warden_modules" ]]; then
        cp -r "${SOURCE_DIR}/warden_modules" "${IMAGE_BUILD_CONTEXT}/warden_modules"
    else
        warn "No warden_modules/ found under SOURCE_DIR — Warden anti-cheat will run with no modules loaded, which can kick players unexpectedly. Building an empty directory instead."
        mkdir -p "${IMAGE_BUILD_CONTEXT}/warden_modules"
    fi

    info "Building image '${IMAGE_TAG}' (client build ${CLIENT_BUILD})..."
    docker build \
        --build-arg "SUPPORTED_CLIENT_BUILD=${CLIENT_BUILD}" \
        -t "$IMAGE_TAG" \
        "$IMAGE_BUILD_CONTEXT" \
        || error_exit "docker build failed. See compiler output above."

    success "Image built: ${IMAGE_TAG}"
}

# -----------------------------------------------------------------------------
# run-docker — LAN-exposed via host networking; server reaches the DB via
# 127.0.0.1 on the published MariaDB port (host networking bypasses Docker's
# embedded DNS, so container-name resolution isn't available here).
# -----------------------------------------------------------------------------

cmd_run_docker() {
    header "nordrassil — Run (Docker, LAN)"
    _settings
    _require_owned_target run-docker
    _check_docker

    local force=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --force) force=1; shift ;;
        *) error_exit "run-docker: unknown flag: $1" ;;
    esac; done

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first."
    _ensure_local_mariadb
    _db_bootstrap

    # --type container avoids docker inspect's fallback-to-image lookup —
    # without it, "vanilla-wow-server" (no tag) ambiguously matches the
    # "vanilla-wow-server:latest" image too, since they share a base name.
    if docker inspect --type container "$SERVER_CONTAINER_NAME" &>/dev/null; then
        [[ "$force" -eq 1 ]] || error_exit "Container '${SERVER_CONTAINER_NAME}' already exists. Re-run with --force to remove and recreate it."
        docker rm -f "$SERVER_CONTAINER_NAME" &>/dev/null || true
    fi

    # /app/bin/warden_modules — baked into the image at build time (see
    # cmd_build_image/Dockerfile), mangosd's cwd is /app/bin at runtime.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.docker.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.docker.conf"  "/app/logs"

    # :Z (private SELinux relabel) is required on Fedora/RHEL hosts with
    # SELinux enforcing — without it the container's unprivileged user gets
    # "Permission denied" reading these bind mounts, since host files default
    # to a context (e.g. config_home_t) containers aren't allowed to read.
    # First run relabels the whole data/ tree (3.2GB, one-time cost).
    # -i keeps stdin open (even detached) — mangosd/realmd run an interactive
    # console reader on stdin, and without it Docker delivers an immediate
    # EOF, which the console reads as an implicit quit: the server would
    # otherwise fully start (DB connected, world initialized, ports bound)
    # and then shut itself down cleanly seconds later.
    info "Starting server container (host networking — realm ${REALM_PORT}, world ${WORLD_PORT})..."
    docker run -d -i \
        --name "$SERVER_CONTAINER_NAME" \
        --network host \
        -v "${SOURCE_DIR}/data:/app/data:ro,Z" \
        -v "${ETC_DIR}/mangosd.docker.conf:/app/etc/mangosd.conf:ro,Z" \
        -v "${ETC_DIR}/realmd.docker.conf:/app/etc/realmd.conf:ro,Z" \
        --restart unless-stopped \
        "$IMAGE_TAG" \
        || error_exit "Failed to start container '${SERVER_CONTAINER_NAME}'."

    success "Server running: realm port ${REALM_PORT}, world port ${WORLD_PORT} (host network — reachable on your LAN IP)."
    info "Logs: docker logs -f ${SERVER_CONTAINER_NAME}"
}

# Stops the server container only — never the DB container, and never
# `docker rm`/the Docker daemon itself (same "stop the server, leave
# everything else alone" contract as cmd_stop for the local path). The
# container has --restart unless-stopped (set in cmd_run_docker), which
# specifically means "restart automatically after a daemon/host restart,
# unless a human stopped it" — so a plain 'docker stop' here is exactly
# enough to keep it down; no need to touch the restart policy.
cmd_stop_docker() {
    header "nordrassil — Stop (Docker)"
    _settings
    _require_owned_target stop-docker

    docker inspect --type container "$SERVER_CONTAINER_NAME" &>/dev/null \
        || { info "Container '${SERVER_CONTAINER_NAME}' not found — nothing to stop."; return; }

    [[ "$(docker inspect --type container "$SERVER_CONTAINER_NAME" --format='{{.State.Status}}' 2>/dev/null)" == "running" ]] \
        || { info "Container '${SERVER_CONTAINER_NAME}' is not running."; return; }

    docker stop "$SERVER_CONTAINER_NAME" &>/dev/null \
        && success "Container '${SERVER_CONTAINER_NAME}' stopped (Docker itself keeps running)." \
        || error_exit "Failed to stop container '${SERVER_CONTAINER_NAME}'."
    info "Container kept, not removed — resume it with: docker start ${SERVER_CONTAINER_NAME} (re-running 'run-docker' instead will remove and recreate it fresh)."
}

# -----------------------------------------------------------------------------
# run-k8s — hostNetwork so the fixed client-expected ports work without a
# LoadBalancer controller. Target comes from the global --context/--kind flags;
# storage backend (hostPath vs StorageClass) and paths come from config.
# -----------------------------------------------------------------------------

# Escapes a value for embedding inside a double-quoted YAML scalar
# ("__TOKEN__" in the templates): backslash first, then the quote itself.
_yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# render_template <template-file> <token1=value1> [...]
# Single-line token substitution only — do not pass multi-line values (sed
# can't do that safely). Use inject_block below for multi-line content.
render_template() {
    local tpl="$1"; shift
    local content; content="$(cat "$tpl")"
    local pair token value escaped
    for pair in "$@"; do
        token="${pair%%=*}"
        value="${pair#*=}"
        escaped="$(_sed_escape "$value")"
        content="$(printf '%s' "$content" | sed "s|__${token}__|${escaped}|g")"
    done
    printf '%s\n' "$content"
}

# inject_block <template-file> <token> <replacement-file>
# Splices the full multi-line content of <replacement-file> in place of a
# line that is exactly "__<token>__" — for content sed's single-line 's'
# command can't hold (e.g. the hostPath-vs-PVC volume source block, whose
# line count varies). Same pattern dozzle.sh uses for the same reason.
inject_block() {
    local tpl="$1" token="$2" block_file="$3"
    # Matches on the trimmed line so an indented "          __TOKEN__"
    # placeholder (kept indented in the template for YAML readability) still
    # matches — unlike a bare $0 == token check, which only fires on an
    # unindented, column-0 placeholder.
    awk -v token="__${token}__" '
        { trimmed = $0; sub(/^[ \t]+/, "", trimmed) }
        trimmed == token { while ((getline line < block_file) > 0) print line; next }
        { print }
    ' block_file="$block_file" "$tpl"
}

cmd_run_k8s() {
    header "nordrassil — Run (Kubernetes, LAN via hostNetwork)"
    _settings
    _require_owned_target run-k8s
    _announce_kube_target

    # Storage backend, namespace and realm address come from config (set them
    # with 'set K8S_STORAGE_TYPE hostpath|storageclass', 'set K8S_DATA_HOSTPATH',
    # 'set K8S_DB_HOSTPATH', 'set K8S_STORAGECLASS'); --namespace/--address are
    # one-shot overrides that also persist. The kube target is the global
    # --context/--kind (see kubectl_context_flag).
    local namespace="" address=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --namespace) namespace="$2"; shift 2 ;;
        --address)   address="$2"; shift 2 ;;
        *) error_exit "run-k8s: unknown flag: $1" ;;
    esac; done

    docker image inspect "$IMAGE_TAG" &>/dev/null || error_exit "Image '${IMAGE_TAG}' not built — run 'build-image' first (kind: also 'kind load docker-image')."

    # Target: --kind <name> ⇒ a kind cluster (context kind-<name>, and the
    # image is side-loaded with 'kind load'); --context <name> ⇒ a plain k8s
    # context; neither ⇒ the current kube context.
    local target_type target_context
    if [[ -n "$KIND_CLUSTER" ]]; then
        target_type="kind"; target_context="$KIND_CLUSTER"
    else
        target_type="k8s";  target_context="$KUBE_CONTEXT"
    fi

    [[ -n "$namespace" ]] && K8S_NAMESPACE="$namespace"
    cfg_set K8S_NAMESPACE "$K8S_NAMESPACE"

    [[ -n "$address" ]] && REALM_ADDRESS="$address"
    cfg_set REALM_ADDRESS "$REALM_ADDRESS"

    [[ "$K8S_STORAGE_TYPE" == "storageclass" ]] && \
        warn "StorageClass-backed game data still needs the 3.2GB data/ directory copied into the PVC once — this script does not automate that copy (no assumptions about how the target cluster reaches this host's filesystem). hostPath is the zero-copy option for a single-node cluster."

    if [[ "$target_type" == "kind" ]]; then
        info "kind target — loading image into the cluster (kind can't pull local-only images)..."
        info "kind load docker-image..."
            kind load docker-image "$IMAGE_TAG" --name "$target_context" \
            || error_exit "kind load docker-image failed."
    fi

    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    local k8s_tpl="${TEMPLATES_DIR}/k8s"
    local manifest; manifest="$(mktemp /tmp/vanilla-wow-k8s-XXXXXX.yaml)"
    local storage_type; storage_type="$K8S_STORAGE_TYPE"
    local data_source_file db_source_file job_manifest
    data_source_file="$(mktemp /tmp/vanilla-wow-data-src-XXXXXX)"
    db_source_file="$(mktemp /tmp/vanilla-wow-db-src-XXXXXX)"
    job_manifest="$(mktemp /tmp/vanilla-wow-db-init-XXXXXX.yaml)"
    # One trap for all four temp files — a second trap on the same signal
    # would silently replace the first rather than adding to it. EXIT, not
    # RETURN: error_exit's 'exit 1' never runs a RETURN trap, which used to
    # leave the rendered manifests (the DB password among them) in /tmp.
    # All four are mktemp-created, i.e. 0600.
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}' '${data_source_file}' '${db_source_file}' '${job_manifest}'" EXIT

    # inject_block splices these lines in VERBATIM (no reindentation) in place
    # of the "__DATA_SOURCE__"/"__DB_SOURCE__" placeholder line in the
    # templates below — the indentation here (10 spaces for the key, 12 for
    # its children) must match where that placeholder sits: nested under
    # spec.template.spec.volumes[].<key>, both templates use the same depth.
    if [[ "$storage_type" == "hostpath" ]]; then
        printf '          hostPath:\n            path: %s\n            type: Directory\n' \
            "$K8S_DATA_HOSTPATH" > "$data_source_file"
        printf '          hostPath:\n            path: %s\n            type: DirectoryOrCreate\n' \
            "$K8S_DB_HOSTPATH" > "$db_source_file"
    else
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-data\n' > "$data_source_file"
        printf '          persistentVolumeClaim:\n            claimName: vanilla-wow-db\n' > "$db_source_file"
        warn "StorageClass path selected — remember to copy game data into the vanilla-wow-data PVC before the server pod will start cleanly."
    fi

    render_template "${k8s_tpl}/namespace.yaml" "NAMESPACE=${K8S_NAMESPACE}" > "$manifest"

    # DB root password as a Secret (referenced via secretKeyRef by mariadb.yaml
    # and db-init-job.yaml below) — right after the namespace so it exists
    # before anything that mounts it. base64 output is [A-Za-z0-9+/=] only,
    # so it needs no YAML quoting and is safe for render_template's sed.
    # Resolved, not $DB_PASS: the Secret used to carry base64("ask").
    local db_pass_new; db_pass_new="$(_db_password_new)" || return 1
    local db_pass_b64; db_pass_b64="$(printf '%s' "$db_pass_new" | base64 | tr -d '\n')"
    echo "---" >> "$manifest"
    render_template "${k8s_tpl}/db-secret.yaml" "NAMESPACE=${K8S_NAMESPACE}" "DB_PASS_B64=${db_pass_b64}" >> "$manifest"

    if [[ "$storage_type" != "hostpath" ]]; then
        local sc; sc="$K8S_STORAGECLASS"
        local sc_line=""
        [[ -n "$sc" ]] && sc_line="  storageClassName: ${sc}"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-data" "SIZE=5Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
        echo "---" >> "$manifest"
        render_template "${k8s_tpl}/pvc.yaml" \
            "NAMESPACE=${K8S_NAMESPACE}" "NAME=vanilla-wow-db" "SIZE=10Gi" "STORAGECLASS_LINE=${sc_line}" >> "$manifest"
    fi

    echo "---" >> "$manifest"
    inject_block "${k8s_tpl}/mariadb.yaml" "DB_SOURCE" "$db_source_file" \
        | render_template /dev/stdin "NAMESPACE=${K8S_NAMESPACE}" >> "$manifest"

    # server.yaml is deliberately NOT part of this manifest — it's applied
    # last, after the db-init Job has completed (see below). entrypoint.sh
    # has no DB-wait of its own, so a server pod started alongside the Job
    # crash-loops for the whole world-dump import on a first deploy.
    info "Applying manifests (namespace, storage, mariadb)..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "$manifest" || error_exit "kubectl apply failed."

    # ConfigMap for the server's conf files, DB host pointed at the in-cluster
    # mariadb Service (hostNetworked pods can still reach ClusterIP services;
    # DNS resolution for that needs dnsPolicy: ClusterFirstWithHostNet, set in
    # server.yaml). --from-file avoids hand-escaping a 3000+ line conf file
    # as an inline YAML string.
    local saved_db_host="$DB_HOST"
    DB_HOST="mariadb.${K8S_NAMESPACE}.svc.cluster.local"
    # /app/bin/warden_modules — same image as run-docker, same baked-in path.
    _render_mangosd_conf "$(_effective_conf_source mangosd.conf)" "${ETC_DIR}/mangosd.k8s.conf" "/app/data" "/app/logs" "/app/bin/warden_modules"
    _render_realmd_conf  "$(_effective_conf_source realmd.conf)"  "${ETC_DIR}/realmd.k8s.conf"  "/app/logs"
    DB_HOST="$saved_db_host"

    info "Creating server config ConfigMap..."
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" create configmap vanilla-wow-conf \
        --from-file=mangosd.conf="${ETC_DIR}/mangosd.k8s.conf" \
        --from-file=realmd.conf="${ETC_DIR}/realmd.k8s.conf" \
        --dry-run=client -o yaml | kubectl $ctx_flags apply -f - \
        || error_exit "Failed to create the server ConfigMap."

    info "Creating the DB bootstrap ConfigMap..."
    # The Job runs lib/bootstrap.sh — the bootstrap 'configure' runs — through
    # templates/k8s/db-init.sh. Created on every deploy, so the Job always runs
    # this checkout's copy.
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" create configmap vanilla-wow-db-init \
        --from-file=bootstrap.sh="${SCRIPT_DIR}/lib/bootstrap.sh" \
        --from-file=db-init.sh="${k8s_tpl}/db-init.sh" \
        --dry-run=client -o yaml | kubectl $ctx_flags apply -f - \
        || error_exit "Failed to create the DB bootstrap ConfigMap."

    info "Running DB bootstrap Job (schemas + world dump + migrations)..."
    # A Job's pod template is immutable once created, so re-applying it with
    # anything changed (realm address, password, sql path) fails — delete
    # any previous run first (also drops its completed/failed pods).
    # shellcheck disable=SC2086
    kubectl $ctx_flags -n "$K8S_NAMESPACE" delete job vanilla-wow-db-init --ignore-not-found \
        || error_exit "Failed to remove the previous db-init Job."
    render_template "${k8s_tpl}/db-init-job.yaml" \
        "NAMESPACE=${K8S_NAMESPACE}" \
        "REALM_ID=${REALM_ID}" "REALM_NAME=$(_yaml_escape "$REALM_NAME")" "REALM_ADDRESS=$(_yaml_escape "$REALM_ADDRESS")" \
        "WORLD_PORT=${WORLD_PORT}" "CLIENT_BUILD=${CLIENT_BUILD}" \
        "CUSTOM_SQL=$(_yaml_escape "${CUSTOM_SQL:-}")" \
        "SQL_HOSTPATH=${SOURCE_DIR}/sql" > "$job_manifest"
    # shellcheck disable=SC2086
    kubectl $ctx_flags apply -f "$job_manifest" || error_exit "db-init Job apply failed."
    info "Waiting for db-init Job to complete (world dump import can take a while)..."
    local init_rc=0
    _wait_db_init "$ctx_flags" || init_rc=$?
    case "$init_rc" in
        1)  # Failed for good (backoffLimit used up): a server against a half-
            # bootstrapped DB only restarts forever, so it is not deployed.
            warn "db-init Job failed. Its last lines:"
            # shellcheck disable=SC2086
            kubectl $ctx_flags -n "$K8S_NAMESPACE" logs job/vanilla-wow-db-init --tail=30 >&2 || true
            error_exit "The DB bootstrap failed — the server was NOT deployed. Fix the cause, then run run-k8s again." ;;
        2)  warn "db-init Job did not complete in time — deploying the server anyway (it restarts until the DB is ready). Check: kubectl -n ${K8S_NAMESPACE} logs job/vanilla-wow-db-init" ;;
    esac

    # Only now that the DB is bootstrapped: the server Deployment.
    info "Applying server deployment..."
    # shellcheck disable=SC2086
    inject_block "${k8s_tpl}/server.yaml" "DATA_SOURCE" "$data_source_file" \
        | render_template /dev/stdin \
            "NAMESPACE=${K8S_NAMESPACE}" "IMAGE_TAG=${IMAGE_TAG}" \
            "REALM_PORT=${REALM_PORT}" "WORLD_PORT=${WORLD_PORT}" \
        | kubectl $ctx_flags apply -f - || error_exit "server deployment apply failed."

    # shellcheck disable=SC2086
    info "Waiting for server rollout..."
        kubectl $ctx_flags -n "$K8S_NAMESPACE" rollout status deployment/vanilla-wow-server --timeout=120s \
        || warn "Server rollout did not complete. Check: kubectl -n ${K8S_NAMESPACE} get pods"

    success "Deployed. hostNetwork pod — reachable on the node's LAN IP: realm ${REALM_PORT}, world ${WORLD_PORT}."
}

# _wait_db_init CTX_FLAGS — wait for the db-init Job: 0 when it completed, 1
# when it failed for good (its backoffLimit used up), 2 when it is still
# running after NORDRASSIL_DB_INIT_TIMEOUT seconds (900). `kubectl wait
# --for=condition=complete` waited out the full 900s on a Job that had
# already failed, then deployed anyway (Kamino item 109). Polled every
# NORDRASSIL_DB_INIT_POLL seconds (5).
_wait_db_init() {
    local ctx_flags="$1" waited=0 conds
    local poll="${NORDRASSIL_DB_INIT_POLL:-5}" limit="${NORDRASSIL_DB_INIT_TIMEOUT:-900}"
    while :; do
        # The condition types currently True, space-separated.
        # shellcheck disable=SC2086
        conds="$(kubectl $ctx_flags -n "$K8S_NAMESPACE" get job/vanilla-wow-db-init \
            -o 'jsonpath={range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null)" || conds=""
        case " ${conds} " in
            *" Failed "*)   return 1 ;;
            *" Complete "*) return 0 ;;
        esac
        (( waited >= limit )) && return 2
        sleep "$poll"; waited=$((waited + poll))
    done
}

# Scales the server Deployment to 0 — never touches mariadb, the PVCs, or
# the ConfigMap (same "stop the server, leave everything else alone"
# contract as cmd_stop/cmd_stop_docker). Uses the global --context/--kind
# target (or the ambient kube context when neither is given) rather than
# forcing a re-selection just to stop something.
cmd_stop_k8s() {
    header "nordrassil — Stop (Kubernetes)"
    _settings
    _require_owned_target stop-k8s
    _announce_kube_target

    command -v kubectl &>/dev/null || error_exit "kubectl not found."

    local ctx_flags; ctx_flags="$(kubectl_context_flag)"
    # shellcheck disable=SC2086
    kubectl $ctx_flags get deployment vanilla-wow-server -n "$K8S_NAMESPACE" &>/dev/null \
        || { info "No 'vanilla-wow-server' deployment found in namespace '${K8S_NAMESPACE}' — nothing to stop."; return; }

    # shellcheck disable=SC2086
    kubectl $ctx_flags scale deployment/vanilla-wow-server -n "$K8S_NAMESPACE" --replicas=0 \
        && success "Server deployment scaled to 0 replicas in namespace '${K8S_NAMESPACE}' (mariadb, PVCs, and the ConfigMap are untouched)." \
        || error_exit "Failed to scale down the server deployment."
    info "Resume it with: kubectl scale deployment/vanilla-wow-server -n ${K8S_NAMESPACE} --replicas=1 (or re-run 'run-k8s')."
}

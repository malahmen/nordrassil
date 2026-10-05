# nordrassil

> The World Tree. Roots in the database, a canopy your whole LAN can log into.

A **gum-free, flag-driven** engine that builds and runs a
[VMaNGOS](https://github.com/vmangos/core)-style **vanilla WoW (1.12.1 / client
build 5875)** server from a repack — natively for fast local iteration, and as
a Docker image or Kubernetes deployment for LAN-wide play.

It has **no interactive prompts**: every command is driven by flags and a flat
`key=value` config file, so it's equally usable from a shell, a Makefile, CI, or
cron. [scomp-link](https://github.com/malahmen/scomp-link) ships a thin
`gum` TUI (**wow-nordrassil**) that collects values and drives this by flags —
that front-end owns all the interactivity, nordrassil owns the logic.

## What it does

The repack ships compiled Windows binaries and a bundled Windows MySQL, but also
its own C++ source (a standard out-of-source CMake project). nordrassil **always
builds native Linux binaries from that source** — no Wine, no Windows MySQL. The
`.exe` files and `mysql5/` directory are ignored.

Two independent paths, one shared database bootstrap:

- **Local native** (`install-deps` / `configure` / `start` / `stop`): builds
  `mangosd`/`realmd` directly on this host via cmake+make for fast iteration.
  The ACE toolkit (a hard build dependency) isn't packaged for Fedora/RHEL, so
  `install-deps` builds it from source there instead, cached in
  `~/.cache/ace-wrappers/<version>/` (shared across checkouts, versioned so an
  ACE bump can't reuse a stale build); apt hosts use `libace-dev`.
- **Container** (`build-image` / `run-docker` / `run-k8s`): compiles inside an
  Ubuntu build stage regardless of host OS, so it works everywhere Docker does.
  This is the actual LAN-deployable artifact. k8s uses `hostNetwork` so the
  fixed client-expected ports work without a LoadBalancer.

The database is **always a separate MariaDB container/pod** — never bundled into
the server image, never installed natively on the host. The same bootstrap
sequence (schemas + world dump + migrations + optional `sql/Custom` content) is
reused by `configure` (local dev) and the k8s `db-init` Job.

Import state is tracked **inside the database**, in `realmd.nordrassil_applied`,
so what has been imported travels with the data rather than with this host. Each
step records a row (`base`, `anticheat`, `world-full`, `migration:<file>.sql`,
`custom:<file>.sql`) and is skipped on a later run. Recreating the container or
volume therefore re-imports correctly, where the earlier host-side marker files
would have claimed everything was already done against an empty database. An
existing install is migrated once, automatically, by seeding the table from those
old markers; a populated database with neither the table nor markers re-imports
and says so.

> **Platform:** the server is Linux + Docker + Kubernetes, and the script needs
> bash 4+ (macOS ships 3.2 — `brew install bash`). From macOS only the config
> store (`set`/`get`/`config`) and, against a remote kube context, the k8s
> account/search commands are useful; building and running the server needs
> Linux.

## Install / usage

`nordrassil.sh` is a self-contained Bash script (plus a `templates/` directory
of Dockerfile / entrypoint / k8s manifests / source patches). No `gum`, no
`_common` — clone and run:

```sh
./nordrassil.sh help        # same as -h / --help
```

### Global flags (kube target for `run-k8s` / `stop-k8s`)

| Flag | Meaning |
| --- | --- |
| `--context CTX` | use kube-context `CTX` |
| `--kind CLUSTER` | use kind cluster `CLUSTER` (context `kind-CLUSTER`; side-loads the image) |
| `--profile NAME` | use the profile `NAME` (see [Profiles](#profiles)); also `$NORDRASSIL_PROFILE` |

Neither given ⇒ the current kube context.

### Commands

```
Setup / local
  install-deps
  configure [--custom NAMES]              # DB bootstrap + render the local conf files (no build)
  edit --file mangosd|realmd              # open a conf file in $EDITOR (default vim)
  start | stop | status

Deploy
  build-image
  run-docker [--force]                    # --force recreates an existing container
  stop-docker
  run-k8s [--namespace NS] [--address ADDR]
  stop-k8s

Accounts
  create-account --name N --pass P [--level 0-6] [--where local|docker|k8s]
  list-accounts [--where ...]
  delete-account --name N [--where ...]
  set-account-level --name N --level 0-6 [--where ...]

Characters
  rename-character --from OLD --to NEW

Search
  search --kind items|npcs|teleports|characters --term TERM

Config store
  set KEY VALUE | get KEY | config | list-custom

Administration
  apply-sql --file PATH --db NAME [--force] [--no-record]
  restart [--graceful [SECS]] [--where ...]

Profiles
  profiles                        list profiles, marking the active one
  forget [--all]                  drop the cached database password

help | -h | --help
```

`--where` disambiguates only when a server is running under more than one
target at once; otherwise nordrassil auto-detects. `list-custom` lists the
`sql/Custom/*.sql` basenames available to `configure --custom`.

Things worth knowing:

- `configure` does not build anything: it starts the local MariaDB container,
  runs the DB bootstrap, and (re)renders `mangosd.conf`/`realmd.conf` into
  `~/.config/nordrassil/etc/` from the repack's pristine copies — so it
  **overwrites any changes made with `edit`**. The first `start` does the
  native build. `run-docker`/`run-k8s` render from the `edit`ed copies, so
  hand edits survive there; `start` just needs a restart to pick them up.
- `run-k8s` never pushes the image anywhere. With `--kind` it side-loads it
  (`kind load docker-image`); for any other context the image must already be
  present on the node (or set `IMAGE_TAG` to a registry tag you pushed
  yourself). With `K8S_STORAGE_TYPE=hostpath` on kind, the paths
  (`K8S_DATA_HOSTPATH`, `K8S_DB_HOSTPATH`, and `$SOURCE_DIR/sql` for the
  db-init Job) must be mounted into the kind node with `extraMounts` in the
  cluster config — a kind node is a container and can't see the host's
  filesystem otherwise.
- The k8s `db-init` Job applies **every** `sql/Custom/*.sql` it finds; the
  `CUSTOM_SQL` selection only applies to `configure`/`run-docker`.

### Examples

```sh
# point at the repack, then bootstrap the DB + local conf
./nordrassil.sh set SOURCE_DIR ~/jaws/MaNGOS
./nordrassil.sh configure

# LAN deploy via Docker
./nordrassil.sh build-image
./nordrassil.sh run-docker --force

# LAN deploy onto a kind cluster
./nordrassil.sh --kind homelab run-k8s --namespace wow --address 192.168.1.50

# a GM account and a rename
./nordrassil.sh create-account --name admin --pass secret --level 3
./nordrassil.sh rename-character --from Leeroy --to Jenkins
```

## Administration

`apply-sql` runs a `.sql` file against one database, over whatever transport
the profile names — so the same command works on a local container and on a
remote cluster. It is the thing `configure` cannot do: apply a customization
to a server that is already running.

It is tracked **by content**, not filename. The record is
`sql:<basename>@<sha256 prefix>` in `realmd.nordrassil_applied`, so re-running
an unchanged file is a no-op while an edited one applies again on its own;
`--force` applies regardless, `--no-record` skips the bookkeeping. A file that
fails is never recorded, so fixing it and re-running is the normal path.

Not atomic — DDL in MariaDB is not transactional, so a file that fails halfway
leaves what already ran in place. The client stops at the first error.

```sh
./nordrassil.sh --profile meksha apply-sql --file ./my-change.sql --db mangos
```

`restart` has two modes, which fail differently:

| | |
| --- | --- |
| default | restart at the orchestrator — container restart, or deleting the pod. Deterministic: does not need mangosd healthy enough to read its console. |
| `--graceful [SECS]` | ask mangosd to restart in `SECS`, warning players and saving the world first. Needs a working console. |

Neither mode starts the server again itself; the container's restart policy
does that. Deleting the pod is deliberate rather than `kubectl rollout
restart`: a delete changes no manifest, so a GitOps controller has nothing to
revert — verified against Argo CD with self-healing on, which stayed
`Synced/Healthy` across a restart.

**`SECS` is not how long the restart takes.** It is how long mangosd waits
before stopping; coming back depends on the supervisor noticing. On a k8s
deployment where mangosd and realmd share a container, mangosd stopped on
schedule but the container ran on until the liveness probe failed three times
(~90s) and kubelet sent `TERM` — so `--graceful 15` took about 95s end to end.
The default path has no such dependency.

## Transports

Reaching the **database** and reaching **mangosd** are separate questions, and
a deployment need not answer them the same way — a server can run as a k8s
Deployment while its MariaDB runs in podman on the host beside it. Two
independent settings, so no single value has to describe the whole stack:

| | Values |
| --- | --- |
| `DB_TRANSPORT` | `auto` \| `docker` \| `podman` \| `kubectl` \| `tcp` |
| `SERVER_TRANSPORT` | `auto` \| `local` \| `docker` \| `podman` \| `kubectl` |

`auto` probes the local container, then the cluster, then a TCP endpoint, which
is what this script did before the two were separable.

**SSH is a third, orthogonal axis.** `DB_SSH_HOST` / `SERVER_SSH_HOST` say
*where the orchestrator runs*, not which one — so administering a remote
cluster needs no `kubectl` on the machine you are sitting at, and a remote
podman container needs no published port. Remoteness multiplies nothing:
nothing about reaching a container engine changes because it is on another
host. With an ssh host set the transport must be explicit; `auto` will not
probe across a network. Every ssh call is `BatchMode`, so key-based auth only.

## Profiles

A profile is one server. `~/.config/nordrassil/profiles/NAME.conf`, layered
**over** `nordrassil.conf`: a key present in the profile wins, anything absent
falls through to the base file. Shared settings stay in one place and a profile
carries only what actually differs. `set` writes to the active profile, or to
the base file when none is active.

`DB_PASS=ask` prompts **once per session, per profile**. The answer is cached
in `$XDG_RUNTIME_DIR` — tmpfs, mode `0600`, gone on logout — so it is never
written to a persistent file; with no `$XDG_RUNTIME_DIR` it simply prompts
every time. `forget` clears it.

A worked example: a k8s server on another host, its MariaDB in podman beside
it, driven from a machine with neither `kubectl` nor the password on it.

```sh
./nordrassil.sh --profile meksha set DB_TRANSPORT podman
./nordrassil.sh --profile meksha set DB_SSH_HOST meksha
./nordrassil.sh --profile meksha set DB_CONTAINER_NAME mariadb
./nordrassil.sh --profile meksha set DB_PASS ask
./nordrassil.sh --profile meksha set SERVER_TRANSPORT kubectl
./nordrassil.sh --profile meksha set SERVER_SSH_HOST meksha
./nordrassil.sh --profile meksha set K8S_NAMESPACE azeroth
./nordrassil.sh --profile meksha set SERVER_POD_SELECTOR app=azeroth
./nordrassil.sh --profile meksha set SERVER_K8S_CONTAINER azeroth
./nordrassil.sh --profile meksha set SERVER_FIFO /opt/azeroth/mangosd.stdin

./nordrassil.sh --profile meksha search --kind npcs --term Hogger
./nordrassil.sh --profile meksha create-account --name bob --pass hunter2
```

## Configuration

State lives in `~/.config/nordrassil/nordrassil.conf` (XDG-style, `key=value`,
one setting per line), with per-server overrides in
`~/.config/nordrassil/profiles/NAME.conf` (see [Profiles](#profiles)).
Read/write it with `get`/`set`/`config`; commands read it back on every run and
fall back to sane defaults for anything unset.

| Key | Default | Notes |
| --- | --- | --- |
| `SOURCE_DIR` | `~/jaws/MaNGOS` | repack root (must contain the source + `mangosd.conf`/`realmd.conf`) |
| `CLIENT_BUILD` | `5875` | 1.12.1 client build the binary supports |
| `DB_HOST` / `DB_PORT` | `127.0.0.1` / `3306` | MariaDB endpoint |
| `DB_USER` / `DB_PASS` | `root` / `root` | MariaDB credentials |
| `DB_CONTAINER_NAME` / `DB_VOLUME` | `nordrassil-mariadb` / `vanilla-wow-mariadb-data` | local MariaDB container + volume |
| `REALM_ID` / `REALM_PORT` / `WORLD_PORT` | `1` / `3724` / `8085` | realmlist row + fixed client ports |
| `REALM_ADDRESS` | detected LAN IP | address the client connects to after auth (never `127.0.0.1` for LAN) |
| `REALM_NAME` / `REALM_ZONE` | `VanillaWoW` / `1` | realm identity |
| `GAME_TYPE` / `PLAYER_LIMIT` | `1` (PvP) / `100` | |
| `WOW_PATCH` | `10` (1.12) | content/progression cap, distinct from `CLIENT_BUILD` |
| `MOTD` / `XP_RATE` / `DROP_RATE` | `Welcome…` / `1` / `1` | gameplay |
| `WRONG_PASS_*`, `REQ_EMAIL_VERIFICATION`, `STRICT_VERSION_CHECK` | repack defaults | realmd security |
| `WARDEN_ENABLED` | `1` | anti-cheat (both Win/OSX together) |
| `STRICT_PLAYER_NAMES` | `0` | `0` also disables the DBC profanity/reserved-name check (see the source patch) |
| `IMAGE_TAG` / `SERVER_CONTAINER_NAME` | `vanilla-wow-server:latest` / `vanilla-wow-server` | Docker |
| `K8S_NAMESPACE` | `vanilla-wow` | |
| `CUSTOM_SQL` | (empty) | comma/space-separated `sql/Custom` basenames applied by `configure` |
| `K8S_STORAGE_TYPE` | `hostpath` | `hostpath` \| `storageclass` |
| `K8S_DATA_HOSTPATH` / `K8S_DB_HOSTPATH` | `$SOURCE_DIR/data` / `/var/vanilla-wow-mariadb` | hostPath backing |
| `K8S_STORAGECLASS` | (empty) | StorageClass name (empty = cluster default) |
| `DB_TRANSPORT` / `SERVER_TRANSPORT` | `auto` / `auto` | see [Transports](#transports) |
| `DB_SSH_HOST` / `SERVER_SSH_HOST` | (empty) | empty = local; otherwise run the orchestrator there over ssh |
| `DB_POD_SELECTOR` | `app=vanilla-wow-mariadb` | label selector for the MariaDB pod |
| `SERVER_POD_SELECTOR` | `app=vanilla-wow-server` | label selector for the mangosd pod |
| `SERVER_K8S_CONTAINER` | (empty) | container in that pod; empty lets kubectl choose (and print "Defaulted container…") |
| `SERVER_FIFO` | `/app/mangosd.stdin` | mangosd's console FIFO **inside** the container |

## Credits

The server itself is [VMaNGOS](https://github.com/vmangos/core) and the vanilla
WoW emulation community's work. nordrassil is the build/deploy/administration
automation *around* a repack of it — it compiles, containerizes, deploys, and
administers; the emulator is theirs.

## License

[The Unlicense](LICENSE) — public domain.

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
  `install-deps` builds it from source there instead; apt hosts use `libace-dev`.
- **Container** (`build-image` / `run-docker` / `run-k8s`): compiles inside an
  Ubuntu build stage regardless of host OS, so it works everywhere Docker does.
  This is the actual LAN-deployable artifact. k8s uses `hostNetwork` so the
  fixed client-expected ports work without a LoadBalancer.

The database is **always a separate MariaDB container/pod** — never bundled into
the server image, never installed natively on the host. The same bootstrap
sequence (schemas + world dump + migrations + optional `sql/Custom` content) is
reused by `configure` (local dev) and the k8s `db-init` Job.

> **Platform:** the server is Linux + Docker + Kubernetes. macOS can drive the
> config/account subcommands, but building and running the server needs Linux.

## Install / usage

`nordrassil.sh` is a self-contained Bash script (plus a `templates/` directory
of Dockerfile / entrypoint / k8s manifests / source patches). No `gum`, no
`_common` — clone and run:

```sh
./nordrassil.sh --help
```

### Global flags (kube target for `run-k8s` / `stop-k8s`)

| Flag | Meaning |
| --- | --- |
| `--context CTX` | use kube-context `CTX` |
| `--kind CLUSTER` | use kind cluster `CLUSTER` (context `kind-CLUSTER`; side-loads the image) |

Neither given ⇒ the current kube context.

### Commands

```
Setup / local
  install-deps
  configure [--custom NAMES]              # (re)build prerequisites + DB bootstrap
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
```

`--where` disambiguates only when a server is running under more than one
target at once; otherwise nordrassil auto-detects. `list-custom` lists the
`sql/Custom/*.sql` basenames available to `configure --custom`.

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

## Configuration

State lives in `~/.config/nordrassil/nordrassil.conf` (XDG-style, `key=value`,
one setting per line). Read/write it with `get`/`set`/`config`; commands read it
back on every run and fall back to sane defaults for anything unset.

| Key | Default | Notes |
| --- | --- | --- |
| `SOURCE_DIR` | `~/jaws/MaNGOS` | repack root (must contain the source + `mangosd.conf`/`realmd.conf`) |
| `CLIENT_BUILD` | `5875` | 1.12.1 client build the binary supports |
| `DB_HOST` / `DB_PORT` | `127.0.0.1` / `3306` | MariaDB endpoint |
| `DB_USER` / `DB_PASS` | `root` / `root` | MariaDB credentials |
| `DB_CONTAINER_NAME` / `DB_VOLUME` | `vanilla-wow-mariadb` / `-data` | local MariaDB container + volume |
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

## Credits

The server itself is [VMaNGOS](https://github.com/vmangos/core) and the vanilla
WoW emulation community's work. nordrassil is the build/deploy/administration
automation *around* a repack of it — it compiles, containerizes, deploys, and
administers; the emulator is theirs.

## License

[The Unlicense](LICENSE) — public domain.

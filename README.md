# XPAM Installer

Installs and manages XPAM on a Linux server.

## Install

On a clean server (Rocky/Alma/RHEL 8+, Ubuntu 20.04+, Debian 11+), as root:

```bash
curl -fsSL https://raw.githubusercontent.com/Sajjad-alaa/xpam-installer/xpam/quick_start.sh | bash
```

That one command downloads this installer to `/opt/xpam-installer`, installs Docker, asks a few
questions (Enter accepts the default), downloads the XPAM images, creates the database and starts
XPAM. The images are private: the installer asks you once to sign in to `ghcr.io` with a GitHub
token that has the `read:packages` scope.

The same thing by hand:

```bash
git clone -b xpam https://github.com/Sajjad-alaa/xpam-installer.git /opt/xpam-installer
cd /opt/xpam-installer && ./xpamctl.sh install
```

Full guide: **[docs/INSTALL.md](docs/INSTALL.md)**.

What changed in each version: **[docs/RELEASE-NOTES.md](docs/RELEASE-NOTES.md)**. To install the
previous version instead, use the tag `xpam-v5.0.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/Sajjad-alaa/xpam-installer/xpam-v5.0.0/quick_start.sh | XPAM_INSTALLER_BRANCH=xpam-v5.0.0 bash
```

## Everyday commands

`xpamctl` works from any folder after the installation.

| Command | What it does |
|---|---|
| `xpamctl status` | state of every service |
| `xpamctl start` / `stop` / `restart` | all services, or one: `xpamctl restart core` |
| `xpamctl upgrade` | updates the installer, backs up config and database, downloads the current images, migrates the database, restarts |
| `xpamctl check_update` | tells whether a newer installer is published |
| `xpamctl version` | the XPAM release and the exact build of each image |
| `xpamctl backup_db` / `restore_db <file>` | database backup and restore |
| `xpamctl tail [service]` | follow the logs |
| `xpamctl uninstall` | remove XPAM from the server |

## Where things are

| | |
|---|---|
| Configuration | `/opt/xpam/config/config.txt` (keep a copy: it holds the secret keys) |
| Data (database, recordings, logs) | `/data/xpam` (`VOLUME_DIR`) |
| Installer | `/opt/xpam-installer` |

A server installed before the rename keeps using `/opt/jumpserver/config` and its existing data
folder. `XPAM_CONFIG_DIR` overrides the configuration folder.

## Services and images

| Service | Container | Image | Public path |
|---|---|---|---|
| gateway (front door: ports, TLS, routing) | `xpam_gateway` | `xpam/gateway` | everything enters here |
| core, worker | `xpam_core`, `xpam_worker` | `xpam/core` | `/core/`, `/api/` |
| web (admin console) | `xpam_web` | `xpam/web` | `/web/` |
| workspace (web terminal) | `xpam_workspace` | `xpam/workspace` | `/workspace/` |
| secureconnection (SSH, RDP, remote desktop) | `xpam_secureconnection` | `xpam/secureconnection` | `/secureconnection/` |
| webconnector (database web client) | `xpam_webconnector` | `xpam/webconnector` | `/webconnector/` |
| ai (assistant) | `xpam_ai` | `xpam/ai` | `/ai/` |
| database, cache | `xpam_postgresql`, `xpam_redis` | `postgres`, `redis` | not published |

Each part runs in its own container. Stopping or replacing one does not affect the others: the
gateway answers that path with a short "temporarily unavailable" page and picks the container up
again within about ten seconds of its return.

### Where the images come from

The installer downloads `<registry>/<name>:<version>` and refreshes it on every install and
upgrade, so a server never keeps running an older build with the same tag. The defaults are in
`static.env`: registry `ghcr.io/sajjad-alaa/xpam`, version `v5.1.16`.

`config.txt` can override this:

| Setting | Meaning |
|---|---|
| `XPAM_IMAGE_REGISTRY=<registry>/<path>` | download from another registry (a mirror of your own) |
| `XPAM_IMAGE_REGISTRY=local` | never download: use the images built or loaded on this server |
| `XPAM_VERSION`, `XPAM_NAMESPACE` | another tag or local name |

Unattended installs can pass the registry credentials in the environment instead of answering the
prompt: `XPAM_REGISTRY_USER`, `XPAM_REGISTRY_TOKEN` (not stored by XPAM), together with
`AUTO_INSTALL=1` to accept every default.

XPAM images are never pulled from Docker Hub (the `xpam` namespace there is not ours).

## Building the images

The Dockerfiles, gateway configuration, brand kit and build scripts are in
[`build/`](build/README.md). On a build server set `XPAM_IMAGE_REGISTRY=local` in `config.txt`,
build with `build/build-all.sh`, test, then publish with `build/push-ghcr.sh`.

## Server without internet access

On a machine that has the images run `bash scripts/0_prepare.sh`, copy the whole folder to the
offline server and run `./xpamctl.sh install` there. See the guide for details.

## Tests

`bash tests/run.sh` runs the installer's regression tests (no Docker needed).

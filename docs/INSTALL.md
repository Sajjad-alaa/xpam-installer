# XPAM installation guide

This guide installs XPAM on one Linux server, using the images published in the GitHub Container
Registry. Plan about 20 minutes.

## 1. What you need

**Server**

| | Minimum | Recommended |
|---|---|---|
| OS | 64-bit Linux with systemd (Rocky/Alma/RHEL 8+, Ubuntu 20.04+, Debian 11+) | same |
| CPU / RAM | 4 cores, 8 GB | 8 cores, 16 GB |
| Disk | 60 GB | 200 GB+ (session recordings grow) |
| Access | root, or a user with sudo | |

Use a clean server. The installer sets up Docker itself; you do not need to install it first.

**Network**

| Port | Direction | Purpose |
|---|---|---|
| 443 (and 80, which redirects to 443) | users → server | web UI, workspace, API |
| 2222 | users → server | SSH/SFTP client access |
| 5001 | users → server | website-asset proxy for the desktop client |
| 22, 3389, database ports | server → your assets | the sessions XPAM opens |
| 443 outbound | server → github.com, ghcr.io, download.docker.com | install only |

**From GitHub**

- A personal access token with the **`read:packages`** scope (Settings → Developer settings →
  Personal access tokens → Tokens (classic)). The installer asks for it once, to download the
  private XPAM images.

## 2. Install

Run this as root on the new server:

```bash
curl -fsSL https://raw.githubusercontent.com/Sajjad-alaa/xpam-installer/xpam/quick_start.sh | bash
```

What happens, in order:

1. The installer is downloaded to `/opt/xpam-installer`, and missing system tools (git, wget,
   gettext, iptables) and Docker are installed.
2. It asks a few questions. Pressing Enter accepts the default, which is right for a standard
   single-server install:

   | Question | Default | Change it when |
   |---|---|---|
   | Data directory | `/data/xpam` | you have a larger disk mounted elsewhere. **It cannot be moved later.** |
   | Database | built-in PostgreSQL | you have your own PostgreSQL/MySQL server |
   | Redis | built-in | you have your own Redis |
   | External ports | 80 / 443 / 2222 | those ports are taken |
   | Language, time zone | English, the server's time zone | |

3. **Sign-in to the image registry.** The XPAM images are private, so the installer asks for a
   GitHub user name and then for a password: paste the `read:packages` token there (nothing is
   shown while you paste). This is needed once per server.
4. The images are downloaded (several GB), the database is created, and you are asked whether to
   start XPAM now (Enter = yes). The installer waits until every service is ready and prints the
   address to open.

If anything fails, fix what the message says and run `xpamctl install` again: it continues where
it stopped and keeps the answers you already gave.

The same installation by hand, if you prefer not to pipe a script into a shell:

```bash
git clone -b xpam https://github.com/Sajjad-alaa/xpam-installer.git /opt/xpam-installer
cd /opt/xpam-installer && ./xpamctl.sh install
```

**Unattended installation** (no questions): set `AUTO_INSTALL=1`, and pass the registry sign-in in
the environment as `XPAM_REGISTRY_USER` and `XPAM_REGISTRY_TOKEN`. XPAM does not store the token.

## 3. First login

1. Open `https://<server-ip>/`. The browser warns about the certificate, because the server
   starts with a self-signed one (see step 4).
2. Sign in with **admin / ChangeMe**. You are forced to set a new password (administrators:
   at least 14 characters with upper case, lower case and a number).
3. A new server runs on the built-in trial license: 2 users, 1 asset, 1 month. Import your license
   under System settings → License. Licenses are bound to the server, so one issued for another
   server does not work here.

## 4. Before real use

- **Certificate.** Put your certificate and key in `/opt/xpam/config/nginx/cert/` as `server.crt`
  and `server.key`, then `xpamctl restart`.
- **Server name.** People can sign in through any address that reaches the server (its IP, a
  public IP, a DNS name); nothing has to be listed. Set `SERVER_NAME=pam.example.com` in
  `/opt/xpam/config/config.txt` and run `xpamctl restart` when you install a certificate for a
  name, so the gateway answers under that name.
- **Reverse proxy or load balancer in front.** If another device terminates HTTPS and forwards
  to XPAM, set `USE_LB=0` in `config.txt` and make that device send `X-Forwarded-For` and
  `X-Forwarded-Proto`. Without it sign-in is refused, because XPAM cannot tell that the browser
  used HTTPS.
- **Backups.** Schedule `xpamctl backup_db` (it writes to `/data/xpam/db_backup/`) and copy
  `/opt/xpam/config/` somewhere safe. The config holds the secret keys; without them a database
  backup cannot be read.
- **Firewall.** Open only 443, 80, 2222 and 5001 to users.
- **Desktop client.** Users download it from the "Download" link in the web UI.
- **Sign-in policy.** Passwords need 12 characters (14 for administrators) with upper case, lower
  case and a number, an address is blocked for 30 minutes after 50 failed sign-ins, and a session
  ends after 12 idle hours or when the browser is closed. Multi-factor authentication is **off**
  on a new server: switch it on under System settings → Security (for administrators or for
  everyone); each user is then asked to scan a QR code with an authenticator app at the next
  sign-in. A value saved there wins over the defaults.
- **Name, logo and help links.** A new server is called XPAM and uses the XPAM logo and colours.
  Change the name, logo and theme under System settings → Interface, and the "Documentation" and
  "Support" links of the help menu under System settings → Basic.
- **Kubernetes assets.** The session service runs without host privileges. Kubernetes sessions
  in the web terminal need them: set `KOKO_PRIVILEGED=true` in `config.txt` and `xpamctl restart`
  only if you use that feature.

## 5. Everyday commands

`xpamctl` works from any folder after installation.

| Command | What it does |
|---|---|
| `xpamctl status` | show the services and their health |
| `xpamctl start` / `stop` / `restart` | start, stop or restart everything |
| `xpamctl tail core` | follow the log of one service (`core`, `worker`, `gateway`, `web`, `workspace`, `secureconnection`, `webconnector`, `ai`) |
| `xpamctl backup_db` | back up the database |
| `xpamctl restore_db <file>` | restore a backup |
| `xpamctl upgrade` | update the installer and XPAM to the current build (backs up first) |
| `xpamctl version` | the XPAM release and the exact build of each image |
| `xpamctl uninstall` | remove XPAM (asks before deleting data) |

Where things are:

| | Location |
|---|---|
| Configuration | `/opt/xpam/config/config.txt` |
| Data, recordings, logs, backups | `/data/xpam/` |
| Installer | `/opt/xpam-installer/` |
| Containers | `xpam_gateway`, `xpam_core`, `xpam_worker`, `xpam_web`, `xpam_workspace`, `xpam_secureconnection`, `xpam_webconnector`, `xpam_ai`, `xpam_postgresql`, `xpam_redis` |

### What each container does

| Container | Role | If it stops |
|---|---|---|
| `xpam_gateway` | the front door: ports 80/443, certificate, routing | nothing is reachable |
| `xpam_core` | application and API | logins and new sessions fail |
| `xpam_worker` | background jobs: schedules, account automation, notifications | those jobs wait; logins and sessions keep working |
| `xpam_postgresql`, `xpam_redis` | database and cache | everything stops |
| `xpam_secureconnection` | SSH, RDP, SFTP and Kubernetes sessions | those sessions drop; the UI keeps working |
| `xpam_web` | admin console pages | only the admin console is unavailable |
| `xpam_workspace` | workspace pages in the browser | only the browser workspace is unavailable; the desktop client keeps working |
| `xpam_webconnector` | database sessions in the browser | only those sessions are unavailable |
| `xpam_ai` | AI assistant | only the assistant is unavailable |

### Security defaults

- HTTPS only: port 80 redirects to 443, and browsers are told to keep using HTTPS (HSTS, one year).
  Use a host name with a real certificate; the built-in certificate is self-signed.
- No container runs with full host privileges, and none has access to the Docker socket.
- The admin console and workspace containers have a read-only file system and no extra capabilities.
- Automation jobs (connectivity tests, account verification, password changes) run inside the
  worker. Upstream's separate "Docker execution environment" for Ansible is off, because it
  requires giving the worker control of the host's Docker.
- Session and CSRF cookies are sent over HTTPS only.
- The SSH service (port 2222) offers only SHA-2 based host key signatures and message
  authentication codes. Very old SSH clients (OpenSSH before 7.2, PuTTY before 0.68) cannot connect.
- `BOOTSTRAP_TOKEN` in `config.txt` is only used when a component registers for the first time.
  To replace it, put a new random value in `config.txt` and run `xpamctl start`; components that
  are already registered keep working.

## 6. Upgrading

```bash
xpamctl upgrade
```

One command: it updates the installer itself, backs up the configuration and the database (to
`/data/xpam/db_backup/`), downloads the current images, migrates the database and, after asking,
restarts XPAM with the new version. `xpamctl check_update` tells you beforehand whether a newer
installer is published, and `xpamctl version` shows what is running.

When it asks whether to clean up old images, answer **n** if you build images on this server.

## 7. Server without internet access

On a machine that has the images (after `docker login` and a pull, or after a local build):

```bash
cd /opt/xpam-installer && bash scripts/0_prepare.sh     # saves images and Docker into scripts/
```

Copy the whole `xpam-installer` folder to the offline server and run `./xpamctl.sh install`
there. The installer loads the saved images instead of downloading them.
For the desktop client, copy the installers to `/data/xpam/web/download/` and set
`CLIENT_DOWNLOAD_BASE_URL=/download/public` in `config.txt`.

## 8. Website assets through a publishing host (optional)

Website assets opened through a Windows publishing host (RemoteApp machine) use the
**XPAM WebLite** browser. The host downloads its installer from this server, so copy
`XPAM-WebLite-<version>-x64.msi` from the client release on GitHub to `/data/xpam/web/applets/`
before you publish the WebLite applet to the host. Without that file the installation on the host
fails with "not found".

## 9. If something goes wrong

| Symptom | Cause and fix |
|---|---|
| "This server is not allowed to download the XPAM images" | not signed in, or the token lacks `read:packages`: `docker login ghcr.io -u Sajjad-alaa`, then `xpamctl install` again |
| `download failed from ghcr.io/...` | no connection to `ghcr.io` (HTTPS, port 443), or the disk is full: the two lines under the message give the reason |
| `XPAM image not found on this server` | `XPAM_IMAGE_REGISTRY=local` is set in `config.txt` but the images were never built or loaded here: remove that line to download them |
| A service stays `unhealthy` | `xpamctl tail <service>` shows why; `core` takes the longest on first start |
| Sign-in is refused with "Configuration file has problems" | a reverse proxy in front of XPAM terminates HTTPS: set `USE_LB=0` in `config.txt` and let the proxy send `X-Forwarded-Proto` (see step 4), then `xpamctl restart` |
| "This part of XPAM is temporarily unavailable" | the container behind that path is stopped or restarting: `xpamctl status`, then `xpamctl start`. It answers again about ten seconds after the container is healthy |
| Port already in use | change `HTTP_PORT` / `HTTPS_PORT` / `KOKO_SSH_PORT` in `config.txt`, then `xpamctl restart` |

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
  Tokens (classic)). It is used once on the server to download the private XPAM images.

## 2. Install

Run everything as root.

```bash
# 1. Get the installer
cd /opt
git clone -b xpam https://github.com/Sajjad-alaa/xpam-installer.git
cd xpam-installer

# 2. Create the configuration and point it at the XPAM images
mkdir -p /opt/xpam/config
cp config-example.txt /opt/xpam/config/config.txt
echo "XPAM_IMAGE_REGISTRY=ghcr.io/sajjad-alaa/xpam" >> /opt/xpam/config/config.txt

# 3. Install
./xpamctl.sh install
```

The installer asks a few questions. Pressing Enter accepts the default, which is right for a
standard single-server install:

| Question | Default | Change it when |
|---|---|---|
| Data directory | `/data/xpam` | you have a larger disk mounted elsewhere. **It cannot be moved later.** |
| Database | built-in PostgreSQL | you have your own PostgreSQL/MySQL server |
| Redis | built-in | you have your own Redis |
| External ports | 80 / 443 / 2222 | those ports are taken |

**The first run stops at "Loading Docker Image"** with `pull failed`. That is expected: the images
are private and the server is not logged in yet. Log in (paste the token when asked for the
password), then run the install again; it continues where it stopped.

```bash
docker login ghcr.io -u Sajjad-alaa
./xpamctl.sh install
```

Then start XPAM:

```bash
./xpamctl.sh start
./xpamctl.sh status      # every service should show (healthy) within about two minutes
```

## 3. First login

1. Open `https://<server-ip>/`. The browser warns about the certificate, because the server
   starts with a self-signed one (see step 4).
2. Sign in with **admin / ChangeMe**. You are forced to set a new password (administrators:
   at least 14 characters with upper case, lower case and a number).
3. Administrators must use multi-factor authentication. At the next sign-in XPAM shows a QR code:
   scan it with an authenticator app (Google Authenticator, Microsoft Authenticator, Aegis, ...)
   and enter the 6-digit code. Keep the phone: without it the administrator cannot sign in.
   If it is lost, another administrator can reset it under Users, or run on the server
   `docker exec xpam_core python /opt/jumpserver/apps/manage.py shell -c "from users.models import User; User.objects.filter(username='admin').update(otp_secret_key='')"`
   (the administrator is then asked to scan a new QR code).
4. A new server runs on the built-in trial license: 2 users, 1 asset, 1 month. Import your license
   under System settings → License. Licenses are bound to the server, so one issued for another
   server does not work here.

## 4. Before real use

- **Certificate.** Put your certificate and key in `/opt/xpam/config/nginx/cert/` as `server.crt`
  and `server.key`, then `xpamctl restart`.
- **Server name.** If people reach XPAM through a domain name or a different address than the
  server's own IP, set `SERVER_NAME=pam.example.com` and `DOMAINS="pam.example.com:443"` in
  `/opt/xpam/config/config.txt` (several entries are comma-separated), then `xpamctl restart`.
  Without the right entry, logging in from that address fails with a CSRF error.
- **Backups.** Schedule `xpamctl backup_db` (it writes to `/data/xpam/db_backup/`) and copy
  `/opt/xpam/config/` somewhere safe. The config holds the secret keys; without them a database
  backup cannot be read.
- **Firewall.** Open only 443, 80, 2222 and 5001 to users.
- **Desktop client.** Users download it from the "Download" link in the web UI.
- **Sign-in policy.** XPAM starts stricter than upstream: multi-factor authentication is required
  for administrators, passwords need 12 characters (14 for administrators) with upper case, lower
  case and a number, an address is blocked for 30 minutes after 50 failed sign-ins, and a session
  ends after 12 idle hours or when the browser is closed. Change any of this under
  System settings → Security; consider requiring multi-factor authentication for everyone.
  A value saved there wins over these defaults.
- **Kubernetes assets.** The session service runs without host privileges. Kubernetes sessions
  in the web terminal need them: set `KOKO_PRIVILEGED=true` in `config.txt` and `xpamctl restart`
  only if you use that feature.

## 5. Everyday commands

`xpamctl` works from any folder after installation.

| Command | What it does |
|---|---|
| `xpamctl status` | show the services and their health |
| `xpamctl start` / `stop` / `restart` | start, stop or restart everything |
| `xpamctl tail core` | follow the log of one service (`core`, `worker`, `gateway`, `web`, `workspace`, `koko`, `chen`, `kael`) |
| `xpamctl backup_db` | back up the database |
| `xpamctl restore_db <file>` | restore a backup |
| `xpamctl upgrade` | upgrade to the version in this installer |
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
cd /opt/xpam-installer
git pull
xpamctl upgrade
```

`upgrade` backs up the database, downloads the new images and migrates the database. When it asks
whether to clean up old images, answer **n** if you build images on this server.

## 7. Server without internet access

On a machine that has the images (after `docker login` and a pull, or after a local build):

```bash
cd /opt/xpam-installer && bash scripts/0_prepare.sh     # saves images and Docker into scripts/
```

Copy the whole `xpam-installer` folder to the offline server and run `./xpamctl.sh install`
there. Leave `XPAM_IMAGE_REGISTRY` unset; the installer loads the saved images instead of pulling.
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
| `pull failed` for `ghcr.io/...` | not logged in, or the token lacks `read:packages`: `docker login ghcr.io -u Sajjad-alaa`, then install again |
| `XPAM image not found` | `XPAM_IMAGE_REGISTRY` is missing from `config.txt` and no local images exist |
| A service stays `unhealthy` | `xpamctl tail <service>` shows why; `core` takes the longest on first start |
| Login page loads, login is rejected with a CSRF error | the address you use is missing from `DOMAINS` in `config.txt`, or you are on plain `http://` |
| "This part of XPAM is temporarily unavailable" | the container behind that path is stopped or restarting: `xpamctl status`, then `xpamctl start`. It answers again about ten seconds after the container is healthy |
| Port already in use | change `HTTP_PORT` / `HTTPS_PORT` / `KOKO_SSH_PORT` in `config.txt`, then `xpamctl restart` |

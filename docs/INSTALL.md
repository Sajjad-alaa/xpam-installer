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
- **Replacing SECRET_KEY.** Servers installed before 5.1.10 derived SECRET_KEY from the hardware
  ID. Replace it once, in a maintenance window (XPAM is offline for a few minutes and everybody
  signs in again):

  ```bash
  xpamctl rotate-secret-key
  ```

  It backs up the database and `config.txt`, stops XPAM (database and Redis keep running),
  re-encrypts every stored secret with a new random key in one database transaction, saves the
  key, clears the cache and starts XPAM. If anything cannot be read with the current key it
  stops and changes nothing, and XPAM starts again with the old key. Keep the backup it names
  until you have checked that accounts and sign-in work. Afterwards, randomly generated JIT
  account names (naming "random, fixed per user") are different from before.
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
| `xpamctl rotate-secret-key` | replace SECRET_KEY and re-encrypt all stored secrets (see section 4) |
| `xpamctl fetch-applet-files` | put the Windows publishing host installers on this server (see section 8) |
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
- `/download/` serves only files on this server; a missing file is "not found". Upstream fetched
  missing files from jumpserver.org instead. To allow that again, set `DOWNLOAD_FALLBACK=1` in
  `config.txt` and run `xpamctl restart`.
- Website assets opened in the remote browser check the site's certificate (Website asset →
  "Verify certificate"). It is on for new assets and off for assets created before 5.1.11, so
  internal sites with self-signed certificates keep working; switch it on for every site with a
  proper certificate. A site whose certificate fails is not shown and the user sees why.
- Certificates of LDAP, CAS, SMS and Exchange servers are checked (`VERIFY_EXTERNAL_SSL=true`;
  servers installed before 5.1.11 have `false` in `config.txt`). For a directory with an internal
  CA, upload the CA certificate in the LDAP settings rather than switching the check off.
- Approval channel webhooks (Teams, Slack) must be public internet addresses; internal addresses
  are refused.
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

The host also downloads the applet runtime (`Tinker_Installer_v0.3.0.exe` and
`jumpserver-tinker-python-3.11.11-win64.zip`). Put them on this server before adding the host:

```bash
xpamctl fetch-applet-files
```

Every file is checked against `scripts/applet-files.sha256` in the installer. Add the vendor's
SHA-256 values there, or run it once with `--trust-on-first-use` to record the checksums of the
files downloaded now (later downloads must match them). `APPLET_FILES_SOURCE=<url>` takes the
files from another server.

## 9. Web admin of FortiGate and Palo Alto (GUI)

FortiGate and PaloAlto assets have two protocols: **SSH** (command line) and **HTTP(s)** (the web
admin page, port 443; change the port on the asset when the admin page uses another one, e.g. 8443).
In the workspace, connect to the device and choose **HTTP(s) → Remote browser**: the admin page
opens signed in with the chosen account (or the user's just-in-time account), the password never
reaches the user's computer, and the session is recorded like a remote desktop.

- The sign-in fields and certificate checking are settings of the platform's HTTP(s) protocol
  (Assets → Platforms → FortiGate → Protocols → HTTP(s) → settings). Certificate checking is off by
  default because devices ship with a self-signed certificate; switch it on when the devices have
  a trusted certificate.
- Juniper (J-Web), Huawei and H3C: their platforms offer HTTP(s) — add it to the device (asset →
  Protocols → +); it is not added to every switch and router. The Remote browser finds the login form
  by itself; set the field selectors in the platform's HTTP(s) settings only for unusual pages.
- Other devices with a web admin page (e.g. Cisco Firepower device manager): add HTTP(s) to their
  platform. Cisco ASA has no web admin page (ASDM is a Java program) and stays command line only.
- Just-in-time accounts get the platform's role (read-only, operator, administrator or a custom
  profile), which applies to the web admin page as well as to SSH.
- The device must be reachable from the XPAM server; devices behind a gateway (jump host) are not
  supported for web admin sessions.

## 10. Just-in-time accounts

Instead of sharing a standing account on a server, XPAM can create an account for the user when it
is needed and remove it again. Set it up under **PAM → Just-in-time accounts**.

**1. Create a policy** (Policies → Create):

| Setting | Choices |
|---|---|
| Account lifetime | **Per connection**: created when the user connects, removed about a minute after the session ends. **While access is granted**: created as soon as a permission gives the user the asset under this policy, removed when the permission ends, is deleted, or no longer includes the user or the asset. **Approved time window**: for approved access requests; the account exists from the start to the end of the approved time. |
| Account name | **Same as XPAM username** (with an optional prefix, e.g. `xpam-sajjad`), **Specific name** (one shared name, e.g. `ops`), **Random, fixed per user**, **Random per session** (per connection only). Names are made valid for Linux and Windows: lower case, at most 20 characters. |
| Rights | Normal user, or administrator (Linux: sudo for all commands; Windows: member of Administrators). |
| Linux / Windows | Shell and extra groups (Linux), local groups (Windows; Remote Desktop Users is always added). |
| Removal | Delete the home folder / profile with the account, or keep it as `<home>.bak` (Linux). |

**2. Say who and where it is for** (in the policy, section *Applies to*). Nothing is linked by hand:

| Setting | Meaning |
|---|---|
| Applies to | **Asset permissions and approved requests**, **Approved access requests only**, or **Only permissions I link to it** (the old manual way). |
| Who | All users, chosen users, or users by attribute, e.g. *User groups* = `Linux-Admins`. |
| Where | All assets, chosen assets, or assets by attribute, e.g. *Node* = `/Production/Linux` or *Platform* = `Windows`. |
| Priority | 1-100. When several policies match the same user and asset, the lowest value wins. |

Example with three policies:

| Policy | Priority | Who | Where | Lifetime |
|---|---|---|---|---|
| Linux admins | 10 | group Linux-Admins | node /Production/Linux | while granted, sudo |
| Contractors | 20 | group Contractors | all assets | per connection, no sudo |
| Default | 100 | all users | all assets | approved requests only, per connection |

A user who has a permission (or an approved request) for an asset gets a just-in-time account from
the first policy that matches. Linux/Unix and Windows assets whose platform allows account push
are supported; other assets are skipped.

**Which policy applies?** The tab with that name shows, for a user and assets or nodes, which policy
applies and why (or why none does), either with the user's current permissions or as if an access
request were approved now.

**Access requests.** On the approval screen the approver sees *Just-in-time account*:
**Automatic (policy rules)** (default; the screen lists which policy each requested asset gets),
**No just-in-time account**, or a specific policy. After approval nothing else has to be done.

**One permission differently.** On an asset permission you can still choose a policy (it then wins
over the rules) or turn on *No just-in-time account*.

**3. Connect.** Users choose **Just-in-time account** in the workspace connect dialog. The first
connection takes a few seconds longer while the account is created. From an SSH client use
`ssh <user>#@JIT#<asset>@<xpam-server> -p 2222`.

**Live accounts** lists the accounts that exist right now (with *Remove now*); **History** keeps the
removed ones. A background check every five minutes creates missing accounts and removes leftovers,
for example after a server was offline during a removal.

**Quick start (5.1.4).** PAM → Just-in-time accounts → **Rules → Create** opens a wizard: pick a
template, choose **who** and **which servers**, choose **Instant**, **An approver says yes** or
**Two approvers say yes**, and the longest time. Done. *Advanced form* (or *Edit*) shows every setting.
**Approval channels** (button on the Rules tab) sends approval requests to Microsoft Teams (Workflows
webhook), Slack (incoming webhook) or Telegram (bot token + chat ID); approvers open the request with
the button, sign in and approve. Users of a rule with *Ask for MFA* cannot switch their MFA off.

**Approvals (5.1.5).** A rule can name its own approvers (*Who approves?* in the wizard, *Approvers*
in the full form); otherwise Tickets → Flow setup decides. Requests for assets of several rules are
approved by each rule's approvers in turn. Approvers see waiting requests on the workspace **Access**
page (with reason and warnings) and approve or reject there, from the e-mail, or from Teams/Slack/
Telegram. **Approval settings** sets reminders, escalation to the administrators and when unanswered
requests close. Nobody can approve their own request.

**4. Zero standing privilege (5.1.3).** Turn on *Just-in-time account only* in a policy and the users
it covers see no shared or personal accounts on its assets any more, only the just-in-time account.
Nobody keeps standing access.

- **Self-service.** Users open **Access** (key icon, top left of the workspace), search the assets a
  policy lets them request, choose 1, 2, 4 or 8 hours, give a reason and send. *My access* shows
  the time left with **Connect**, **Extend** and **End now**; pending requests can be cancelled.
- **Approve automatically.** A policy can approve requests by itself up to a number of hours and
  only at chosen times (for example Mon–Fri 08:00–18:00). Longer or out-of-hours requests wait for
  an approver. Every approval, automatic or not, is kept on the request.
- **Two approvers.** A policy can ask for a second person to approve (four-eyes); the first approver
  cannot approve twice. With only one possible approver the request says so.
- **Ending on time.** Users get a message (and a workspace notice with *Extend 1 h*) shortly before
  the end; at the end open sessions are stopped and the accounts removed within a minute.
- **MFA when connecting.** A policy can ask for MFA before its account is used in the web workspace
  (users need MFA set up in their profile). SSH clients use XPAM's own sign-in MFA.
- **Command filter.** Choose command groups in the policy; XPAM keeps a matching rule under
  Command filters ("JIT · policy name") that only applies to that policy's just-in-time sessions.
- **SSH key.** On Linux/Unix a policy can create the account with a new SSH key instead of a password.

**Overview** (first tab) shows the zero-standing score (assets reached only just-in-time), live
accounts, failures, waiting and automatically approved requests, and the permissions that still
give standing accounts. **Convert to JIT** takes the standing accounts out of such a permission;
its users keep access through the matching policy (the removed accounts are noted in the comment).
Every account has an **access trail**: request, approval, creation, sessions with command counts,
removal. Live and history lists can be exported.

**Targets.**

| Target | How |
|---|---|
| Linux/Unix, Windows | push and remove automations (the platform must allow account push); Linux needs SSH, Windows WinRM (5985) |
| MySQL, MariaDB, PostgreSQL, SQL Server, Oracle | a login with *Read only*, *Read and write*, *Administrator* or custom SQL rights, created and dropped with the database's privileged account; its sessions are ended on removal. PostgreSQL logins also expire by themselves (VALID UNTIL) |
| Network devices (Cisco, Huawei, H3C, any SSH device) | the policy's commands to create and remove the account, run with the device's privileged account. Placeholders `{username}`, `{password}`, `{login_password}` |

What the target needs:

- An account in XPAM marked *Privileged* that may create users: on Linux `root` or a sudo-capable
  account; on Windows a local administrator; on databases e.g. `root`, `postgres`, `sa`, `system`;
  on devices an account that may enter configuration mode.
- The just-in-time account is never offered to other users, also not through "All accounts".
- Databases and devices behind a gateway are not supported yet.
- The desktop client shows the just-in-time account from client version 5.1.0 on; the Access page
  is part of the web workspace.

## 11. High availability (two servers and a witness)

Two XPAM servers run as **primary** and **standby**. The standby has a live copy of the database
(synchronous streaming replication, so no committed change is lost) and of the recordings and files
(copied every minute). If the primary fails, the standby takes over by itself in about 30 seconds of
database time plus the time XPAM needs to start (one to two minutes). A small third machine, the
**witness**, votes: a server cut off from the other two can never stay primary (no "split brain").

**What you need**

| | |
|---|---|
| Two XPAM servers | same size, same XPAM version, same network (low latency), fixed IPv4 addresses |
| A witness | any small Linux machine with Docker (1 vCPU, 512 MB), ideally in another rack or room |
| A load balancer or DNS | sends users to the server whose health URL answers: `GET https://<server>/api/health/` → 200 on the primary only (the standby's services are stopped). Forward 443, 80, 2222 and 5001 to both servers; no sticky sessions needed |
| Between the servers | TCP 5432, 8008, 2379, 2380, 6379 and 22 (file copy); witness: 2379, 2380 from both servers |
| On both servers | `rsync`, `openssh`, `openssl`, `curl`, `iptables` (`dnf install -y rsync openssh-clients openssl curl iptables-nft`) |

XPAM limits the replication ports to the other server and the witness by itself (the ports are
published by Docker, which bypasses firewalld). Replication and the vote use TLS with certificates
made for the three addresses.

**Set it up**

1. Install the same XPAM version on the second server (`xpamctl install`), nothing else.
2. On the current XPAM server (it becomes the primary):

   ```bash
   xpamctl ha init <this-server-ip> <second-server-ip> <witness-ip>
   ```

   It prepares two bundles in `/opt/xpam/config/ha/` and waits for the witness.
3. On the witness: copy `xpam-ha-witness.tgz` there (it holds only the cluster certificates) and run

   ```bash
   mkdir xpam-witness && tar xzf xpam-ha-witness.tgz -C xpam-witness && ./xpam-witness/witness.sh
   ```

   The first server then backs up, switches its database (XPAM is offline for a few minutes) and
   starts the agent (`systemctl status xpam-ha`).
4. On the second server: copy `xpam-ha-join.tgz` there (it holds XPAM's secrets: delete it afterwards)
   and run `xpamctl ha join xpam-ha-join.tgz`. It copies the database and becomes the standby.

System settings → **High availability** in the console (and `xpamctl ha status` on a server) shows both
servers, their roles, the replication lag, the last file copy and whether the witness answers.

**When something fails**

| Event | What happens |
|---|---|
| The primary fails | the standby becomes primary (database ~30 s), its agent starts XPAM; the load balancer follows the health URL. Users sign in again |
| The failed server comes back | it rejoins as standby by itself (pg_rewind) and receives what changed meanwhile |
| The servers lose each other | the one that still reaches the witness is (or becomes) primary; the other stops XPAM |
| The witness fails | nothing changes; the two servers still form a majority. Bring it back soon |
| The standby fails right after it rejoined (not yet in sync) | no automatic failover (it could lose the last changes): decide, then `xpamctl ha failover --force` on the server to keep |

**Planned maintenance**: `xpamctl ha switchover` (or "Switch to the other server" in the console)
moves the primary to the standby in about a minute.

**Upgrading**: upgrade the **standby first**, then the primary, with the usual `xpamctl upgrade` on
each. On the standby it only updates the images; on the primary it pauses automatic failover, migrates
the database and starts XPAM.

Other commands: `xpamctl ha role` (this server's role), `xpamctl ha pause on|off` (maintenance mode:
no automatic failover).

## 12. If something goes wrong

| Symptom | Cause and fix |
|---|---|
| "This server is not allowed to download the XPAM images" | not signed in, or the token lacks `read:packages`: `docker login ghcr.io -u Sajjad-alaa`, then `xpamctl install` again |
| `download failed from ghcr.io/...` | no connection to `ghcr.io` (HTTPS, port 443), or the disk is full: the two lines under the message give the reason |
| `XPAM image not found on this server` | `XPAM_IMAGE_REGISTRY=local` is set in `config.txt` but the images were never built or loaded here: remove that line to download them |
| A service stays `unhealthy` | `xpamctl tail <service>` shows why; `core` takes the longest on first start |
| Sign-in is refused with "Configuration file has problems" | a reverse proxy in front of XPAM terminates HTTPS: set `USE_LB=0` in `config.txt` and let the proxy send `X-Forwarded-Proto` (see step 4), then `xpamctl restart` |
| "This part of XPAM is temporarily unavailable" | the container behind that path is stopped or restarting: `xpamctl status`, then `xpamctl start`. It answers again about ten seconds after the container is healthy |
| Port already in use | change `HTTP_PORT` / `HTTPS_PORT` / `KOKO_SSH_PORT` in `config.txt`, then `xpamctl restart` |

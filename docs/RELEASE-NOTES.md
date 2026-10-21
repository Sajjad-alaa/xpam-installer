# XPAM release notes

## 5.1.16 — high availability

- **Two servers and a witness.** `xpamctl ha init` on the current server, a one-line script on a small
  witness machine and `xpamctl ha join` on the second server turn XPAM into a primary/standby cluster:
  PostgreSQL under Patroni with synchronous streaming replication over TLS (no committed change lost),
  leader election by a vote of both servers and the witness (no split brain), Redis following the
  primary, recordings and files copied to the standby every minute.
- **Automatic failover.** If the primary fails, the standby's database takes over in about 30 seconds
  and its agent starts XPAM; the load balancer (or DNS) follows the health URL, which answers on the
  primary only. A failed server rejoins as standby by itself.
- **Console:** System settings → High availability shows both servers, roles, replication lag, the
  last file copy and the witness, and switches the primary for maintenance.
- **Upgrades in a cluster:** standby first, then the primary (automatic failover is paused meanwhile).
- **Told and warned:** administrators are notified when XPAM moves to the other server; a console banner
  shows while protection is reduced (no standby in sync, witness down, recordings not copied).
- **Floating address** for sites without a load balancer (`xpamctl ha vip`), **server and witness
  replacement** (`join-bundle`, `witness-bundle`) and **back to one server** (`xpamctl ha disable`).
- **Only XPAM reaches the database.** In a cluster the other server can only replicate (password and
  cluster certificate, no XPAM account over the network), Patroni's API and Redis replication require
  the cluster certificate, the firewall is in place before Docker at every boot. A single server no
  longer publishes its database on the host (127.0.0.1:5432); set `POSTGRESQL_EXPOSE_PORT` to allow it.
- Fixed: Redis did not start again after a container restart or server reboot (since 5.1.10).

## 5.1.15 — faster asset management

- **Add many.** Paste a list of addresses (or "name address" lines), pick one platform, node and account,
  and XPAM creates them all (Assets → Add many). Lines that fail are listed with the reason; the licence
  limit is checked before anything is created.
- **Detect platform** (network devices: select them → More → Detect platform). XPAM signs in with the
  device's privileged account, recognises FortiGate, Palo Alto, Cisco IOS/ASA/NX-OS, Juniper, Huawei or
  H3C and moves the device to that platform (adding its web admin protocol where there is one).
- **Needs attention** (Assets → Needs attention): unreachable assets, assets without a privileged account,
  failed account checks and admin passwords unchanged for 90 days — each with what to do and the assets.

## 5.1.14 — smoother setup of JIT rules, web assets and devices

- **JIT wizard checks the chosen assets.** Right after you pick servers, databases or devices it shows
  how many can get just-in-time accounts and, for the others, what to fix (e.g. "Add a privileged
  account on the asset", "Account push is turned off in the platform") with the asset names — no more
  finding out when a user's connection fails.
- **Web assets without selectors.** The sign-in fields are optional and empty by default: the Remote
  browser finds the login form and recognises a successful sign-in by itself. Fill them only for
  unusual sites. An address typed without `https://` gets it (and port 443).
- **Devices:** the form explains that the device's admin account must be marked "Privileged" (used for
  account push, discovery and just-in-time accounts, and as the enable password).
- **Firewall GUIs:** Juniper (J-Web), Huawei and H3C platforms now offer the HTTP(s) web admin protocol
  next to SSH — add it to a device with one click (it is not added to every switch and router). FortiGate
  and Palo Alto have it on every device. Cisco ASA stays command line only (ASDM is a Java program).

## 5.1.13 — smoother just-in-time access

- **Extensions lengthen the same access.** "Extend" counts the extra hours from the current end (it
  was refused as "too long" while time was left), keeps the original reason, and once approved the
  existing access simply ends later — no second card, the JIT account stays. A card shows when an
  extension is waiting; one extension can wait at a time.
- **No pointless requests.** Asking again for assets you already have (or that are already waiting
  for approval) is refused with the reason and the hint to extend.
- **You are told the decision.** The workspace shows a notice when your request is approved,
  rejected or closed automatically (with the approver's note); a request closed because nobody
  approved it in time is also mailed to you.
- **End now is precise.** It removes only the accounts of that access (another access keeps its
  accounts) and cancels a waiting extension.
- PostgreSQL just-in-time logins follow an extension (their built-in expiry moves with the access).
- Fixed: XPAM's own ticket notes (approval route) were shown to requesters as an approver's comment.

## 5.1.12 — FortiGate and Palo Alto web admin (GUI)

- **Device web admin in the Remote browser.** FortiGate and PaloAlto assets get an HTTP(s) protocol
  next to SSH. Choosing it opens the device's admin page signed in with the stored account or the
  user's just-in-time account (with its read-only/operator/administrator role); the password stays
  on the server and the session is recorded. A wrong password or an untrusted certificate (when
  certificate checking is on) ends the session with the reason.
- Any device platform can get the HTTP(s) protocol (Juniper, Huawei, H3C, Cisco web UIs); the port
  of the admin page is set on the asset.
- Approval channel webhooks (Teams, Slack) must be public internet addresses (from the 5.1.11 audit
  follow-up).

## 5.1.11 — key rotation, certificate checks, local downloads only

- **`xpamctl rotate-secret-key`** replaces SECRET_KEY and re-encrypts every stored secret (account
  secrets and their history, MFA secrets, e-mail and phone, keys, tokens, storage settings,
  encrypted settings) in one database transaction, and recomputes the e-mail sign-in lookups. It
  backs up first, refuses when the current key cannot read the data, and verifies a sample with the
  new key before saving. Recommended once for servers installed before 5.1.10 (their key came from
  the hardware ID). Plan a few minutes of downtime; everybody signs in again.
- **Website assets: "Verify certificate".** The remote browser now checks the site's certificate
  when the option is on (the default for new assets; existing assets keep the old behaviour until
  you switch it on). A failing certificate ends the session with a clear message, and users cannot
  click through certificate warnings.
- **No download fallback to jumpserver.org.** `/download/` serves only local files (opt back in
  with `DOWNLOAD_FALLBACK=1`). `xpamctl fetch-applet-files` puts the Windows publishing host
  installers on the server, checksum-checked.
- Approval channel webhooks (Teams, Slack) are refused when they point at a private, loopback or
  link-local address, when saved and on every send (an admin could probe internal services through
  the test button).
- New installs check the certificates of LDAP, CAS, SMS and Exchange servers
  (`VERIFY_EXTERNAL_SSL=true`); existing servers keep their setting.
- Images are rebuilt with current operating-system security updates.

## 5.1.10 — security hardening

A full review by ten reviewers (one per service, plus image, secret and endpoint scans) found
84 issues; the important ones are fixed. Highlights:

**Desktop client and workspace**
- `jms2://` links can no longer run commands on the user's computer (every field is validated; no
  shell characters can reach a terminal). Connection-file names cannot leave the config folder.
- The client pins the XPAM server certificate on first use (a self-signed one keeps working; a
  changed certificate needs the user's confirmation) instead of accepting any certificate.
- Terminals only accept typed commands from the page that embeds them; the access token is no longer
  saved in the browser storage; offline-recording files are served to the app only.
- WebLite does not start as a free browser when launched without a connection.

**Core**
- Just-in-time accounts never take over or delete an account that already exists on the target
  (Linux/Windows user, database login, device account); "john.doe" and "john-doe" never share one.
- A rule for "all users" only reaches members of its organization; zero standing privilege fails
  closed; per-connection accounts end within a minute when the user loses the permission.
- Job Center uses the same rules as connecting (no other user's JIT account, nothing under "JIT only").
- Approvals: four eyes on every path (never the requester, never the approver of an earlier step,
  also after escalation); approval channels need the system ticket-settings permission; webhook tests
  follow no redirects and return no response body; approver e-mail links last 1 hour; chat cards
  escape the requester's text; the step-up MFA check has an attempt limit.
- Commands/SQL in JIT rules can only be set by users allowed to view account secrets; device role
  and VDOM names are validated; account push keeps the role of an existing device account unless
  "Also change the role of existing accounts" is on; PAN-OS reverts XPAM's half-done changes; Junos
  uses a private candidate.
- New installs: SECRET_KEY and other secrets are random (they were derived from the hardware ID).
- ansible-core 2.16.19, aiohttp 3.14.4.

**Console**
- Fixed a stored XSS in toast messages; AI answers never load images (data leak by planted text).

**SSH / remote desktop / web proxy**
- The web proxy (port 5001) reaches only the asset, its allowed sites and public hosts — never XPAM's
  containers or other internal servers.
- Share links and removing participants are for the session owner only; monitors cannot send
  input; Lion's "end session" really ends it; the file manager checks its owner; connect tickets
  cannot create new tickets.

**Remote browser**
- New windows (and developer tools) start paused until XPAM has decided: developer tools are closed
  before they appear and no request passes unguarded. Auto-fill only on the asset's own site; the
  password stays hidden during a captcha; file dialogs are off; a session whose guard stops is
  closed; a reaper ends dead or expired sessions; it runs on its own network, isolated from XPAM's
  containers, with a memory limit (`BROWSER_MEM_LIMIT`, default 3g).

**Web database client**
- Asset address and database name can no longer inject JDBC options; masking rules with `*` work;
  command rules match regardless of comments and honour their case setting; kill/lock tasks keep
  working after an error; sessions that never connect are closed; expiry uses the real time zone;
  BouncyCastle, commons-lang3 and Guava updated.

**AI assistant**
- At most 2 active runs per user; the store prunes old contexts and events; `free` is only
  auto-approved with flags (it disconnects users on Huawei/H3C).

**Installer**
- XPAM images are never pulled from Docker Hub (`pull_policy: never`); each service gets only the
  secrets it uses; database dumps are private (700/600); no password appears in the process list;
  the gateway mounts only what it serves, read-only; Redis evicts only expiring keys; upgrade image
  cleanup fixed; uninstall keeps the backups; restore asks before replacing the database; system
  packages in images are refreshed daily at build time.

## 5.1.9

**Network devices and firewalls: account push, change secret, removal, discovery and just-in-time
accounts with their role** — built in for FortiGate, Palo Alto, Cisco IOS / IOS-XE, Cisco ASA, Cisco
NX-OS, Juniper, Huawei and H3C (no commands to write).

| | What XPAM does on the device |
|---|---|
| Account push | Creates the account (or updates its password and role) |
| Change secret | Sets the new password (specific or random; random passwords never contain "?") |
| Remove | Deletes the account ("Sync deletion" in discovered accounts); never the account XPAM signs in with |
| Discovery | Lists the local accounts with their role; a changed role (for example read only → super_admin) is reported as a risk |
| Just-in-time | Creates the temporary account with the rule's role and removes it afterwards, also through gateways; never takes over an account that already exists |

Roles (choose per platform for push, per JIT rule for just-in-time accounts):

| Vendor | Read only | Operator | Administrator | Custom |
|---|---|---|---|---|
| FortiGate | profile `xpam_read_only` (created) | `prof_admin` | `super_admin` | admin profile name |
| Palo Alto | `superreader` | `deviceadmin` | `superuser` | admin role profile |
| Cisco IOS / IOS-XE | privilege 1 | privilege 7 | privilege 15 | privilege 0-15 |
| Cisco ASA | privilege 5 | privilege 10 | privilege 15 | privilege 0-15 |
| Cisco NX-OS | `network-operator` | `network-operator` | `network-admin` | role name |
| Juniper | `read-only` | `operator` | `super-user` | login class |
| Huawei | level 1 | level 2 | level 15 | level 0-15 |
| H3C | `network-operator` | `level-10` | `network-admin` | user role |

- New platforms **FortiGate**, **PaloAlto**, **Cisco-ASA** (firewalls), **Cisco-NXOS** (switch) and
  **Juniper** (router); the built-in **Cisco**, **Huawei** and **H3C** platforms switch to the new
  methods (an "SSH custom commands" method with commands already filled in is kept).
- Platform settings of the new methods: vendor (or automatic recognition), role, Palo Alto commit
  (default: only XPAM's own change, `commit partial admin`), FortiGate VDOM.
- Changes are saved on the device (`write memory`, `copy running-config startup-config`, `save`,
  Junos/PAN-OS commit).
- JIT rules: new **Role on the device**; the rule wizard sets read only (Developers), operator
  (Operations) or administrator (Administrators). The command templates remain for other SSH devices.
- Passwords with a space, `?`, quotes, backslash or backtick are refused with a clear message (device
  command lines treat them specially).

## 5.1.8

**Remote browser: automatic sign-in that covers every case.** While XPAM signs in, the site is
hidden behind a "Signing in…" screen and the user's key presses are ignored, so the login form is
never seen or used. When the sign-in works the site appears (about 2–3 seconds); when it fails
the user is told why and the session ends a few seconds later.

| Situation | What happens |
|---|---|
| Normal login form (also inside frames and web components, with or without selectors) | Filled in and sent |
| Two-step login (user name page, then password page) | Both steps are done |
| HTTP authentication (Basic, Digest, NTLM) | Answered by XPAM, no browser prompt |
| Login page built by JavaScript (single-page apps) | Waits for the form, detects the result |
| MFA code or captcha | The account is filled in, the screen is handed to the user (3 minutes) |
| Wrong password (form back, 401/403, error message) | "Automatic sign-in failed", session ends |
| Account locked / disabled | "Account locked", session ends |
| Website asks for a new password | "New password required", session ends |
| Website down or unknown | Three tries, then "Website not reachable", session ends |
| Website signs the account out later | Signed in again automatically (at most 3 times in 10 minutes) |
| A page fails to load later | XPAM's own "Page not available" page with Try again (Chromium's error page would show the address) |
| No login page at all | The site is shown after a few seconds |

- The asset platform's *success selector* and *interactive selector* are used when set; they are no
  longer required.
- The password stays in the browser service's memory until the session ends (needed to sign in
  again and for HTTP authentication); it is never written to disk or logs.

## 5.1.7

- **Web assets open in any browser** (not only in the desktop client) with the new connect method
  **Remote browser**: the site runs in a secure, isolated browser on the server (new service
  `browser`) and is shown in the workspace like a remote desktop.
  - The site address is never shown: no address bar, just the page; a small toolbar has Back,
    Forward and **Reload**.
  - Sign-in is filled in on the server from the asset's auto-login settings (selectors or script);
    the password never reaches the user's computer.
  - Only the asset's own site and its *Allowed sites* can be opened; other pages are blocked.
  - Developer tools, downloads, printing and saved passwords are off; every session gets a fresh
    browser profile that is deleted at the end; sessions are recorded like remote desktops.
- Clicking a web asset opens it right away with Remote browser, in the web workspace and in the client.
- The client's built-in browser no longer shows the site address either.
- New settings in `config.txt`: `BROWSER_KEY` (generated), `BROWSER_MAX_SESSIONS` (default 10),
  `BROWSER_MAX_HOURS` (default 12), `BROWSER_ENABLED=0` to switch the service off.

## 5.1.6

- **No account to choose for just-in-time access**: in the console request form, servers covered by
  a just-in-time rule show "Just-in-time account — created for you and removed afterwards" instead of
  the account chooser (an existing account can still be picked unless the rule is "JIT only"; with
  mixed servers the chooser appears only for the others). The approval screen shows the just-in-time
  account instead of asking the approver to pick accounts.
- Requests store the account as `@JIT` ("Just-in-time account"); older requests keep working.
- The request form no longer stays empty for users without a selected organization.

## 5.1.5

Approvals, done properly:

- **Approvers per rule**: a just-in-time rule can name its own approvers (e.g. the database team);
  rules without approvers use Tickets → Flow setup. A request for assets of several rules goes to
  each rule's approvers in turn. Four-eyes works inside a team (the first approver cannot approve twice).
- **Nobody approves their own request** — in every approval flow; without another approver the
  administrators approve.
- **Reminders, escalation and expiry**: approvers are reminded after 30 min, the administrators are
  added after 2 h, and requests nobody decides within 24 h (or whose time is already over) are
  closed and the requester is told. All configurable under Rules → Approval settings (0 = off).
- **Approvals inbox in the workspace** (Access page): requests waiting for you with the reason and
  warnings (long access, administrator rights, outside working hours, first time on these assets);
  approve with one click, reject with a reason the requester sees. A workspace notice tells approvers
  about new requests.
- The wizard asks *Who approves?* and orders rules automatically (specific rules before broad ones).

## 5.1.4

- **Simple setup**: *New just-in-time rule* is a 4-question wizard (who, where, how they get in,
  how long) with templates *Developers*, *Operations* and *Administrators*; safe defaults for the
  rest, the full form stays under *Advanced form* / *Edit*. The page has three tabs: Overview,
  Rules, Accounts; *Test* on a rule shows which rule applies to a user.
- **Approve from chat**: approval requests also go to Microsoft Teams, Slack and Telegram with an
  *Open approval* button (Rules → *Approval channels*, with *Send test message*). Chat links always
  need a sign-in; e-mail links can optionally approve without one. Link lifetime is configurable.
- **MFA cannot be switched off** by users of a rule that asks for MFA; they set it up at their next
  sign-in.
- Rules start with nobody selected; a warning shows when a rule covers all users or all assets.
- Oracle just-in-time logins tested.

## 5.1.3

Zero standing privilege and just-in-time access, end to end:

- **Just-in-time account only**: a policy can hide all standing accounts from the users it covers.
- **Self-service Access page** in the workspace: request time-boxed access (1–8 h presets, reason),
  see the time left, connect, extend or end access early, cancel pending requests.
- **Automatic approval** by policy (up to N hours, at chosen times) and **two approvers**
  (four-eyes) for sensitive policies.
- **On-time ending**: warning message and workspace notice before the end; open sessions are ended
  and accounts removed when the access ends.
- **Security**: MFA before the just-in-time account is used, command filters for just-in-time
  sessions, SSH key credentials on Linux/Unix.
- **More targets**: MySQL/MariaDB, PostgreSQL, SQL Server and Oracle logins with chosen rights;
  network devices through command templates.
- **Overview dashboard**: zero-standing score, live accounts, approvals, standing access with
  one-click **Convert to JIT**; **access trail** per account; export of live and removed accounts.
- The approval history shows the chosen just-in-time policy by name; the Oracle driver is now in
  the core image.

## 5.1.2

- **Just-in-time policies apply by rules.** Each policy says who (users, user groups or user
  attributes) and where (assets, nodes, platforms or other asset attributes) it is for, plus a
  priority. XPAM picks the matching policy by itself for asset permissions and approved access
  requests, so several policies no longer have to be linked to permissions by hand. The old
  "only permissions I link to it" way is still available.
- **Approvers choose the just-in-time account on the request**: automatic (the screen shows which
  policy each asset gets), none, or a specific policy.
- New **Which policy applies?** tab: shows for a user and assets which policy applies and why.
- Asset permissions can turn off just-in-time accounts ("No just-in-time account").
- Upgrading from 5.1.1: a policy that applied to approved requests becomes "Approved access
  requests only" for all users and assets; other policies keep working with their linked
  permissions.

## 5.1.1

- **Approved access requests use just-in-time accounts automatically.** A policy can be set to
  "Apply automatically to approved access requests" (any account lifetime). The permission created
  when a request is approved gets the policy right away, so nobody has to edit it by hand. Turning
  the setting on also covers requests approved earlier that are still valid.

## 5.1.0

**Just-in-time accounts.** XPAM can create an account on a Linux or Windows server for the user when
it is needed and remove it again, instead of everyone sharing a standing account.

- Three account lifetimes: per connection, while access is granted, and approved time window
  (for approved access requests).
- Four naming options: same as the XPAM username (with optional prefix), a specific shared name,
  random but fixed per user, random per session.
- Normal or administrator rights per policy (Linux sudo, Windows Administrators).
- Console: PAM → Just-in-time accounts (policies, live accounts with "Remove now", history), and a
  policy field on asset permissions. Workspace and SSH clients offer "Just-in-time account".
- Accounts are removed after the session, when the permission ends, when a user leaves the
  permission or is deleted, and by a check every five minutes for anything left behind.

Other changes:

- Removing an account from a Linux server now also removes its sudo rule, can delete the home folder,
  ends the account's processes when asked, and never fails because an earlier `<home>.bak` exists.
  Removing a Windows account can sign it out and delete its profile.
- Leaving the admin console for the workspace in the same browser tab no longer signs the user out.

Upgrade from 5.0.0: `xpamctl upgrade`. 5.0.0 stays available: tag `xpam-v5.0.0`, branch `xpam-5.0`,
images `xpam/*:v5.0.0`.

## 5.0.0

First XPAM release.

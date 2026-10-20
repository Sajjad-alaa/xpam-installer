# XPAM release notes

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

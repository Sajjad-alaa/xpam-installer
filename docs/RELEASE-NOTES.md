# XPAM release notes

## 5.1.8

- **Remote browser: a failed automatic sign-in closes the session.** When the website does not
  accept the stored account (for example the password was changed on the site), the user sees
  "Automatic sign-in failed — ask your administrator to update the account" and the session ends
  a few seconds later. The login page is never left open for someone to try other credentials.
  - How success is detected: the asset platform's *success selector* when it is set; otherwise the
    login form must be gone about 20 seconds after signing in.
  - If the platform has an *interactive selector* (MFA code, captcha) and it appears, the user has
    3 minutes to complete it before the session is closed.

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

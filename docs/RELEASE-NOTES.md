# XPAM release notes

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

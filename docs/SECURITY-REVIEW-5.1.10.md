# XPAM 5.1.10 security review — findings and status

Ten reviewers (core x2, console, workspace/Electron, SSH/remote desktop, browser service, web
database client, AI service, installer/gateway, black-box/images). [x] = fixed in 5.1.10.
Items still open are listed at the end with the reason.


## Installer (I)
- [x] I1 CRIT random_str from dmidecode → always random (new installs). LIVE SECRET_KEY rotation = ask owner
- [x] I2 HIGH compose pulls docker.io/xpam/* → pull_policy: never + xpamctl pull uses pull_images
- [x] I3 HIGH all secrets to koko/chen/kael env (config_safe deny-list) → allow-list
- [x] I4 MED db dumps world-readable → umask 077/chmod
- [x] I5 MED redis/db passwords in ps → redis conf file + REDISCLI_AUTH; backup env-file
- [x] I6 MED browser reaches all internal services → own network (+ Chromium blocks private addr subresources B10)
- [x] I7 MED gateway rw mount core data → ro subfolders, cert ro
- [x] I8 MED no mem/pids limits → browser limits (+ maybe others)
- [ ] I9 MED no rollback → retag :prev before pull
- [x] I10 MED clean_images never runs / grep substring
- [x] I-low: xpamctl "$@"; nec_port; set_env loop; "no" prompt; restore confirm; uninstall deletes backups; static.env rewrite; redis allkeys-lru→volatile-lru; download fallback (owner decision); dead code
- [x] port 5001 realm renamed XPAM; redis.port/minio bind 127.0.0.1

## Black-box (X)
- [x] Spring CVEs: not applicable (XsltView/SSE unused) → note; Boot 4 migration later
- [x] ansible-core 2.16.19, aiohttp 3.14.4 pinned (core.Dockerfile)
- [ ] libexpat → rebuild secureconnection (apt upgrade in Dockerfile)
- [ ] health endpoints detail (low), cookie flags jms_public_key (low), CSP (low), chen error path (low)

## Browser (B)
- [x] B1 CRIT DevTools allowed → setAutoAttach waitForDebuggerOnStart + close devtools before render; test F12/inspect
- [x] B2 HIGH re-login/autofill on allowed_urls hosts / any origin → only asset origin + login_path
- [x] B3 HIGH captcha: password filled then overlay removed → fill username only? (keep overlay over pw field)
- [x] B4 HIGH new windows race before Fetch.enable → waitForDebuggerOnStart
- [x] B5 HIGH --no-sandbox shared uid, file dialogs → AllowFileSelectionDialogs false, profile 0700, rm .vncpass
- [ ] B6 HIGH ignore_cert always true → default false? (per-asset option) — careful: internal self-signed assets common
- [x] B7 MED reaper thread for dead/expired sessions; release on guard failure
- [x] B8 MED CDP socket timeout desync
- [x] B9 MED wildcard *.com allowed
- [ ] B10 MED subresources to internal hosts → block private/service addrs (network seg I6 covers containers)
- [x] B11 MED --disable-dev-shm-usage + disk cache cap + mem_limit
- [x] B12-17 LOW finish() back button; notify replies leak; dead branch; hmac non-ascii; stale X lock; .vncpass

## Core auth/tickets (A)
- [x] A1 HIGH approval channels endpoint org perm writes global settings + TICKETS_DIRECT_APPROVE
- [x] A2 MED webhook SSRF (test/send) → safe target + no redirects + ok/failed only
- [x] A3 MED SLA escalation re-adds step-1 approver → exclude earlier processors; central check
- [x] A4 MED bound email tokens 24-168h → 1h for bound
- [x] A5 MED MFA lock ignores group perms; confirm 500 when no backend
- [x] A6 MED (=C-M2) JIT MFA skipped for component tokens
- [x] A7 LOW no rate limit on MFA confirm
- [x] A8 LOW slack/teams markdown injection
- [x] A9 LOW self-approval paths → central processor != applicant
- [x] A10 LOW JIT provisioned before token checks
- [x] A11 LOW SLA: close attribution, unordered [:500], notify w/o channel
- [ ] A12-13 license gates (owner decision?) ; A14 perf; dead code

## Core JIT/automations (C)
- [x] C-H1 HIGH JIT takes over/deletes pre-existing accounts (db cleanup DROP USER, posix adopt, device release)
- [x] C-H2 HIGH Job Center bypasses ZSP, run-as other users' JIT accounts
- [x] C-H3 HIGH cross-org self-service (users=all)
- [x] C-M1 name collisions john.doe/john-doe
- [x] C-M3 ZSP fails open when asset unsupported
- [x] C-M4 device CLI injection custom_role/vdom/username \n; {login_password} exfil
- [x] C-M5 network push demotes existing admins → keep role default for existing
- [x] C-M6 PAN revert partial / Junos configure private
- [x] C-M7 revocation gaps per-connection
- [ ] C-low: release race; token cap; custom cmds gateway/hostkey; platform name jinja; coverage disclosure; convert 500; perf; NX operator mapping; web_browser method w/o service; dead code

## Console lina (W)
- [x] W-H1 HIGH DOM XSS toPlainTextMessage innerHTML (message.js:76) → DOMParser
- [x] W-H2 (=A1) approval channels UI: show save/test only with system perm
- [x] W-M1 ticket approve sends @JIT even with apply_jit none → drop @JIT / require account
- [ ] W-low: wizard pick() reset; input-number null; policy list Test row; channels btn perms; route perm view_jitaccount; dashboard convert error; JITAccountTable catch; RequestAccountField stale responses; AssetPermission jit_policy+jit_disabled; AutomationParamsSetting el.type textarea; dead JITLive/History lists; console.logs in guards

## Koko/Lion (K)
- [x] K-H1 lion kill_session doesn't close tunnel → t.Close()
- [x] K-H2 webproxy open proxy (ALLOWED_HOSTS unread) → restrict to asset host + allowed_urls, block internal
- [x] K-H3 share links for any session (koko tty + lion share/delete) → owner + EnableShare check
- [x] K-M1 lion monitor can send input; writable share skips filters
- [ ] K-M2 (=B6) ignore_cert hard-coded
- [x] K-M3 connect tickets long-lived/reusable/query/empty token id
- [x] K-M4 elfinder sid ownership
- [ ] K-low: ssh forward defer; token expire before owner check, browser token expire earlier; width clamp; CORS internal origins; redis TLS CA; races; usql argv/PAGE; dead code

## Workspace/Electron (E)
- [x] E-C1 CRIT jms2:// command injection (launcher render without quoting/validation)
- [x] E-H2 postMessage CMD into terminals any origin + COOP header
- [x] E-H3 desktop trusts any TLS cert for server → only -202 / TOFU
- [x] E-M4 jms-asset protocol serves home dir with CORS *
- [x] E-M5 .rdp/.vnc name traversal
- [x] E-M6 batch JIT MFA prompts cancel each other
- [x] E-M7 bearerToken + dynamicPassword in localStorage
- [ ] E-low: toolbar i18n keys; WebProxySurface dead nav; AccessCenter selection; duplicate polling; WebLite standalone; dev window bypass

## AI kael (K2)
- [x] K2-H1 image exfil via markdown images in AI answers (lina MessageText + workspace) + img-src CSP
- [x] K2-H2 store deep copy / never pruned → DoS (big refactor; at least quotas + prune)
- [x] K2-M1 one user occupies 4 workers → per-user active run limit
- [ ] K2-M2 harness mutex held during codex start
- [x] K2-M3 `free` auto-approved (network devices) → flags only / non-unix off
- [ ] K2-low: GET treated as write; path escape sign; csrf cookie prefix; delete only hides; identity double call; runs as root; openapi unauth; dead code

## Webconnector chen (J)
- [x] J-C1 CRIT JDBC URL injection (address/db_name) → validate host/db in toJDBCUrl + force allowLoadLocalInfile=false etc; core hostname validation for DB assets
- [x] J-H2 masking wildcard never matches
- [x] J-H3 ACL bypass comments / case
- [x] J-H4 task stream dies on exception
- [x] J-H5 sessions without websocket never reaped; interceptor no expiry/lock check
- [ ] J-M6 UTC+8 hardcoded expiry; M7 XSS error dialog; M8 mssql trustServerCertificate; M9 key files /tmp; M10 exports not deleted; M11 pool DoS; M12 orphan sessions; M13 pool race; M14 deps bcprov/commons-lang3/guava/grpc
- [ ] J-low CSV injection; ThreadLocal db; perf; dead code
- [x] chen env: needs CORE_HOST BOOTSTRAP_TOKEN DOMAINS LOG_LEVEL TZ (blanking done)

## Open — decisions for the owner
- Live SECRET_KEY was derived from the hardware UUID (old installer). New installs are random; the
  live key needs a planned rotation with re-encryption of all stored secrets.
- Remote browser `ignore_cert` is always on (internal sites with self-signed certificates work); a
  per-asset "verify certificate" option would close the man-in-the-middle risk for public sites.
- `/download/` falls back to static.jumpserver.org for files not hosted locally (applet host setup).
- JIT self-service / approvals do not check the ticket licence; the trial installation date
  fails open on errors.
- Web database client: Spring Framework 6.2.19 (open-source line ended); the two 2026 CVEs need
  XsltView / SSE fragments, which chen does not use; plan the Spring Boot 4 migration.
- A Content-Security-Policy beyond frame-ancestors (needs testing of every page).

## Tests run for 5.1.10
- Network device drivers 120/120 and end-to-end 80/80 (emulator, fresh database, all migrations).
- JIT/approval hardening 13/13 on an isolated stack (real Linux host, PostgreSQL, two organizations).
- Remote browser: 22 sign-in scenarios + developer tools by keyboard, popups, captcha lock, other-site
  forms, wildcard, crash reaping.
- Go unit tests (koko webproxy/lion/auth, kael store/policy/service), WebLite 11/11, desktop launcher
  validation 11/11, TypeScript type check, lint on console and workspace.

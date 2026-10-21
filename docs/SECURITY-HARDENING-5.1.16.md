# XPAM 5.1.16: closing the five residual attack vectors

This report covers the five weak points found after the database lockdown. For each one it gives the
risk, the fix, the files that changed, and how the fix was tested. The last section lists what an
administrator now does differently.

**Starting point.** The lockdown had already closed the network side:

- The database, Patroni's API and Redis replication between the servers all need TLS plus the
  cluster certificate.
- The firewall is in place before Docker starts.
- A single server no longer publishes PostgreSQL.

The five items below are what was left: what someone could do once they had a foothold, meaning a
compromised component, a stolen file or a compromised witness.

| # | Vector | Severity before | Status |
|---|---|---|---|
| 1 | Internet-facing components hold secrets they don't need | HIGH (corrected: MEDIUM, see below) | Fixed |
| 2 | A copy of the join bundle or the CA key gives the whole cluster | MEDIUM | Fixed |
| 3 | One shared Redis password for every component | MEDIUM | Fixed |
| 4 | The witness shares the servers' certificate and can write the vote store | LOW–MEDIUM | Fixed |
| 5 | Cluster certificates cannot be replaced | LOW | Fixed |

---

## 1. Components got secrets they don't use

**Risk.** These services all read `config-safe.txt`:

- the SSH/RDP/web-proxy service (port 2222 and the browser sessions);
- the database web client;
- the AI service;
- the other helpers.

That file was produced from `config.txt` by removing a fixed list of five keys: a deny-list. Two
consequences:

- **The HA passwords reached these services.** In HA mode that means the replication, Patroni API
  and rewind passwords.
- **Any secret added to `config.txt` later would reach every component**, because a deny-list lets
  through anything not on it.

> **Correction to the first assessment.** I first said these services held `SECRET_KEY` and the Redis
> password. Each compose file already overrode those with empty values, so they were not exposed. The
> real problems were the HA passwords and the deny-list design. Severity: MEDIUM rather than HIGH.

**Fix: an allow-list.**

- `config-safe.txt` now drops every setting whose **name looks like a secret**. That covers anything
  containing `PASSWORD`, `PASSWD`, `SECRET`, `TOKEN`, `PASSPHRASE`, `PRIVATE` or `CREDENTIAL`, any
  `*_KEY` setting, and every `HA_*`, `DB_*`, `VAULT_*`, `SSH_CA_*`, `OPENBAO_*` and `REDIS_KOKO_*`
  setting.
- Each compose file passes **only the secrets its service uses, by name**:

| Service | Secrets it receives |
|---|---|
| SSH/RDP (koko/lion) | `BOOTSTRAP_TOKEN`, `BROWSER_KEY`, its own Redis account (see #3) |
| Database web client (chen) | `BOOTSTRAP_TOKEN` |
| AI (kael) | `BOOTSTRAP_TOKEN`, `CHAT_AI_API_KEY`, the platform delegation settings |
| nec, magnus, video-worker, xrdp, razor | `BOOTSTRAP_TOKEN` |

A secret added later reaches no component unless a compose file names it.

**Files:**

- `scripts/gists/conf.sh`: `CONFIG_SAFE_SECRET_PATTERN`, applied in `gen_safe_config`.
- `compose/koko.yml`, `chen.yml`, `kael.yml`, `nec.yml`, `magnus.yml`, `video-worker.yml`,
  `xrdp.yml`, `razor.yml`.

**Tested:**

- The filter was run on a sample config. Every secret was removed, and ordinary settings such as
  `CORE_HOST`, `REDIS_HOST`, `KOKO_SSH_PORT` and `SHARE_ROOM_TYPE` were kept.
- The rehearsal checks `config-safe.txt` on a real HA server: it holds no secret, and `CORE_HOST` is
  still present as a control.

---

## 2. The join bundle and the CA key

**Risk.**

- The CA private key (`ca.key`) stayed in plain text on both servers and inside the join bundle.
  Anyone holding it can issue certificates the whole cluster trusts.
- The join bundle (`xpam-ha-join.tgz`) was an unencrypted tar file with XPAM's full configuration. A
  copy left in a home folder, a ticket or a chat gave away everything.

**Fix:**

- **The CA key is stored only encrypted**, as `ca.key.enc` (AES-256) under the **cluster
  passphrase**. The plain key is shredded right after setup. It is only needed to replace
  certificates (#5), and then XPAM asks for the passphrase.
- **Both bundles are encrypted** with the **bundle passphrase** and are now
  `xpam-ha-join.enc` and `xpam-ha-witness.enc`. They use AES-256-CBC with a PBKDF2 key derived over
  600,000 iterations.
- `ha join` and `apply-certs` refuse to continue if the passphrase is wrong.
- **The witness bundle holds only the witness's own certificate:** no CA key and no server
  certificate.
- `ha init` creates both passphrases and shows them **once**. For automation, set
  `XPAM_HA_PASSPHRASE` and `XPAM_HA_BUNDLE_PASSPHRASE` in the environment beforehand. Passphrases are
  passed to `openssl` through the environment, never on the command line, so they don't appear in
  `ps` output.

**Files:**

- `scripts/ha.sh`: `passphrase_from`, `encrypt_dir`, `decrypt_to`, `protect_ca_key`, `ca_key_ok`,
  `bundle_passphrase`, `make_join_bundle`, `make_witness_bundle`.
- `ha/certs.sh`.

**Tested (rehearsal):**

- Both bundles are encrypted.
- A wrong passphrase is refused.
- Only `ca.key.enc` exists, with no plain `ca.key`.
- The witness bundle holds no secret and no CA key.

---

## 3. One Redis password for everything

**Risk.** Every component used Redis's one password. A compromised SSH/RDP service could have read and
changed XPAM's web sessions and cache, and the job queue. The queue accepts JSON only, so this could
not run code, but it could tamper with data.

**Fix: a separate Redis account for the SSH/RDP service.**

- The account is called `koko`. It is used only when shared rooms are set to Redis
  (`SHARE_ROOM_TYPE=redis`, which is off by default).
- It may only:
  - use keys `JUMPSERVER:KOKO:*` and `JUMPSERVER:LION:*`;
  - use channels `JUMPSERVER:KOKO:*`, `JUMPSERVER:LION:*` and `JMS:KOKO:SESSIONS:*`;
  - run ordinary read, write and pub/sub commands.
- It may not run `KEYS`, `SCAN`, admin commands or dangerous commands.
- Its password (`REDIS_KOKO_PASSWORD`) is created at install and on upgrade.
- The SSH/RDP service now sends a Redis user name: new `REDIS_USERNAME` setting in xpam-secureconnection.

**Files:**

- `compose/redis.yml`, `compose/ha-redis.yml` (the account).
- `compose/koko.yml`.
- `scripts/1_config_xpam.sh`, `scripts/7_upgrade.sh` (the password).
- xpam-secureconnection, commit `af7acd40`: `RedisUsername` in the config, passed to `pkg/exchange`
  and `pkg/lion`.

**Tested on a real Redis with this ACL:**

- **Allowed:** the service's own keys and channels.
- **Refused:** XPAM's sessions, the job queue, other channels, `KEYS`, `SCAN`, `FLUSHALL`, `CONFIG`.
- The xpam-secureconnection Go tests pass.

---

## 4. The witness shared the servers' certificate

**Risk.** The witness had the same certificate as the two servers. The firewall and the missing
passwords already kept it away from the database, Patroni and Redis. But in the vote store (etcd) it
could still **write**. A compromised witness could therefore force failovers or stop the cluster,
though not steal data.

**Fix: separate identities, and permissions in the vote store.**

| Certificate | Who | What it allows |
|---|---|---|
| `node.crt` (CN `xpam-node`) | both servers | PostgreSQL replication, Patroni API, Redis replication, etcd member |
| `witness.crt` (CN `xpam-witness`) | witness | etcd member: **it votes, nothing more** |
| `client.crt` (no name) | Patroni | TLS to the vote store; the account `xpam-node` and its password identify it |

- etcd authentication is on, and it is enabled **before** Patroni first starts.
- Role `xpam` may read and write `/xpam/` (XPAM's records). It is granted only to user `xpam-node`.
- The root account is needed to add or remove members, as `ha join` does. Its password is never given
  to the witness.
- The witness can take part in elections but can neither read nor change the cluster's records.

> Why Patroni's certificate has no name: etcd's gateway rejects a client certificate that has a name
> once authentication is on. So Patroni connects with a nameless certificate plus a password.

**Files:**

- `ha/certs.sh`.
- `ha/witness.sh.in`.
- `build/patroni-entrypoint.sh`: the etcd3 client certificate and account.
- `compose/ha-postgresql.yml`: `HA_ETCD_PASSWORD`.
- `compose/ha-etcd.yml`.
- `scripts/ha.sh`: `ha_etcdctl`, `setup_vote_accounts`. Passwords are sent on stdin, and the user
  name through an environment variable.

**Tested:**

- **Cluster test:** the witness's certificate can neither read nor write XPAM's records.
- **Rehearsal:** the witness cannot write to the vote store, and failover, rewind and switchover still
  work with permissions on.

---

## 5. No way to replace the certificates

**Risk.** The certificates are valid for 10 years. If one leaked, for example from a compromised
server, the only remedy was to set the cluster up again.

**Fix: three commands, and XPAM keeps running throughout.**

1. **On the primary,** run `xpamctl ha rotate-certs`. It asks for the cluster passphrase, then:
   - pauses automatic failover;
   - creates a new CA and new certificates;
   - applies them on this server: etcd restarts, while PostgreSQL, Patroni and Redis **re-read** the
     certificates without restarting;
   - writes new encrypted bundles.
2. **On the standby,** run `xpamctl ha apply-certs xpam-ha-join.enc`.
3. **On the witness,** unpack the new witness bundle with the usual command. The vote state is kept.
4. **On the primary,** run `xpamctl ha rotate-certs --finish`, which turns automatic failover back on.

The old certificates are kept as `certs.before-<date>`. After step 4 the old CA is no longer trusted
anywhere.

**Files:**

- `scripts/ha.sh`: `ha_rotate_certs`, `ha_apply_certs`, `apply_certs_local`, `install_certs`.
- `build/xpam-reload-certs` (new): runs `pg_ctl reload`, then HUPs Patroni.
- `build/postgresql-ha.Dockerfile`.
- `ha/witness.sh.in`: `STATE=keep`.

**Tested (cluster test and rehearsal):**

- During the rotation, neither XPAM nor PostgreSQL restarted.
- Replication runs on the new certificates.
- A connection with the **old** certificate is refused.

---

## Test results

| Suite | Result |
|---|---|
| `tests/ha/cluster_test.sh`: containers, RBAC, failover, rewind, split, switchover, lockdown, rotation | **32/32 passed** |
| `tests/ha/rehearsal.sh`: three real servers through the full install path | **66/66 passed** |
| Redis ACL (standalone) | all allowed and refused cases as expected |
| xpam-secureconnection `go test` | pass |

## What an administrator does differently

- **Keep two passphrases** from `xpamctl ha init` in the password safe:
  - the **cluster passphrase**, needed for `rotate-certs`;
  - the **bundle passphrase**, needed to open the bundles.

  XPAM shows them only once.
- **Bundles are now `.enc` files.** `xpamctl ha join xpam-ha-join.enc` asks for the bundle passphrase.
  On the witness, `openssl enc -d … | tar xz` then `witness.sh`; the exact line is printed by `ha init`
  and in INSTALL.md §11.
- **After a suspected compromise:** run `rotate-certs`, then `apply-certs`, then the witness bundle,
  then `--finish`. Also rotate XPAM's own secret key with `xpamctl rotate-secret-key`.
- **Upgrading from 5.1.15:** nothing to do. The upgrade creates the SSH/RDP service's Redis password,
  and regenerates `config-safe.txt` with the new filter.

## What remains by design

- **The two servers trust each other.** The primary writes into the standby's data folder, and both
  have the same `config.txt`. Root on one server means the cluster.
- **Inside a server,** XPAM reaches PostgreSQL and Redis without TLS, over Docker's internal network,
  which never leaves the machine. Each connection still needs a password.
- **Losing two of the three machines stops automatic failover.** The vote needs a majority.
- **A next step, if wanted:** keep the master key in a vault or KMS instead of `config.txt`.

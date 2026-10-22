# XPAM and external vaults

XPAM can keep its secrets in an external vault instead of on its own server. There are two levels:

| | What goes to the vault | Vaults |
|---|---|---|
| **Account storage** | The passwords and keys of the accounts XPAM manages | HashiCorp Vault, CyberArk Conjur, Delinea Secret Server, Google Secret Manager, Azure Key Vault, AWS Secrets Manager, OpenBao |
| **Startup secrets** | XPAM's own `SECRET_KEY`, the database and Redis passwords, component tokens: nothing secret stays on the XPAM server | HashiCorp Vault with the **XPAM Vault kit** |

Before XPAM writes an account secret to any vault, it encrypts it with `SECRET_KEY`. This creates a
**split of knowledge** with the hardened setup:

| Someone who has… | can read account passwords? |
|---|---|
| a copy of XPAM's database or backups | no: the database holds only a marker |
| root on a stopped or copied XPAM server (disk, snapshot) | no: `config.txt` holds no secret, and the keys were only in memory |
| Vault administrator rights | no: the values in Vault are encrypted with `SECRET_KEY`, which they cannot read (see "administrators" below) |
| root on the **running** XPAM server | yes. XPAM has to use the passwords, so the process holds them. Vault's audit log records every read, and access can be revoked in Vault at once |

## 0. At install

`xpamctl install` (or `quick_start.sh`) ends by asking where XPAM keeps its secrets:

| Choice | What happens | Protects against |
|---|---|---|
| **1. Vault servers of their own** (recommended) | You set up the kit (section 1) first; the installer connects with this server's bundle | A stolen disk, snapshot or backup **and** root on the XPAM server copying the vault |
| **2. A hardened Vault on this server** (the default when unattended) | The kit runs on the XPAM server itself (`--local`) and unseals at boot with `systemd-creds`. That uses the TPM if there is one, otherwise a key on this disk | Copies of `config.txt`, database backups, Docker's settings. **Not** root on the server or a full disk copy without a TPM. Move it later with `xpamctl vault connect` |
| **3. On this server only** | As before | Nothing beyond file permissions and database encryption |

For automation, set:
- `XPAM_VAULT_MODE=external` with `XPAM_VAULT_BUNDLE=<xpam-vault-IP.enc>` and
  `XPAM_VAULT_BUNDLE_PASSPHRASE`; or
- `XPAM_VAULT_MODE=local`; or
- `XPAM_VAULT_MODE=none`.

On an existing installation:
- `xpamctl vault local` sets up the local Vault;
- `xpamctl vault connect <bundle>` connects to Vault servers. When XPAM is already connected, it
  **moves** everything there, for example from the local Vault: the account secrets come back from the
  current Vault, the startup secrets are written to the new one, XPAM switches over, and the account
  secrets go to the new Vault. The local Vault is then stopped; its data stays in `/opt/xpam-vault`
  until you delete it.

The Vault image is `hashicorp/vault:2.1.2` from Docker Hub. For an offline installation, load it first,
or set `XPAM_VAULT_IMAGE` to your registry's copy.

---

## 1. The XPAM Vault kit (HashiCorp Vault)

The script `vault/xpam-vault.sh` sets up a hardened HashiCorp Vault cluster on its own servers. It
needs three small Linux servers, separate from XPAM's:
- 2 CPU and 2 GB RAM each;
- Docker with Compose v2, `openssl`, `curl`, `python3`;
- **swap off** (`swapoff -a`, and removed from `/etc/fstab`);
- the clock synchronised (NTP).

They need different administrators from the XPAM servers, if you can manage it.

### What the kit enforces

**Network:**
- Vault answers only clients with a certificate from the kit's own CA, over **TLS 1.3 only**.
- It doesn't reveal its version, addresses or cluster name. There is no web UI.
- The firewall (chain `XPAM-VAULT`, applied before Docker at boot) lets in only XPAM's servers, the
  administrators and the other Vault servers on 8200, and only the Vault servers on 8201.

**Servers:**
- Raft storage is replicated over the 3 servers, and any one can fail.
- Vault runs as its own non-root user, in a read-only container with no Linux capabilities and core
  dumps off.

**Audit:**
- Every request is written to the audit log: who, what, from which address. Secret values appear only
  as HMACs.
- Vault refuses to answer when it can't write the audit log.

**XPAM's access:**
- XPAM logs in with **its own client certificate**. Its token works **only from its own address**,
  lasts 20 minutes (at most 1 hour) and is renewed automatically.
- XPAM may only use its two stores: account secrets and startup secrets. It **cannot delete or destroy
  the history**, change its own login, create tokens or touch the audit log.

**Administrators:**
- They log in with the admin certificate (key encrypted with the kit passphrase).
- They can see cluster health, take backups and recreate XPAM's logins.
- They **cannot read XPAM's secrets** or give themselves access. The values they may set on an XPAM
  login are pinned: the kit's CA only, `xpam-*` names only, XPAM's addresses only, XPAM's policy only.

**Emergency access:**
- **No root token is kept.** The unseal key shares (3 of 5) are shown once; you can encrypt them to
  each holder's PGP key instead.
- An emergency root token needs 3 share holders: `vault operator generate-root`.

### Setting it up

```bash
# on the first Vault server (10.0.0.11); the XPAM servers are 10.0.0.21 and 10.0.0.22
./xpam-vault.sh init --nodes 10.0.0.11,10.0.0.12,10.0.0.13 --xpam 10.0.0.21,10.0.0.22
```

`init` shows the following, **once**:
- **Kit passphrase:** protects the CA key and the admin key on this server.
- **Bundle passphrase:** opens the bundles for the other servers.
- **Five unseal key shares:** give one to each of five different people.

It writes one encrypted bundle for each other Vault server and one for each XPAM server, in
`/opt/xpam-vault/out/`.

Next steps:
1. On the other two Vault servers, copy the bundle and the script over, then run
   `./xpam-vault.sh join xpam-vault-node-<ip>.enc`, then `./xpam-vault.sh unseal`. Three share holders
   type their share; it's not shown on screen.
2. Check with `./xpam-vault.sh status` (on the first server): 3 servers, all unsealed, one leader.
3. Connect XPAM (section 2), then delete the bundles: `shred -u /opt/xpam-vault/out/*`.

### `init` options

| Option | Meaning |
|---|---|
| `--admin-ips 10.0.5.0/24` | where administrators connect from (default: the Vault servers themselves) |
| `--cluster NAME` | name of this XPAM installation in Vault (default `xpam`) |
| `--siem host:port` | also stream the audit log to your SIEM over TCP |
| `--pgp-keys a.b64,b.b64,…` | encrypt each of the 5 shares to one holder (`gpg --export <id> \| base64 -w0`) |
| `--seal-config file.hcl` | auto-unseal with a `seal` stanza: Transit, AWS/Azure/GCP KMS, or an HSM (Vault Enterprise). The shares then become recovery shares |

### Running it

| When | What to do |
|---|---|
| A Vault server restarts | `./xpam-vault.sh unseal` on it (3 share holders). The other two keep serving meanwhile. With `--seal-config` it unseals by itself |
| Backups | `./xpam-vault.sh snapshot /backup/vault-$(date +%F).snap`. The file is encrypted by Vault; restoring it needs the unseal shares |
| A new XPAM server at an address given at `init` (e.g. a rebuilt server) | `./xpam-vault.sh add-xpam <ip>` gives a new bundle for it |
| A new XPAM address | Administrators cannot add one (that is the point); it needs an emergency root token (3 share holders) |
| Audit logs | `/opt/xpam-vault/logs/audit.log` on the active server, rotated daily, kept 90 days. Ship them off the servers (`--siem`, or XPAM's log shipment) |

The certificates are valid for 825 days. There is no rotation command yet: plan a re-issue before then.

---

## 2. Connecting XPAM (`xpamctl vault connect`)

On each XPAM server, with its own bundle:

```bash
xpamctl vault connect xpam-vault-10.0.0.21.enc
```

It asks for the bundle passphrase, then:
1. **Logs in** to Vault with this server's certificate and checks its rights.
2. **Writes the startup secrets** to Vault (`SECRET_KEY`, `BOOTSTRAP_TOKEN`, the database, Redis and
   component passwords, the HA passwords), reads them back and compares them.
3. **Writes a recovery copy**, `/opt/xpam/config/vault/escrow.enc`, encrypted with the **recovery
   passphrase**, which is shown once. Keep it offline, apart from the server: with it XPAM can be brought
   back even if Vault is lost.
4. **Installs `xpam-secrets.service`**. At every boot it reads the secrets from Vault into memory
   (`/run/xpam/secrets`, never on disk). Each container gets **only the secrets it uses**, and reads
   them when it starts.
5. **Removes the secrets from `config.txt`**, switches account storage to Vault, and locks the vault
   settings in the console (`VAULT_LOCKED`).
6. **Restarts XPAM.** The containers are recreated, so none keeps a secret in its Docker settings.
7. **Moves every account password and key to Vault** and checks the database keeps none.

At the end it lists older copies still on the server that hold secrets: `config.txt` backups, HA
bundles, database backups from before. Move them offline or `shred -u` them.

### Afterwards

| Command or situation | What happens |
|---|---|
| `xpamctl vault status` | Shows Vault, the login, which secrets are in Vault, whether any is left in `config.txt`, and how many account secrets are left in the database (should be 0) |
| The server boots | XPAM's containers wait until the secrets are in memory. If Vault can't be reached, XPAM waits; it never starts with empty or new secrets |
| `xpamctl upgrade`, `backup_db`, `ha ...` | These read the secrets from memory. They refuse to run if the secrets can't be read, so an upgrade never creates a new `SECRET_KEY` |
| `xpamctl rotate-secret-key` | Re-encrypts everything, including the account secrets in Vault. The new key goes to Vault, which keeps the previous one as an older version |
| `xpamctl vault disconnect` | Brings everything back to this server: secrets into `config.txt`, account secrets into the database |
| Console: System settings → Vault | Shows the configuration and the **Test** button. The settings can't be changed there, and "Restore to database" is refused, so a console administrator can't redirect secrets to another vault |

**High availability requires Vault.** The cluster's configuration holds every password, so
`xpamctl ha init` refuses until XPAM's secrets are in a Vault of the kit. The steps:
1. Kit `init` with `--xpam A,B` (both addresses).
2. On A, `xpamctl vault connect xpam-vault-A.enc`.
3. On A, `xpamctl ha init A B W --vault-bundle xpam-vault-B.enc`. B's Vault login then travels inside
   the encrypted HA join bundle.
4. `xpamctl ha join` on B logs B in to Vault with its own certificate before it needs any password.

The join bundle carries no XPAM secret.

### Proving it: `xpamctl vault verify`

| Checked | How |
|---|---|
| Encryption to each Vault server | TLS 1.3 negotiated (cipher shown); the server certificate is signed by the kit CA and names that address; days until it expires |
| What is refused | TLS 1.2 (with a valid certificate); any request without a client certificate |
| This server's client certificate | Days until it expires |
| Vault | Unsealed; its version is not revealed |
| XPAM's token | Only XPAM's policy (no `default`, no `root`), at most an hour, bound to this server's address |
| Least privilege | XPAM cannot list mounts, create tokens, touch the audit log or destroy the history of its startup secrets |
| This server | `config.txt` holds no secret, the secrets are in memory (tmpfs) only, no container holds `SECRET_KEY` in its settings, the database keeps no account secret |
| XPAM's own client | Inside the core container: TLS 1.3 minimum and the kit CA only (a server with a public certificate is refused) |

XPAM's client never accepts less than TLS 1.3, even from a misconfigured Vault.
`VAULT_HCP_TLS_MIN_VERSION=1.2` exists only for an older Vault outside the kit.

**Components that cannot use Vault yet:** the upstream video worker, nec, magnus, razor and xrdp
images. `connect` refuses to run while one of them is running.

---

## 2b. The data key: what encrypts the secrets, and its rotation

Every encrypted field goes through one *data key*: account passwords and keys, MFA seeds, API secrets,
secret settings and connection tokens.

| `XPAM_DATA_KEY` | Where the key is | Used with |
|---|---|---|
| `transit` | **Inside HashiCorp Vault (Transit). It never leaves Vault.** XPAM's database holds only ciphertext (`xpamt:…vault:v3:…`). To use a password, XPAM asks Vault, which returns it for that connection only. Every value has its own derived key | Choices 1 and 2: set automatically by `connect` / `local` |
| `local` | A keyring in XPAM's database: random 256-bit data keys, versioned, each wrapped by a key derived from `SECRET_KEY` (HKDF) | Choice 3: set at install |
| `legacy` | AES-256-GCM keyed by `SECRET_KEY`, as before | Older installations, until changed |

**Rotation without downtime:** `xpamctl vault rotation daily|weekly|monthly|off`, weekly by default.
- With Transit, Vault makes a new key version on schedule.
- A nightly task re-encrypts every value to the newest version, in place. With Transit, Vault re-wraps
  the values itself, without XPAM seeing them.
- XPAM keeps running and **nobody is signed out**: the data key is separate from the sessions' signing key.
- Versions older than the last 4 (`XPAM_DATA_KEY_KEEP_VERSIONS`) are retired once nothing uses them. A
  leaked old key, or a database backup older than about a month, then opens nothing.
- If a value can't be opened, the task keeps every version and retries the next night.

**What XPAM may do with the Transit key:** encrypt, decrypt, re-wrap, read its versions, set when old
versions stop working, and set the rotation period. It may **not** export it, trim old versions, delete
it, or allow its deletion. If Vault is unreachable, a read fails with an error, never an empty password.

The console shows the data key under System settings → Vault: provider, current version, how many
values are on each version, and the rotation.

On an installation without Vault: `xpamctl vault data-key local` (versioned keyring) or `legacy`.
`xpamctl rotate-secret-key` re-wraps the keyring and leaves Transit values alone, since they don't
depend on `SECRET_KEY`.

---

## 3. Several vaults at once

Besides the configured vault, XPAM can use further **vault connections**, of any supported type.

**Adding a connection, on the server:**
- `xpamctl vault add-connection <name> <type> settings.json`. The file holds the `VAULT_<TYPE>_*`
  settings of section 4; shred it afterwards.
- `xpamctl vault add-connection <name> hcp --bundle xpam-vault-IP.enc` for another Vault of the kit.

A connection added this way is *managed*: the console shows and tests it but cannot change it. With
`VAULT_LOCKED` the console cannot add connections at all. Connection settings are stored in XPAM's
database, encrypted with `SECRET_KEY`. The console never shows their passwords or keys.

**Storage rules** (System settings → Vault storage rules, per organization):
- Match on **asset groups**, **platforms** and a **username pattern** (e.g. `svc_*`).
- Choose the **vault** (empty means the configured one) and, optionally, a **mirror**.
- The first matching rule by priority wins. A rule without conditions is the organization's default.
- Each secret remembers where it is. Changing a rule moves the secrets concerned in the background,
  removing the old copy. You can also press "Apply rules now".

| Need | How |
|---|---|
| Each organization in its own vault | One rule without conditions in each organization |
| Network devices in Delinea, servers in HashiCorp | A rule on the "Network" asset group to the Delinea connection |
| Service accounts in a separate vault | A rule with username `svc_*` |
| A copy in a second vault (the administrator decides) | Set **Mirror** on a rule, or the configured vault's mirror (System settings → Vault → Mirror). New secrets go to both; existing ones are copied when you switch it on; if the vault fails, XPAM reads the mirror |
| Passwords that live in the customer's vault | On the account: Password → **Read from an existing vault**, with the connection, the path and the field. XPAM reads it when connecting, keeps no copy, and never rotates, pushes or deletes it |

What the path means for an existing secret:

| Vault | Path | Field |
|---|---|---|
| HashiCorp / OpenBao | API path, e.g. `secret/data/app/db` | the key (e.g. `password`) |
| CyberArk Conjur | variable id, e.g. `prod/db/password` | – |
| Delinea | secret id | field slug (default `password`) |
| Google | secret name (or `projects/…/secrets/…`) | version (default latest) |
| AWS | secret name or ARN | key of a JSON secret |
| Azure | secret name | version |

XPAM's account in that vault needs read access to those secrets. With the kit, that means a policy line
added by an emergency root token, since the kit's administrators cannot widen XPAM's policy.

---

## 4. Other vaults (account storage)

Put these in `config.txt` (`VAULT_ENABLED=true`, `VAULT_BACKEND=…`), then restart XPAM. Credentials
can also be entered in the console page of the vault; `xpamctl vault connect` does this for HashiCorp.
Then press **Sync** (System settings → Vault) to move the existing account secrets.

To lock the console as `connect` does, also set `VAULT_LOCKED=true`. All the vault settings must then
be in `config.txt`.

### CyberArk Conjur (Open Source, Enterprise or Secrets Manager Self-Hosted, Conjur Cloud)

```yaml
# Conjur policy, loaded by an administrator into root: a host for XPAM that owns its branch
- !host xpam-server
- !policy
  id: xpam
  owner: !host xpam-server
```

```
VAULT_BACKEND=cyberark
VAULT_CYBERARK_URL=https://conjur.example.com
VAULT_CYBERARK_ACCOUNT=myorg
VAULT_CYBERARK_LOGIN=host/xpam-server
VAULT_CYBERARK_API_KEY=<the host's API key>
VAULT_CYBERARK_POLICY=xpam
VAULT_CYBERARK_CA_FILE=/opt/jumpserver/config/conjur-ca.pem   (if Conjur uses a private CA)
```

How it works:
- Each account secret is a variable under `xpam/`, declared by XPAM the first time.
- Conjur keeps the previous values.
- The host's access token (8 minutes) is renewed automatically.

### Delinea Secret Server (on-premises or Cloud)

Create the following in Secret Server:
- an **application account** for XPAM;
- a **folder** where only that account has edit rights;
- a **secret template** with a password field (e.g. the built-in *Password* template).

```
VAULT_BACKEND=delinea
VAULT_DELINEA_URL=https://ss.example.com/SecretServer
VAULT_DELINEA_USERNAME=xpam-app
VAULT_DELINEA_PASSWORD=<its password>
VAULT_DELINEA_FOLDER_ID=7
VAULT_DELINEA_TEMPLATE_ID=6003
VAULT_DELINEA_FIELD=password          (the field's slug)
VAULT_DELINEA_DOMAIN=                 (for a domain account)
```

Each account secret is a Secret Server secret named `xpam:<org>:<path>` in that folder. Secret Server
keeps the field history.

### Google Secret Manager

Create a **service account** with `roles/secretmanager.admin` on the project, or a custom role with:
- `secrets.create`, `secrets.get`, `secrets.update`, `secrets.delete`;
- `versions.add`, `versions.access`, `versions.destroy`.

Download its **JSON key**.

```
VAULT_BACKEND=gcp
VAULT_GCP_PROJECT=my-project
VAULT_GCP_CREDENTIALS=<the JSON key, on one line>
VAULT_GCP_LOCATIONS=                  (empty: automatic replication; or e.g. europe-west1,europe-west4)
```

How it works:
- Each account secret is a secret `xpam_<org>_<path>`.
- A new value is a new version, and the previous version is destroyed.

### Azure Key Vault, AWS Secrets Manager, OpenBao

As before (`VAULT_AZURE_*`, `VAULT_AWS_*`, `VAULT_OPENBAO_*`).

---

## 5. Adding another vault

A vault is a small plugin in `apps/accounts/backends/<name>/`. CyberArk, Delinea and Google are about
150 lines each and good templates.

1. **`service.py`:** a client with `is_active()`, `get(name, strict=False)`, `create(name, secret)`,
   `update(name, secret)`, `delete(name)` and `update_metadata(name, dict)`.
   - `get` returns `''` for a missing secret, or `None` with `strict=True`.
   - The secrets it receives are already encrypted with `SECRET_KEY`.
   - Log in with a short-lived token, renew it before it expires, and log in again once on a 401.
2. **`main.py`:** `class Vault(GeneralVaultMixin, BaseVault)` with `type = VaultTypeChoices.<name>`. It
   builds the client from `VAULT_<NAME>_*` settings.
3. **`entries.py`** (optional): secret names when the vault does not accept `orgs/<org>/assets/...`
   paths. See `delinea/entries.py` and `gcp/entries.py`.
4. **Wire it up:**
   - `VaultTypeChoices` (`accounts/const/vault.py`);
   - defaults (`jumpserver/conf.py`) and settings (`jumpserver/settings/auth.py`);
   - a serializer (`settings/serializers/feature.py`);
   - the category in `settings/api/settings.py` (serializer, permission, `VAULT_LOCKED_CATEGORIES`) and
     in `settings/api/vault.py` (Test);
   - a console page in `xpam-web/src/views/settings/Feature/Vault/`.
5. **Test it with `tests/vault/backends_test.py`.** It runs XPAM's own save, read, update, restore, sync
   and delete flow against the backend. Add the vendor (real, or a mock that follows its documented
   API) to `tests/vault/backends_run.sh`.

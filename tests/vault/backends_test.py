"""
XPAM account storage backends, end to end through XPAM's own code (signals, entries, sync/restore tasks).

Run inside a core container connected to a THROWAWAY database, with the VAULT_* settings of one backend in
the environment (VAULT_ENABLED=true, VAULT_BACKEND=hcp|cyberark|delinea|gcp, ...):
    python /t/backends_test.py
Checks: the backend's own test, a new account's secret goes to the vault (encrypted with SECRET_KEY there)
and the database keeps only the marker, XPAM reads it back, an update reaches the vault, restore brings it
back into the database and sync moves it out again, deleting the account removes it from the vault.
"""
import os
import sys
import uuid

sys.path.insert(0, '/opt/jumpserver/apps')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django  # noqa: E402

django.setup()

from django.conf import settings  # noqa: E402

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + f'[{settings.VAULT_BACKEND}] ' + name + ('' if ok else f'  ({detail})'),
          flush=True)


from orgs.models import Organization  # noqa: E402
from orgs.utils import set_current_org  # noqa: E402

set_current_org(Organization.default())

from accounts.backends import vault_client  # noqa: E402
from accounts.models import Account  # noqa: E402
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK  # noqa: E402
from accounts.tasks.vault import restore_secret_from_vault, sync_secret_to_vault  # noqa: E402
from assets.models import Host, Platform  # noqa: E402
from common.db.utils import Encryptor  # noqa: E402

vault_client.type  # noqa: B018  (sets up the lazy client from the settings)
backend = vault_client._wrapped
check('the configured backend is in use', backend.type == settings.VAULT_BACKEND, backend.type)
ok, error = backend.is_active()
check("the backend's own test (create, read, update, delete)", ok, error)


def raw(account):
    """ what the vault itself holds for this account (still encrypted with SECRET_KEY) """
    entry = backend.build_entry(account)
    if settings.VAULT_BACKEND == 'hcp':
        return (backend.client.get(path=entry.full_path).get('data') or {}).get('secret')
    return backend.client.get(name=entry.full_path)


def stored(account):
    return Account.objects.get(id=account.id)._secret


from django.db import transaction  # noqa: E402

with transaction.atomic():  # (asset signals run on commit)
    host, _ = Host.objects.get_or_create(
        name='vault-test', defaults={'address': '192.0.2.10', 'platform': Platform.objects.get(name='Linux')})
canary = 'canary-' + uuid.uuid4().hex
account = Account.objects.create(asset=host, name='vt-' + uuid.uuid4().hex[:6], username='vt-' + uuid.uuid4().hex[:6],
                                 secret_type='password',
                                 secret=canary)
check('the database keeps only the marker', stored(account) == VAULT_SAVED_SECRET_MARK, stored(account)[:30])
value = raw(account)
check('the vault holds the secret, encrypted with SECRET_KEY (vault admins cannot read it)',
      value and value != canary and Encryptor(value).decrypt() == canary, str(value)[:30])
check('XPAM reads it back', Account.objects.get(id=account.id).secret == canary)

changed = canary + '-2'
account = Account.objects.get(id=account.id)
account.secret = changed
account.save()
check('an update reaches the vault', Encryptor(raw(account) or '').decrypt() == changed)
check('and XPAM reads the new value', Account.objects.get(id=account.id).secret == changed)

restore_secret_from_vault()
check('restore brings the secret back into the database',
      stored(account) == changed, (stored(account) or '')[:30])
sync_secret_to_vault()
check('sync moves it out of the database again', stored(account) == VAULT_SAVED_SECRET_MARK)
check('still readable after the round trip', Account.objects.get(id=account.id).secret == changed)

Account.objects.get(id=account.id).delete()
check('deleting the account removes it from the vault', not raw(account))

print(f'RESULT [{settings.VAULT_BACKEND}]: {sum(results)}/{len(results)} passed', flush=True)
sys.exit(0 if all(results) else 1)

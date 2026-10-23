"""Isolated stack: account passwords in Vault with a copy in the database (VAULT_KEEP_DB_COPY, 5.1.19) — the copy
follows each change, is encrypted with the local data key, is read only when Vault does not answer; switching the
option off removes the copies, on fills them from Vault; bringing a secret back from Vault drops its copy.
  python keep_copy_test.py setup|down|live|up      (keep_copy_run.sh pauses Vault between the phases)"""
import json, os, secrets, sys, time
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
from django.db import connection
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node
from accounts.models import Account, AccountTemplate
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK
from accounts.tasks.vault import update_secret_copies
from users.models import User

STATE = '/tmp/keep_copy_state.json'
PHASE = sys.argv[1]
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)


def raw(model, pk, column):
    with connection.cursor() as c:
        c.execute(f'SELECT "{column}" FROM {model._meta.db_table} WHERE id = %s', [str(pk)])
        return c.fetchone()[0]


def fresh(model, pk):
    with tmp_to_root_org():
        return model._base_manager.get(pk=pk)


def pw():
    return 'P-' + secrets.token_urlsafe(18)


org = Organization.default(); set_current_org(org)
admin = User.objects.get(username='admin')
A = APIClient(); A.force_authenticate(admin); H = {'HTTP_X_JMS_ORG': str(org.id)}

if PHASE == 'setup':
    check('the option is on (VAULT_KEEP_DB_COPY) with the local data key',
          settings.VAULT_KEEP_DB_COPY is True and settings.XPAM_DATA_KEY == 'local',
          (settings.VAULT_KEEP_DB_COPY, settings.XPAM_DATA_KEY))
    s1, s2, t1 = pw(), pw(), pw()
    r = A.post('/api/v1/assets/hosts/', {
        'name': 'kc-linux', 'address': '10.0.0.9', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(Node.org_root().id)], 'protocols': [{'name': 'ssh', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': s1}]},
        format='json', **H)
    set_current_org(org)
    acc = Account.objects.get(asset_id=r.data['id'], username='root')
    check('the account is in Vault: the database keeps the marker', raw(Account, acc.id, '_secret') == VAULT_SAVED_SECRET_MARK)
    copy = raw(Account, acc.id, '_secret_copy') or ''
    check('the database copy is encrypted with the local data key', copy.startswith('xpamk:') and s1 not in copy, copy[:12])
    check('the copy holds the password', fresh(Account, acc.id)._secret_copy == s1)
    check('the password is read (from Vault)', fresh(Account, acc.id).secret == s1)

    r = A.patch(f'/api/v1/accounts/accounts/{acc.id}/', {'secret': s2}, format='json', **H)
    set_current_org(org)
    check('a changed password goes to Vault and to the copy',
          r.status_code == 200 and fresh(Account, acc.id).secret == s2 and fresh(Account, acc.id)._secret_copy == s2,
          r.status_code)
    hist = fresh(Account, acc.id).history.first()
    try:
        hist.secret
        check('the account history still opens (history rows have no copy)', True)
    except Exception as e:
        check('the account history still opens (history rows have no copy)', False, e)

    r = A.post('/api/v1/accounts/account-templates/', {
        'name': 'kc-template', 'username': 'deploy', 'secret_type': 'password', 'secret': t1}, format='json', **H)
    set_current_org(org)
    tpl = AccountTemplate.objects.get(name='kc-template')
    check('an account template is in Vault with a copy too',
          raw(AccountTemplate, tpl.id, '_secret') == VAULT_SAVED_SECRET_MARK and fresh(AccountTemplate, tpl.id)._secret_copy == t1,
          r.status_code)
    json.dump({'acc': str(acc.id), 'tpl': str(tpl.id), 's2': s2, 't1': t1}, open(STATE, 'w'))

elif PHASE == 'down':
    st = json.load(open(STATE))
    started = time.monotonic()
    got = None
    try:
        got = fresh(Account, st['acc']).secret
    except Exception as e:
        got = e
    check('Vault does not answer: the password comes from the database copy', got == st['s2'], type(got).__name__)
    check('... within the Vault timeout', time.monotonic() - started < settings.VAULT_HCP_TIMEOUT + 5,
          round(time.monotonic() - started, 1))
    check('the template too', fresh(AccountTemplate, st['tpl']).secret == st['t1'])
    settings.VAULT_KEEP_DB_COPY = False
    try:
        got = fresh(Account, st['acc']).secret
    except Exception as e:
        got = None
    check('without the option, Vault down: no password (the copy is not used)', got != st['s2'])

elif PHASE == 'live':
    # XPAM running with Vault answering, then Vault stops answering (the runner pauses it)
    st = json.load(open(STATE))
    check('Vault answers: the password is read from it', fresh(Account, st['acc']).secret == st['s2'])
    open('/tmp/keep_copy_ready', 'w').close()
    for _ in range(60):
        if os.path.exists('/tmp/keep_copy_paused'):
            break
        time.sleep(1)
    got = None
    try:
        got = fresh(Account, st['acc']).secret
    except Exception as e:
        got = e
    check('Vault stops answering while XPAM runs: the password comes from the copy', got == st['s2'], type(got).__name__)

elif PHASE == 'up':
    st = json.load(open(STATE))
    settings.VAULT_KEEP_DB_COPY = False
    update_secret_copies()
    check('option off: the copies are removed',
          raw(Account, st['acc'], '_secret_copy') is None and raw(AccountTemplate, st['tpl'], '_secret_copy') is None)
    check('... and the password is still read from Vault', fresh(Account, st['acc']).secret == st['s2'])
    settings.VAULT_KEEP_DB_COPY = True
    kept, failed = update_secret_copies()
    check('option on: the copies are filled from Vault', (kept, failed) == (2, 0)
          and fresh(Account, st['acc'])._secret_copy == st['s2'], (kept, failed))
    # a secret saved to the vault before 5.1.17 keeps an encrypted marker in the database
    from common.db.utils import Encryptor
    with connection.cursor() as c:
        c.execute(f'UPDATE {AccountTemplate._meta.db_table} SET "_secret" = %s, "_secret_copy" = NULL WHERE id = %s',
                  [Encryptor(VAULT_SAVED_SECRET_MARK).encrypt(), st['tpl']])
    old = raw(AccountTemplate, st['tpl'], '_secret')
    kept, failed = update_secret_copies()
    check('a secret saved before 5.1.17 (encrypted marker) gets its copy too',
          old != VAULT_SAVED_SECRET_MARK and (kept, failed) == (2, 0) and fresh(AccountTemplate, st['tpl'])._secret_copy == st['t1'],
          (kept, failed))
    from accounts.tasks.vault import _get_model_queryset, ACTION_RESTORE
    qs, _skipped = _get_model_queryset(AccountTemplate, ACTION_RESTORE)
    check('... and bringing secrets back from Vault still finds it', qs.filter(id=st['tpl']).exists())
    acc = fresh(Account, st['acc'])
    from accounts.backends import vault_client
    acc.restore_secret_from_vault(vault_client.get_for_restore(acc))
    check('a secret brought back from Vault drops its copy',
          raw(Account, st['acc'], '_secret') != VAULT_SAVED_SECRET_MARK and raw(Account, st['acc'], '_secret_copy') is None
          and fresh(Account, st['acc']).secret == st['s2'])

print(f'RESULT {PHASE}: {sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)

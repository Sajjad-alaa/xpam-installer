"""
XPAM: tokens at rest — a copy of the database must give no usable token.

Checks: connection token values are stored encrypted (also those created before the upgrade: migration
0011 encrypts them, and rolling back decrypts them), the components' API still returns the usable value,
OAuth2 access/refresh tokens are kept only as SHA-256 (old plain copies blanked) and still authenticate.

Run inside a core container connected to a THROWAWAY database (never the live one):
    python /t/at_rest_test.py
"""
import os
import sys
from datetime import timedelta
from types import SimpleNamespace

sys.path.insert(0, '/opt/jumpserver/apps')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django  # noqa: E402

django.setup()

from django.core.management import call_command  # noqa: E402
from django.db import connection  # noqa: E402
from django.utils import timezone  # noqa: E402

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ({detail})'))


def raw(sql, params=()):
    with connection.cursor() as c:
        c.execute(sql, params)
        return c.fetchall() if c.description else []


from authentication.models import ConnectionToken  # noqa: E402
from orgs.models import Organization  # noqa: E402
from users.models import User  # noqa: E402

user = User.objects.filter(username='admin').first()
org_id = Organization.DEFAULT_ID

# 1. a token created now is stored encrypted and reads back as created
token = ConnectionToken(user=user, account='@INPUT', protocol='ssh', connect_method='ssh', org_id=org_id)
token.value = 'Ab3dEf6hIj9kLm0p'
token.save()
stored = raw("SELECT value FROM authentication_connectiontoken WHERE id = %s", [token.id])[0][0]
check('a new connection token value is stored encrypted', stored != token.value and len(stored) > 64, stored[:20])
check('it reads back as the original value', ConnectionToken.objects.get(id=token.id).value == 'Ab3dEf6hIj9kLm0p')

# 2. roll back: the value is plain again (as before the upgrade); then add OAuth tokens the old way
call_command('migrate', 'authentication', '0010', verbosity=0)
stored = raw("SELECT value FROM authentication_connectiontoken WHERE id = %s", [token.id])[0][0]
check('rollback leaves the value plain (as before the upgrade)', stored == 'Ab3dEf6hIj9kLm0p', stored[:20])

from oauth2_provider.models import get_access_token_model, get_refresh_token_model  # noqa: E402
from authentication.backends.oauth2_provider.utils import get_or_create_jumpserver_client_application  # noqa: E402
from oauth2_provider.oauth2_validators import OAuth2Validator  # noqa: E402

AccessToken, RefreshToken = get_access_token_model(), get_refresh_token_model()
app = get_or_create_jumpserver_client_application()
old_access = 'old-access-' + os.urandom(12).hex()
old_refresh = 'old-refresh-' + os.urandom(12).hex()
at = AccessToken.objects.create(user=user, application=app, token=old_access, scope='read write',
                                expires=timezone.now() + timedelta(hours=1))
RefreshToken.objects.create(user=user, application=app, token=old_refresh, access_token=at)
# simulate a token issued before hashed storage: the plain copy is in the table
raw("UPDATE oauth2_provider_accesstoken SET token = %s WHERE id = %s", [old_access, at.id])
check('before the upgrade an OAuth token is stored in plain',
      raw("SELECT token FROM oauth2_provider_accesstoken WHERE id = %s", [at.id])[0][0] == old_access)

# 3. upgrade
call_command('migrate', 'authentication', verbosity=0)
stored = raw("SELECT value FROM authentication_connectiontoken WHERE id = %s", [token.id])[0][0]
check('the upgrade encrypts existing connection token values', stored != 'Ab3dEf6hIj9kLm0p' and len(stored) > 64)
check('an existing token still reads back (still usable)',
      ConnectionToken.objects.get(id=token.id).value == 'Ab3dEf6hIj9kLm0p')
check('no plain connection token value left in the table',
      not raw("SELECT 1 FROM authentication_connectiontoken WHERE value <> '' AND length(value) <= 64"))

# the components' API (SSH/RDP, database proxy) gets the usable value to compare with what the user typed
from authentication.serializers import ConnectionTokenSecretSerializer  # noqa: E402

field = ConnectionTokenSecretSerializer().fields['value']  # the full token has no asset here: the field only
value = field.to_representation(field.get_attribute(ConnectionToken.objects.get(id=token.id)))
check("the components' secret API returns the usable value", value == 'Ab3dEf6hIj9kLm0p')

rows = raw("SELECT token, token_checksum FROM oauth2_provider_accesstoken WHERE id = %s", [at.id])
check('the upgrade blanks old plain OAuth access tokens (hash kept)', rows[0][0] == '' and len(rows[0][1]) == 64)
check('and refresh tokens', not raw("SELECT 1 FROM oauth2_provider_refreshtoken WHERE token <> ''"))
check('an old access token still authenticates (looked up by its hash)',
      OAuth2Validator().validate_bearer_token(old_access, ['read'], SimpleNamespace()))
check('a wrong access token does not',
      not OAuth2Validator().validate_bearer_token(old_access + 'x', ['read'], SimpleNamespace()))

# 4. tokens issued now (the desktop client's real flow: PKCE authorize, code exchange, refresh, revoke)
import base64, hashlib, json  # noqa: E401,E402
from urllib.parse import parse_qs, urlsplit  # noqa: E402
from django.test import RequestFactory  # noqa: E402
from oauth2_provider.views import AuthorizationView, RevokeTokenView, TokenView  # noqa: E402

factory, verifier = RequestFactory(), 'v' * 64
callback = app.redirect_uris.split()[0]
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
req = factory.get('/core/auth/oauth2-provider/authorize/', {
    'client_id': app.client_id, 'redirect_uri': callback, 'response_type': 'code', 'scope': 'read write',
    'state': 's', 'code_challenge': challenge, 'code_challenge_method': 'S256'}, secure=True)
req.user = user
code = parse_qs(urlsplit(AuthorizationView.as_view()(req)['Location']).query)['code'][0]


def token_request(**data):
    response = TokenView.as_view()(factory.post('/core/auth/oauth2-provider/token/', data, secure=True))
    return response.status_code, json.loads(response.content)


status, new = token_request(grant_type='authorization_code', client_id=app.client_id, code=code,
                            redirect_uri=callback, code_verifier=verifier)
check('the desktop client still gets tokens', status == 200 and new.get('refresh_token'), new)
check('a newly issued OAuth token is not stored in plain',
      not raw("SELECT 1 FROM oauth2_provider_accesstoken WHERE token <> ''")
      and not raw("SELECT 1 FROM oauth2_provider_refreshtoken WHERE token <> ''"))
check('it authenticates', OAuth2Validator().validate_bearer_token(new['access_token'], ['read'], SimpleNamespace()))
status, refreshed = token_request(grant_type='refresh_token', client_id=app.client_id,
                                  refresh_token=new['refresh_token'])
check('refresh works with hashed storage', status == 200 and
      OAuth2Validator().validate_bearer_token(refreshed['access_token'], ['read'], SimpleNamespace()), refreshed)
check('the used refresh token is refused the second time', token_request(
    grant_type='refresh_token', client_id=app.client_id, refresh_token=new['refresh_token'])[0] == 400)
response = RevokeTokenView.as_view()(factory.post('/core/auth/oauth2-provider/revoke/', {
    'client_id': app.client_id, 'token': refreshed['access_token']}, secure=True))
check('revoke works with hashed storage', response.status_code == 200 and
      not OAuth2Validator().validate_bearer_token(refreshed['access_token'], ['read'], SimpleNamespace()))

from authentication.serializers import AccessTokenSerializer  # noqa: E402

preview = AccessTokenSerializer(AccessToken.objects.filter(user=user).last()).data['token_preview']
check("the user's token list shows a hash prefix, not the token", preview.startswith('#') and len(preview) == 9, preview)

# clean up the test rows (throwaway database anyway)
ConnectionToken.objects.filter(id=token.id).delete()
AccessToken.objects.filter(user=user).delete()

print(f'RESULT: {sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)

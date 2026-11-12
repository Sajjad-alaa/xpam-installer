"""The desktop client's sign-in (OAuth2 authorization code with PKCE, built-in client) end to end with the image's
packages (oauthlib, django-oauth-toolkit, DRF): authorize -> code on the client's callback -> token -> API call with
the token; and the refusals: no PKCE, a wrong verifier, a foreign redirect, a reused code, a forged token.
  run with tests/security/unit_run.sh <core-image> tests/security/oauth_flow_test.py"""
import base64
import hashlib
import secrets
import urllib.parse

from django.conf import settings
from django.urls import reverse
from rest_framework.test import APIClient

from authentication.backends.oauth2_provider.utils import get_or_create_client_application
from users.models import User

settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:200]}]' if detail != '' else ''), flush=True)


app = get_or_create_client_application()
redirect = settings.OAUTH2_PROVIDER_CLIENT_REDIRECT_URI
admin = User.objects.get(username='admin')
authorize_url = reverse('authentication:oauth2-provider:authorize')
token_url = reverse('authentication:oauth2-provider:token')


def pkce():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    return verifier, challenge


def authorize(client, challenge=None, redirect_uri=redirect):
    params = {'response_type': 'code', 'client_id': app.client_id, 'redirect_uri': redirect_uri, 'state': 'st'}
    if challenge:
        params.update(code_challenge=challenge, code_challenge_method='S256')
    return client.get(authorize_url + '?' + urllib.parse.urlencode(params))


def code_of(response):
    location = response.get('Location', '')
    # (XPAM sends a redirect to another scheme or site through its confirmation page: /core/redirect/confirm/?next=)
    parsed = urllib.parse.urlparse(location)
    if parsed.path.endswith('/redirect/confirm/'):
        location = urllib.parse.parse_qs(parsed.query).get('next', [''])[0]
    return urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get('code', [''])[0], location


browser = APIClient()
browser.force_login(admin)
verifier, challenge = pkce()
r = authorize(browser, challenge)
code, location = code_of(r)
check('authorize answers with a code on the client callback', r.status_code == 302 and location.startswith(redirect)
      and code, (r.status_code, location[:80]))

anon = APIClient()
t = anon.post(token_url, {'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect,
                          'client_id': app.client_id, 'code_verifier': verifier})
body = t.json() if t.status_code == 200 else {}
token = body.get('access_token', '')
check('the code is exchanged for a token', t.status_code == 200 and token, (t.status_code, list(body)))

api = APIClient()
api.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')
p = api.get('/api/v1/users/profile/')
check('the token reaches the API as its user', p.status_code == 200 and p.json().get('username') == 'admin', p.status_code)

t2 = anon.post(token_url, {'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect,
                           'client_id': app.client_id, 'code_verifier': verifier})
check('a code works only once', t2.status_code in (400, 401), t2.status_code)

r = authorize(browser, None)
c, location = code_of(r)
check('authorize without PKCE gives no code', not c, (r.status_code, location[:100]))

verifier2, challenge2 = pkce()
r = authorize(browser, challenge2)
c2, _ = code_of(r)
t3 = anon.post(token_url, {'grant_type': 'authorization_code', 'code': c2, 'redirect_uri': redirect,
                           'client_id': app.client_id, 'code_verifier': secrets.token_urlsafe(48)})
check('a wrong PKCE verifier gets no token', t3.status_code in (400, 401), t3.status_code)

r = authorize(browser, challenge, redirect_uri='https://evil.example/callback')
c4, location = code_of(r)
check('a foreign redirect gets no code', not c4 and not location.startswith('https://evil.example'),
      (r.status_code, location[:100]))

forged = APIClient()
forged.credentials(HTTP_AUTHORIZATION='Bearer ' + secrets.token_urlsafe(30))
check('a forged token is refused', forged.get('/api/v1/users/profile/').status_code == 401)

print(f'DONE {sum(results)}/{len(results)} passed', flush=True)

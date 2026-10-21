"""Rehearsal probe, run inside xpam_core: python /tmp/p.py alerts | messages <text> | status"""
import os
import sys

sys.path.insert(0, '/opt/jumpserver/apps')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django  # noqa: E402

django.setup()
from django.conf import settings  # noqa: E402

settings.ALLOWED_HOSTS = ['*']
from rest_framework.test import APIClient  # noqa: E402
from users.models import User  # noqa: E402

admin = User.objects.get(username='admin')
c = APIClient()
c.force_authenticate(admin)
mode = sys.argv[1]
if mode == 'alerts':
    data = c.get('/api/v1/xpack/admin/banner-alerts/').json()
    print('ALERTS', sorted(a['id'] for a in data.get('alerts', []) if a.get('category') == 'ha'))
elif mode == 'messages':
    from notifications.models import SiteMessage
    n = SiteMessage.objects.filter(user=admin, content__subject__icontains=sys.argv[2]).count()
    print('MESSAGES', n)
elif mode == 'status':
    d = c.get('/api/v1/settings/ha/status/').json()
    print('API', d.get('enabled'), sorted(m['role'] for m in d.get('members', [])), (d.get('agent') or {}).get('role'))

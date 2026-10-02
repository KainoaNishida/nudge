#!/usr/bin/env python3
"""Embed only public project configuration. API/provider secrets never belong in the app."""
import os, plistlib, sys
from urllib.parse import urlparse
url = os.environ.get('NUDGE_SUPABASE_URL', '')
key = os.environ.get('NUDGE_SUPABASE_PUBLISHABLE_KEY', '')
if bool(url) != bool(key):
    raise SystemExit('Both NUDGE_SUPABASE_URL and NUDGE_SUPABASE_PUBLISHABLE_KEY are required.')
if not url:
    raise SystemExit(0)
if urlparse(url).scheme != 'https' or not urlparse(url).hostname:
    raise SystemExit('Managed service URL must be HTTPS.')
if not key.startswith('sb_publishable_'):
    raise SystemExit('Use a Supabase publishable key, never a backend secret/service-role key.')
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
info.update(NudgeSupabaseURL=url, NudgeSupabasePublishableKey=key)
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f)

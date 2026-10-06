"""Bounded provider checks. Never return provider bodies or credential values."""
import json
import urllib.request
import urllib.error
from installer_core import validation_request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, 'Redirect refused', headers, fp)

def check_provider_key(provider, key):
    if not isinstance(key, str) or not key.strip() or any(c in key for c in '\r\n\0'):
        return False, 'Enter a single-line API key.'
    if provider not in ('openrouter', 'anthropic', 'zai'):
        return False, 'Choose a supported provider.'
    data = None
    if provider == 'zai':
        url = 'https://api.z.ai/api/paas/v4/chat/completions'
        headers = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}
        data = json.dumps({'model':'glm-4.5-flash', 'messages':[{'role':'user','content':'Reply OK.'}],
                           'max_tokens':16, 'thinking':{'type':'disabled'}, 'stream':False}).encode()
    else:
        url, headers = validation_request(provider, key)
    try:
        request = urllib.request.Request(url, headers=headers, data=data)
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
            if response.status != 200:
                return False, 'Unexpected provider response. Please retry.'
            payload = json.loads(response.read(262144))
        if not isinstance(payload, dict):
            return False, 'Unexpected provider response. Please retry.'
        field = 'choices' if provider == 'zai' else 'data'
        expected = dict if provider == 'openrouter' else list
        if not isinstance(payload.get(field), expected) or (provider == 'zai' and not payload[field]):
            return False, 'Unexpected provider response. Please retry.'
        return True, 'Provider access verified. You can continue.'
    except urllib.error.HTTPError as error:
        if error.code == 401:
            return False, 'The provider rejected this API key. Check it and retry.'
        if error.code in (402,403):
            return False, 'Provider access denied. Check key permissions, plan or balance.'
        if error.code == 429:
            return False, 'Provider rate limit reached. Wait and retry.'
        return False, f'Provider check failed (HTTP {error.code}). Please retry.'
    except (OSError, ValueError, urllib.error.URLError):
        return False, 'Could not reach or read the provider. Check your connection and retry.'

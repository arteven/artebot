import os, urllib.request, json
k=os.environ.get('ECHO_KEY','')
print('sandbox env ECHO_KEY shape:', k[:22]+'...', 'len', len(k), 'placeholder' if k.startswith('openshell:') else 'NOT-placeholder')
req=urllib.request.Request('http://host.openshell.internal:9999/v1/echo', data=b'{"hi":1}', headers={'x-api-key':k,'content-type':'application/json'})
try:
    r=urllib.request.urlopen(req, timeout=20); print('HTTP', r.status, r.read().decode())
except Exception as e:
    print('ERR', type(e).__name__, getattr(e,'code',''), (e.read().decode()[:300] if hasattr(e,'read') else str(e)))

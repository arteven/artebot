# plain HTTP echo: logs request headers (only the x-api-key value is redacted to a prefix/len/sha256 so no secret is printed)
import http.server, json, hashlib, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s): s.do_GET()
    def do_GET(s):
        k=s.headers.get('x-api-key')
        rec=dict(path=s.path, has_key=k is not None, key_len=len(k or ''), key_prefix=(k or '')[:14], key_sha256=hashlib.sha256((k or '').encode()).hexdigest()[:16], is_placeholder=(k or '').startswith('openshell:'))
        open('/home/smoke/echo.log','a').write(json.dumps(rec)+'\n')
        b=json.dumps(rec).encode(); s.send_response(200); s.send_header('content-length',str(len(b))); s.end_headers(); s.wfile.write(b)
    def log_message(s,*a): pass
http.server.ThreadingHTTPServer(('0.0.0.0',9999),H).serve_forever()

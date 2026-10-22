from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parent
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path!='/': self.send_error(404); return
        data=(ROOT/'index.html').read_bytes()
        self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    def do_POST(self):
        if self.path!='/report':self.send_error(404);return
        n=int(self.headers.get('Content-Length','0'))
        if n>20000:self.send_error(413);return
        data=json.loads(self.rfile.read(n))
        with (ROOT/'browser-evidence.jsonl').open('a') as out:out.write(json.dumps(data,ensure_ascii=False)+'\n')
        self.send_response(204);self.end_headers()
    def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(f'http://127.0.0.1:{server.server_port}/',flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()

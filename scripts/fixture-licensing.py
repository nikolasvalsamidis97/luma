"""Loopback-only integration fixture. NEVER deploy this test wrapper."""
import json, os, sys
from pathlib import Path
from wsgiref.simple_server import make_server, WSGIRequestHandler
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'licensing-server'))
from service import Service, Application
root=Path(sys.argv[1]); service=Service(str(root/'fixture.sqlite3'))
lid,key=service.issue(seats=1,label='Temporary UI check')
(root/'key').write_text(key); os.chmod(root/'key',0o600)
real=Application(service)
def app(env,start):
    path=env['PATH_INFO']
    if path=='/test/expire':
        with service.db() as db: db.execute("UPDATE licenses SET trial_end=0 WHERE kind='standard'")
    elif path=='/test/revoke': service.revoke(lid)
    elif path=='/test/restore':
        with service.db() as db: db.execute('UPDATE licenses SET revoked=0 WHERE id=?',(lid,))
    else: return real(env,start)
    start('200 OK',[('Content-Type','application/json')]); return [b'{}']
class Quiet(WSGIRequestHandler):
    def log_message(self,*args): pass
server=make_server('127.0.0.1',0,app,handler_class=Quiet)
(root/'port').write_text(str(server.server_port)); server.serve_forever()

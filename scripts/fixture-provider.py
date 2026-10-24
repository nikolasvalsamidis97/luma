"""Local-only integration fixture. Run after make-test-video.swift. Not shipped in Luma."""
import base64
import json
import time
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

VIDEO = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / '.build/playback-fixture.mp4'

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log credential-bearing URLs.

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != '/player_api.php':
            if not parsed.path.startswith(('/live/', '/movie/', '/series/')):
                self.send_error(404)
                return
            data = VIDEO.read_bytes()
            start, end = 0, len(data) - 1
            requested = self.headers.get('Range')
            if requested:
                bounds = requested.removeprefix('bytes=').split('-')
                start = int(bounds[0] or 0)
                end = min(int(bounds[1]) if bounds[1] else end, end)
            self.send_response(206 if requested else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            if requested:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
            self.send_header('Content-Length', str(end - start + 1))
            self.end_headers()
            self.wfile.write(data[start:end + 1])
            return
        query = parse_qs(parsed.query)
        action = query.get('action', [''])[0]
        if query.get('username') != ['fixture'] or query.get('password') != ['fixture']:
            response = {'user_info': {'auth': 0}}
        elif action.endswith('_categories'):
            response = [{'category_id': '1', 'category_name': 'Local playback test'}]
        elif action in ('get_live_streams', 'get_vod_streams'):
            response = [{'stream_id': 1, 'name': 'Local H.264 test', 'category_id': '1', 'container_extension': 'mp4'}]
        elif action == 'get_series':
            response = [{'series_id': 1, 'name': 'Local test series', 'category_id': '1', 'plot': 'Local integration fixture.'}]
        elif action == 'get_series_info':
            response = {'episodes': {'1': [{'id': 101, 'season': 1, 'episode_num': 1, 'title': 'Test episode 1', 'container_extension': 'mp4'}, {'id': 102, 'season': 1, 'episode_num': 2, 'title': 'Test episode 2', 'container_extension': 'mp4'}], '2': [{'id': 201, 'season': 2, 'episode_num': 1, 'title': 'Season 2 premiere', 'container_extension': 'mp4'}]}}
        elif action == 'get_short_epg':
            response = {'epg_listings': [{'id': '1', 'title': base64.b64encode(b'Local playback test').decode(), 'start_timestamp': str(int(time.time()) - 60), 'stop_timestamp': str(int(time.time()) + 3600)}]}
        else:
            response = {'user_info': {'auth': 1, 'status': 'Active'}}
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 18765), Handler)
if len(sys.argv) > 3:
    Path(sys.argv[3]).write_text(str(server.server_port))
print(f'Local fixture listening on http://127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()

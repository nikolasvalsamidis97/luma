"""Local-only playlist fixture. Never uses a real provider or saved login."""
import http.server
import json
import pathlib
import sys
import urllib.parse
video = pathlib.Path(sys.argv[1]).read_bytes()
changed = False
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        global changed
        path = urllib.parse.urlsplit(self.path).path
        if path == '/advance':
            changed = True
            body = b'ok'
        elif path == '/start':
            self.send_response(302)
            self.send_header('Location', '/folder/list.m3u')
            self.end_headers()
            return
        elif path == '/fail':
            self.send_response(403)
            self.end_headers()
            return
        elif path == '/player_api.php':
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            user = query.get('username', [''])[0]
            action = query.get('action', [''])[0]
            if user == 'bad':
                self.send_response(403)
                self.end_headers()
                return
            if action.endswith('_categories'):
                value = [{'category_id': '1', 'category_name': 'Fixture category'}]
            elif action == 'get_vod_streams':
                value = [{'stream_id': '1', 'name': user + ' movie', 'container_extension': 'mp4'}]
            elif action == 'get_live_streams':
                value = [{'stream_id': '1', 'name': user + ' channel'}]
            elif action == 'get_series':
                value = [{'series_id': '1', 'name': user + ' series'}]
            else:
                value = {'user_info': {'auth': 1, 'status': 'Active'}}
            body = json.dumps(value).encode()
        elif path.endswith('.m3u') or path == '/other':
            old = '' if changed else '#EXTINF:-1 tvg-type="movie" group-title="Films",Fixture movie\nvideo.mp4?token=fixture-movie\n'
            body = (f'#EXTM3U\n{old}'
                    '#EXTINF:-1 tvg-type="live" group-title="News",Fixture channel\nvideo.mp4?token=fixture-live\n'
                    '#EXTINF:-1 group-title="Drama",Fixture show S01E01\nvideo.mp4?token=fixture-ep1\n'
                    '#EXTINF:-1 group-title="Drama",Fixture show S02E01\nvideo.mp4?token=fixture-ep2\n').encode()
        elif path.endswith('video.mp4'):
            body = video
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'video/mp4' if path.endswith('video.mp4') else 'text/plain')
        self.end_headers()
        self.wfile.write(body)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()

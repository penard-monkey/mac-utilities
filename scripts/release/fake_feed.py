#!/usr/bin/python3
"""Serve local release artifacts over loopback for isolated native Updates testing."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import unquote


class Handler(SimpleHTTPRequestHandler):
    def do_HEAD(self):
        if self.path == '/releases/latest':
            self.send_response(302)
            self.send_header('Location', '/releases/tag/'+self.server.tag)
            self.end_headers()
        elif self.path == '/releases/tag/'+self.server.tag:
            self.send_response(200)
            self.end_headers()
        else:
            self.send_error(404)

    def do_GET(self):
        prefix = '/releases/download/'+self.server.tag+'/'
        if not self.path.startswith(prefix):
            self.send_error(404)
            return
        name = unquote(self.path[len(prefix):])
        if Path(name).name != name or not name or name.startswith('.'):
            self.send_error(404)
            return
        self.path = '/'+name
        super().do_GET()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(args.artifacts.resolve())))
    server.tag = json.loads((args.artifacts/'release.json').read_text())['tag']
    print('http://127.0.0.1:'+str(server.server_port), flush=True)
    server.serve_forever()

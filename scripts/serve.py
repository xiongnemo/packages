"""Serve a built site locally, honouring its _redirects the way Pages does.

Usage: serve.py SITE PORT

Static rules are tried first, then dynamic ones (`:placeholder` matches one
path segment, `*` the rest, `:splat` in the destination) in file order, which is
how Cloudflare Pages and Netlify resolve them. Every request is logged so a test
can show which paths were served and which were redirected to GitHub.
"""

import http.server
import re
import sys
from functools import partial
from pathlib import Path

site, port = Path(sys.argv[1]), int(sys.argv[2])
static, dynamic = {}, []
for line in (site / "_redirects").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    source, destination, *rest = line.split()
    code = int(rest[0]) if rest else 302
    if ":" in source or "*" in source:
        pattern = re.escape(source).replace(r"\*", "(?P<splat>.*)")
        pattern = re.sub(r":(\w+)", r"(?P<\1>[^/]+)", pattern)
        dynamic.append((re.compile(f"^{pattern}$"), destination, code))
    else:
        static[source] = (destination, code)


def resolve(path):
    if path in static:
        return static[path]
    for pattern, destination, code in dynamic:
        match = pattern.match(path)
        if match:
            for key, value in match.groupdict().items():
                destination = destination.replace(f":{key}", value)
            return destination, code
    return None


class Handler(http.server.SimpleHTTPRequestHandler):
    def _redirect(self):
        target = resolve(self.path.split("?", 1)[0])
        if not target:
            return False
        location, code = target
        self.send_response(code)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()
        print(f"{code} {self.path} -> {location}", flush=True)
        return True

    def do_GET(self):
        if not self._redirect():
            print(f"200 {self.path}", flush=True)
            super().do_GET()

    def do_HEAD(self):
        if not self._redirect():
            super().do_HEAD()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=str(site))).serve_forever()

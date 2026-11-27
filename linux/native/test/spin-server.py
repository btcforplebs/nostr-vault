"""spin-stage.sh's stand-in vault: a web app whose first copy spins, and is kept in WebKit's cache for a year.

  python3 -I spin-server.py <port> <request log> <sign-in token>

"/" is never cached and loads /app.js. The first /app.js the server sends saves a sign-in (localStorage nv-session,
holding the token) and then runs a loop that never ends: the page's web process at 100% CPU, making no system calls,
as on Guy's machine (2026-11-27). It is sent as cacheable for a year (immutable), so WebKit loads that copy from its
cache in every later window, in every drawing mode, without asking again: only a window whose cache was cleared asks.
Every later /app.js draws a page (a gradient and text: many colours) and reports the nv-session it finds to /saw, so
the test can see that the sign-in survived the fresh cache. Each request is one line in the request log.
"""
import http.server
import sys
import urllib.parse

PORT, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3]
sent = {"app": 0}

INDEX = b"""<!doctype html><html><head><meta charset="utf-8"><title>spin test</title></head>
<body style="margin:0;background:#000"><script src="/app.js"></script></body></html>"""

SPIN = ("""try { localStorage.setItem("nv-session", JSON.stringify({ pubkey: "%s", method: "readonly" })) } catch (e) {}
for (;;) {}
""" % TOKEN).encode()

GOOD = b"""const s = localStorage.getItem("nv-session")
fetch("/saw?" + encodeURIComponent(s || "nothing"))
document.body.innerHTML = '<div style="height:100vh;background:linear-gradient(135deg,#f00,#ff0,#0f0,#0ff,#00f,#f0f);'
  + 'font:40px sans-serif;color:#fff;padding:40px">Fresh copy of the web app. Signed in as: '
  + (s || "nobody").replace(/</g, "&lt;") + '</div>'
"""


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, body, ctype, cache):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"GET {urllib.parse.unquote(self.path)}\n")
        if path == "/app.js":
            sent["app"] += 1
            if sent["app"] == 1:
                self.send(SPIN, "text/javascript", "public, max-age=31536000, immutable")
            else:
                self.send(GOOD, "text/javascript", "no-store")
        elif path == "/saw":
            self.send(b"ok", "text/plain", "no-store")
        else:
            self.send(INDEX, "text/html; charset=utf-8", "no-store")


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

"""spin-stage.sh's stand-in vault for the safe start: a web app that spins because of its own saved data.

  python3 -I safe-server.py <port> <request log> <token>

Nothing is ever cached (no-store), so a fresh WebKit cache can't help. /app.js, on a page with nothing saved, saves a
sign-in and a key the way the web vault does (localStorage nv-session, nv-accounts with an ncryptsec, a cookie, the
nv-keyring database, an account's wallet, drafts and outbox), plus a feed database ("haven:<pk>:feed") holding a
record that makes it spin; it reports /seeded and then loops forever. Any later load that finds that feed record
spins at once. One that finds no feed record but the keyring key draws a page (many colours) and reports to /saw
everything it found, so the test sees the sign-in and every key survived the safe start.
"""
import http.server
import sys
import urllib.parse

PORT, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3]
PK = "ab" * 32

INDEX = b"""<!doctype html><html><head><meta charset="utf-8"><title>safe test</title></head>
<body style="margin:0;background:#000"><script src="/app.js"></script></body></html>"""

APP = ("""const T = "%s", PK = "%s", DBS = ["nv-keyring", "haven:" + PK + ":wallet", "haven:" + PK + ":drafts",
  "haven:" + PK + ":outbox", "haven:" + PK + ":feed"]
const open = n => new Promise((ok, no) => { const r = indexedDB.open(n, 1)
  r.onupgradeneeded = () => r.result.createObjectStore("s"); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error) })
const get = (db, k) => new Promise(ok => { const r = db.transaction("s").objectStore("s").get(k)
  r.onsuccess = () => ok(r.result); r.onerror = () => ok(undefined) })
const put = (db, k, v) => new Promise((ok, no) => { const t = db.transaction("s", "readwrite"); t.objectStore("s").put(v, k)
  t.oncomplete = ok; t.onerror = () => no(t.error) })
const spin = () => { for (;;) {} }
;(async () => {
  const dbs = await Promise.all(DBS.map(open)), [key, wallet, drafts, outbox, feed] = dbs
  if (await get(feed, "poison")) spin()
  const k = await get(key, "sealing")
  if (!k) {
    localStorage.setItem("nv-session", JSON.stringify({ pubkey: PK, method: "local", t: T }))
    localStorage.setItem("nv-accounts", JSON.stringify([{ pubkey: PK, method: "local", ncryptsec: "ncryptsec1" + T }]))
    document.cookie = "nvc=" + T + "; max-age=31536000; path=/"
    await put(key, "sealing", "key-" + T); await put(wallet, "nwc", "nwc-" + T)
    await put(drafts, "d1", "draft-" + T); await put(outbox, "e1", "unsent-" + T)
    await put(feed, "poison", "spin")
    for (const db of dbs) db.close()
    await fetch("/seeded")
    setTimeout(spin, 300)
    return
  }
  const acc = JSON.parse(localStorage.getItem("nv-accounts") || "[]")[0] || {}
  const c = (document.cookie.match(/(?:^|; )nvc=([^;]*)/) || [])[1]
  const saw = { session: JSON.parse(localStorage.getItem("nv-session") || "{}").t, ncryptsec: acc.ncryptsec, cookie: c,
    key: k, wallet: await get(wallet, "nwc"), draft: await get(drafts, "d1"), outbox: await get(outbox, "e1"),
    feed: (await get(feed, "poison")) || "empty" }
  fetch("/saw?" + new URLSearchParams(saw))
  document.body.innerHTML = '<div style="height:100vh;background:linear-gradient(135deg,#f00,#ff0,#0f0,#0ff,#00f,#f0f);'
    + 'font:40px sans-serif;color:#fff;padding:40px">Safe start: signed in, saved feed gone</div>'
})()
""" % (TOKEN, PK)).encode()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"GET {urllib.parse.unquote(self.path)}\n")
        body, ctype = (APP, "text/javascript") if path == "/app.js" else \
            (b"ok", "text/plain") if path in ("/saw", "/seeded") else (INDEX, "text/html; charset=utf-8")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

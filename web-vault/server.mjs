// Local server for the built app: serves dist/ under /vault/ (the site layout). Open it as http://localhost:PORT/vault/,
// which is a secure context (service worker, storage.persist, IndexedDB); on a phone, via `adb reverse`.
import http from "node:http"; import fs from "node:fs"; import path from "node:path"
import { loaderCsp, LOADER_FILE, nappletOriginFile } from "./src/napplet/csp.js"
import { nappletParentHost } from "./src/napplet/origin.js"
const root = path.resolve("dist"), port = Number(process.env.PORT || 8799)
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".json": "application/json", ".css": "text/css" }
http.createServer((req, res) => {
  // A napplet's own origin (n-<id>.localhost:PORT, src/napplet/origin.js): its loader and service worker, nothing else.
  const parentHost = nappletParentHost(req.headers.host)
  if (parentHost) {
    const hit = nappletOriginFile(new URL(req.url, "http://x").pathname, { host: req.headers.host, vaultHosts: [parentHost, parentHost.replace(/^localhost/, "127.0.0.1")] })
    if (!hit) { res.statusCode = 404; return res.end() }
    for (const [k, v] of Object.entries(hit.headers)) res.setHeader(k, v)
    res.setHeader("Content-Type", hit.type)
    return res.end(fs.readFileSync(path.join(root, hit.file)))
  }
  const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/vault(\/|$)/, "/")
  let p = path.join(root, pathname)
  // A path boundary, not a string prefix: "%2e%2e%2fdist-secret" must not reach a sibling of root.
  if (p !== root && !p.startsWith(root + path.sep)) { res.statusCode = 403; return res.end() }
  if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, "index.html")
  if (!fs.existsSync(p)) p = path.join(root, "index.html")
  res.setHeader("Content-Type", types[path.extname(p)] || "application/octet-stream")
  // Vite's assets/ names carry a content hash, so they never change; everything else revalidates (ETag, 304).
  res.setHeader("Cache-Control", /\/assets\//.test(p.slice(root.length)) ? "public, max-age=31536000, immutable" : "no-cache")
  // The napplet loader's own CSP, as nginx sends it (src/napplet/csp.js).
  if (p === path.join(root, LOADER_FILE)) res.setHeader("Content-Security-Policy", loaderCsp())
  send(req, res, p)
}).listen(port, () => console.log(`http://localhost:${port}/vault/`))

// The build writes .br and .gz next to each big file (vite.config.js precompress); send the smallest one the browser takes.
function send(req, res, p) {
  const ae = req.headers["accept-encoding"] || ""
  const [file, enc] = [[`${p}.br`, "br"], [`${p}.gz`, "gzip"]].find(([f, e]) => new RegExp(`\\b${e}\\b(?!\\s*;\\s*q=0(\\.0*)?\\s*(,|$))`).test(ae) && fs.existsSync(f)) || [p]
  const st = fs.statSync(file), etag = `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`
  res.setHeader("Vary", "Accept-Encoding")
  res.setHeader("ETag", etag)
  if (req.headers["if-none-match"] === etag) { res.statusCode = 304; return res.end() }
  if (enc) res.setHeader("Content-Encoding", enc)
  res.setHeader("Content-Length", st.size)
  fs.createReadStream(file).pipe(res)
}

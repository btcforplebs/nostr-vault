// Local server for the built app: serves dist/ under /vault/ (the site layout). Open it as http://localhost:PORT/vault/,
// which is a secure context (service worker, storage.persist, IndexedDB); on a phone, via `adb reverse`.
import http from "node:http"; import fs from "node:fs"; import path from "node:path"
const root = path.resolve("dist"), port = Number(process.env.PORT || 8799)
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".json": "application/json", ".css": "text/css" }
http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/vault(\/|$)/, "/")
  let p = path.join(root, pathname)
  if (!p.startsWith(root)) { res.statusCode = 403; return res.end() }
  if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, "index.html")
  if (!fs.existsSync(p)) p = path.join(root, "index.html")
  res.setHeader("Content-Type", types[path.extname(p)] || "application/octet-stream")
  res.setHeader("Cache-Control", "no-cache")
  fs.createReadStream(p).pipe(res)
}).listen(port, () => console.log(`http://localhost:${port}/vault/`))

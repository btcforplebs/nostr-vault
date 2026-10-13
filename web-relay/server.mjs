// Local dev server: serves ../website/relay/ under /relay/ (the site layout) and appends POST /beacon bodies to beacons.jsonl.
import http from "node:http"; import fs from "node:fs"; import path from "node:path"
const root = path.resolve("../website/relay"), port = Number(process.env.PORT || 8080)
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json", ".json": "application/json" }
http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/relay(\/|$)/, "/")
  if (req.method === "POST" && pathname === "/beacon") {
    let b = ""; req.on("data", c => { b += c; if (b.length > 1e5) req.destroy() })
    req.on("end", () => { fs.appendFileSync("beacons.jsonl", JSON.stringify({ rx: new Date().toISOString(), ip: req.socket.remoteAddress, ...safe(b) }) + "\n"); res.end("ok") })
    return
  }
  let p = path.join(root, pathname)
  if (!p.startsWith(root)) { res.statusCode = 403; return res.end() }
  if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, "index.html")
  if (!fs.existsSync(p)) p = path.join(root, "index.html")
  res.setHeader("Content-Type", types[path.extname(p)] || "application/octet-stream")
  res.setHeader("Cache-Control", "no-cache")
  fs.createReadStream(p).pipe(res)
}).listen(port, () => console.log("listening", port))
function safe(b) { try { return JSON.parse(b) } catch { return { raw: b.slice(0, 500) } } }

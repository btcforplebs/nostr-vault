import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { npubEncode } from "nostr-tools/nip19"
import { mountFipsPanel } from "./src/fips/panel.js"
import { loadOwners } from "./src/fips/owners.js"
import { loadHaven } from "./src/haven/haven.js"
import { HavenClient } from "./src/haven/client.js"

const $ = id => document.getElementById(id)
const LS = localStorage
const pageStart = Date.now()
const sid = Math.random().toString(36).slice(2, 8)
const ua = navigator.userAgent
const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true

// ---- log: kept in localStorage (survives reload) and beaconed to the dev server when reachable
const logLines = JSON.parse(LS.getItem("log") || "[]")
function log(type, data = {}) {
  const rec = { t: new Date().toISOString(), sid, type, vis: document.visibilityState, ...data }
  logLines.push(rec); while (logLines.length > 500) logLines.shift()
  LS.setItem("log", JSON.stringify(logLines))
  $("log").textContent = logLines.slice(-60).map(r => JSON.stringify(r)).reverse().join("\n")
  beacon(rec)
}
// Beacons only go to the local dev server; on the static site the report below is the measurement.
const beaconOn = ["localhost", "127.0.0.1"].includes(location.hostname)
function beacon(rec) {
  if (!beaconOn) return
  try { navigator.sendBeacon("/beacon", JSON.stringify({ ...rec, ua, standalone })) } catch {}
}

// ---- previous session's last heartbeat => how long did it live / what was the gap
const prev = JSON.parse(LS.getItem("hb") || "null")
const fmt = ms => { const s = Math.floor(ms / 1000); return `${Math.floor(s / 3600)}h${String(Math.floor(s / 60) % 60).padStart(2, "0")}m${String(s % 60).padStart(2, "0")}s` }

// ---- throwaway key for synthetic test events (never a real account). Haven only stores outbox notes from its
// owner or whitelist, so this key is whitelisted; it lives in this page's storage, same trust as the relay itself.
let skHex = LS.getItem("sk")
if (!skHex) { skHex = bytesToHex(generateSecretKey()); LS.setItem("sk", skHex) }
const sk = hexToBytes(skHex), pk = getPublicKey(sk)

// Haven runs in this page; the page reads and writes through its own stream on the outbox route, so its
// writes pass the same policies as anyone else's and reach live FIPS subscriptions through Haven.
let haven, relay
let count = 0, seq = Number(LS.getItem("seq") || 0)

async function addEvent(tag = "gen") {
  const ev = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [["t", "nv-web-relay"]], content: `${tag} #${++seq} ${new Date().toISOString()}` }, sk)
  LS.setItem("seq", seq)
  const r = await relay.event(ev)
  if (!r.ok) log("event-rejected", { msg: r.message })
  return r.ok
}
async function refreshCount() { if (!relay) return; count = await relay.count({ kinds: [1], authors: [pk] }); $("count").textContent = $("scount").textContent = count }

// ---- wake lock / screensaver
let lock = null, saverOn = false
async function takeLock() {
  try {
    lock = await navigator.wakeLock.request("screen")
    log("wakelock-acquired")
    lock.addEventListener("release", () => { log("wakelock-released"); lock = null; updLock() })
  } catch (e) { log("wakelock-error", { err: String(e) }) }
  updLock()
}
function updLock() { $("slock").textContent = "wake lock: " + (lock ? "held" : "NOT held") }
$("start").onclick = async () => { saverOn = true; $("saver").classList.add("on"); LS.setItem("saver", "1"); await takeLock() }
$("saver").onclick = () => { saverOn = false; $("saver").classList.remove("on"); LS.setItem("saver", "0"); lock?.release() }
document.addEventListener("visibilitychange", () => { log("visibility"); if (document.visibilityState === "visible" && saverOn && !lock) takeLock() })
for (const ev of ["pagehide", "pageshow", "freeze", "resume", "online", "offline"]) addEventListener(ev, e => log(ev, { persisted: e.persisted }))
document.addEventListener("freeze", () => log("freeze")); document.addEventListener("resume", () => log("resume"))

// Measurement generator: off unless turned on on this device (it writes test notes from a throwaway key).
let genOn = LS.getItem("gen") === "1"
$("gen").textContent = "Generator: " + (genOn ? "on" : "off")
$("gen").onclick = () => { genOn = !genOn; LS.setItem("gen", genOn ? "1" : "0"); $("gen").textContent = "Generator: " + (genOn ? "on" : "off") }
$("burst").onclick = async () => { if (!relay) return; const t = Date.now(); let ok = 0; for (let i = 0; i < 1000; i++) ok += await addEvent("burst"); await refreshCount(); log("burst", { ms: Date.now() - t, accepted: ok, count }); await info() }
// Signature self-test: a valid event must be accepted and a tampered copy rejected by the relay itself.
async function sigSelfTest() {
  const good = finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [["t", "nv-web-relay-selftest"]], content: "selftest " + Date.now() }, sk)
  const forged = { ...good, content: good.content + " tampered" }
  const badSig = { ...good, id: good.id, sig: good.sig.slice(0, -2) + (good.sig.endsWith("00") ? "11" : "00") }
  const r = { good: await relay.event(good), forged: await relay.event(forged), badSig: await relay.event(badSig) }
  const stored = await relay.query({ ids: [good.id] })
  const pass = r.good.ok && !r.forged.ok && !r.badSig.ok && stored.length === 1
  return { pass, good: r.good.ok, forged: r.forged.message, badSig: r.badSig.message, goodStored: stored.length }
}

// Overnight report: the generator writes one event every 10s, so gaps in created_at are the time the page was not running.
async function report() {
  const evs = await relay.query({ kinds: [1], authors: [pk], "#t": ["nv-web-relay"] })
  const ts = evs.map(e => e.created_at).sort((a, b) => a - b)
  const gaps = []
  for (let i = 1; i < ts.length; i++) if (ts[i] - ts[i - 1] > 30) gaps.push({ from: new Date(ts[i - 1] * 1000).toISOString(), to: new Date(ts[i] * 1000).toISOString(), down: fmt((ts[i] - ts[i - 1]) * 1000) })
  const span = ts.length ? ts[ts.length - 1] - ts[0] : 0
  const est = await navigator.storage.estimate()
  const ev = t => logLines.filter(l => l.type === t).length
  return {
    origin: location.origin + location.pathname, standalone, persisted: await navigator.storage.persisted(),
    quotaMB: Math.round(est.quota / 1048576), usageMB: +(est.usage / 1048576).toFixed(2),
    events: ts.length, first: ts.length && new Date(ts[0] * 1000).toISOString(), last: ts.length && new Date(ts[ts.length - 1] * 1000).toISOString(),
    span: fmt(span * 1000), gapsOver30s: gaps.length, gaps: gaps.slice(-40),
    counts: { boots: ev("boot"), hidden: logLines.filter(l => l.type === "visibility" && l.vis === "hidden").length, wakeLockReleased: ev("wakelock-released"), freeze: ev("freeze"), pagehide: ev("pagehide") },
    selftest: relay ? await sigSelfTest() : "haven not running", ua,
  }
}
$("report").onclick = async () => { if (!relay) return; const r = await report(); $("info").textContent = JSON.stringify(r, null, 1); log("report", { events: r.events, gaps: r.gapsOver30s, selftest: r.selftest.pass }) }
$("copyrep").onclick = async () => navigator.clipboard.writeText(JSON.stringify(await report(), null, 1))
$("copy").onclick = () => navigator.clipboard.writeText(JSON.stringify(logLines, null, 1))

async function info() {
  const est = await navigator.storage.estimate()
  const persisted = await navigator.storage.persisted()
  const lines = {
    session: sid, standalone, pubkey: pk.slice(0, 16) + "…",
    persisted, quotaMB: (est.quota / 1048576).toFixed(0), usageMB: (est.usage / 1048576).toFixed(2),
    wakeLockAPI: "wakeLock" in navigator, prevSession: prev && { sid: prev.sid, lived: fmt(prev.last - prev.start), lastBeat: new Date(prev.last).toISOString(), gapToNow: fmt(pageStart - prev.last) },
    ua,
  }
  $("info").textContent = JSON.stringify(lines, null, 1)
  return lines
}

// Haven needs its owner at start: the first saved owner is Haven's owner, any others and the test key are whitelisted.
async function startHaven(owners) {
  const [owner, ...rest] = [...owners]
  const t = Date.now()
  haven = await loadHaven()
  const loadMs = Date.now() - t
  await haven.start({ ownerNpub: npubEncode(owner), whitelist: [...rest.map(npubEncode), npubEncode(pk)] })
  relay = new HavenClient(haven.conn("page", { mode: "nip01", route: "/" }))
  return { loadMs, startMs: Date.now() - t - loadMs }
}

;(async () => {
  const owners = loadOwners({ log })
  try {
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(e => log("sw-error", { err: String(e) }))
    const persistGranted = await navigator.storage.persist()
    if (!owners.size) {
      $("status").textContent = "Add your vault's npub below to start Haven"
      log("boot", { haven: false, persistGranted })
    } else {
      const ms = await startHaven(owners)
      await refreshCount()
      const i = await info()
      log("boot", { haven: true, ...ms, count, persistGranted, quotaMB: i.quotaMB, usageMB: i.usageMB, prev: i.prevSession })
      $("status").textContent = `Haven ready (owner ${npubEncode([...owners][0]).slice(0, 16)}…)`
    }
  } catch (e) { $("status").textContent = "HAVEN FAILED TO START: " + e; log("init-error", { err: String(e) }); haven = relay = undefined }
  mountFipsPanel({ haven, owners, log })

  // heartbeat every 5s; generator event every 10s; beacon a heartbeat every 60s
  let n = 0
  setInterval(async () => {
    n++
    LS.setItem("hb", JSON.stringify({ sid, start: pageStart, last: Date.now() }))
    $("uptime").textContent = $("suptime").textContent = fmt(Date.now() - pageStart)
    if (relay && genOn && n % 2 === 0) { try { await addEvent() } catch (e) { log("event-error", { err: String(e) }) } }
    if (n % 2 === 0) await refreshCount().catch(() => {})
    if (n % 12 === 0) beacon({ t: new Date().toISOString(), sid, type: "hb", vis: document.visibilityState, uptime: fmt(Date.now() - pageStart), count, lock: !!lock })
  }, 5000)
})()

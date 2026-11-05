// Settings › Relays: whether each relay answers from this browser and, when it doesn't, why (iPhone RelayProbe.swift
// and RelayFailReason.swift, Logen 2026-11-05 parity N2). A probe opens a socket, asks for one event and times the
// first answer (EVENT, EOSE, NOTICE or CLOSED all count), with one retry 1.5 s later before calling a relay down.
// A browser never says why a WebSocket failed, so after a failure the relay's NIP-11 address is asked over HTTPS: an
// answer gives the iPhone's HTTP reasons; none (the server doesn't allow it, or isn't there) leaves "not answering".
// Nothing is signed or published.

export const TIMEOUT_MS = 6000
export const RETRY_MS = 1500
/** Slower than this shows as "slow" (RelayProbe.slowMilliseconds). */
export const SLOW_MS = 500
const HTTP_WAIT_MS = 4000

/** RelayFailReason.noAnswer. */
export const noAnswer = ms => `no answer in ${Math.round(ms / 1000)} s`

/** RelayFailReason.text(httpStatus:): what an HTTP answer at the relay's address means, word for word the iPhone's.
 *  `nostrJson`: the answer was a NIP-11 document (a relay that answers HTTP but not its socket). */
export function httpReason(status, nostrJson = false) {
  if (status === 401 || status === 403) return `refused (HTTP ${status})`
  if (status === 404) return "no relay at this address (HTTP 404)"
  if (status === 429) return "rate-limited (HTTP 429)"
  if (status >= 200 && status < 300) return nostrJson ? "not answering" : "not a relay (answered with a web page)"
  if (status >= 500 && status < 600) return `server error (HTTP ${status})`
  return `HTTP ${status}`
}

/** The relay's NIP-11 address: wss → https, ws → http. null for anything else. */
export function infoUrl(url) {
  try {
    const u = new URL(url)
    if (u.protocol !== "wss:" && u.protocol !== "ws:") return null
    u.protocol = u.protocol === "wss:" ? "https:" : "http:"
    return u.href
  } catch { return null }
}

/** Why a socket that failed didn't connect: offline, the HTTP answer at its address, or "not answering". */
export async function failReason(url, { online = () => globalThis.navigator?.onLine !== false, fetchFn = globalThis.fetch, waitMs = HTTP_WAIT_MS } = {}) {
  if (!online()) return "you're offline"
  const info = infoUrl(url)
  if (!info) return "not a relay address"
  try {
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), waitMs)
    const res = await fetchFn(info, { headers: { Accept: "application/nostr+json" }, signal: ctl.signal, cache: "no-store" }).finally(() => clearTimeout(timer))
    return httpReason(res.status, /nostr\+json/i.test(res.headers?.get?.("content-type") ?? ""))
  } catch { return "not answering" }
}

/** One try: -> { ms } when the relay answered, { why } when it didn't. `WS` and `now` are for tests. */
export function probeOnce(url, { WS = globalThis.WebSocket, timeoutMs = TIMEOUT_MS, now = () => performance.now(), reason = failReason } = {}) {
  return new Promise(resolve => {
    if (!infoUrl(url)) return resolve({ why: "not a relay address" })
    let ws, done = false
    const start = now()
    const end = r => { if (done) return; done = true; clearTimeout(timer); try { ws?.close() } catch {} resolve(r) }
    const timer = setTimeout(() => end({ why: noAnswer(timeoutMs) }), timeoutMs)
    try { ws = new WS(url) } catch { return end({ why: "not a relay address" }) }
    ws.onopen = () => { try { ws.send(JSON.stringify(["REQ", "nv-probe", { kinds: [0], limit: 1 }])) } catch {} }
    ws.onmessage = () => end({ ms: Math.max(0, Math.round(now() - start)) })
    const failed = () => { if (done) return; clearTimeout(timer); done = true; try { ws.close() } catch {} reason(url).then(why => resolve({ why }), () => resolve({ why: "not answering" })) }
    ws.onerror = failed
    ws.onclose = failed
  })
}

/** A probe with the iPhone's one retry: a blip doesn't call a relay down. */
export async function probeRelay(url, { retryMs = RETRY_MS, sleep = ms => new Promise(r => setTimeout(r, ms)), ...opts } = {}) {
  const first = await probeOnce(url, opts)
  if (!first.why) return first
  await sleep(retryMs)
  return probeOnce(url, opts)
}

/** The row's line (RelayMatrixView.subtitle): "120 ms", "720 ms · slow", the reason, or "…" while probing.
 *  -> { text, tone: "ok" | "slow" | "down" | "probing" } */
export function probeLine(result) {
  if (!result) return { text: "…", tone: "probing" }
  if (result.why) return { text: result.why, tone: "down" }
  return result.ms > SLOW_MS ? { text: `${result.ms} ms · slow`, tone: "slow" } : { text: `${result.ms} ms`, tone: "ok" }
}

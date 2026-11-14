// The napplet host: runs one NIP-5D napplet (a single self-contained index.html) in a sandboxed srcdoc frame and
// answers its requests. The page that calls mountNapplet is the shell; it owns keys, relays, the vault and storage,
// and passes one handler per NAP domain. A napplet only ever talks over the MessagePort it hands over in its one
// `napplet.hello`; anything else from its window means the document was replaced, and the frame is removed.
// Spec: NIP-5D (nostr-protocol/nips PR #2303), napplet.run/docs "NIP-5D explained". P0 findings: docs/napplets/P0_SPIKE.md.
import { preludeFor } from "./prelude.js"
import { frameCsp, LOADER_FILE } from "./csp.js"
import { artifactHash, buildSrcdoc } from "./srcdoc.js"

export { artifactHash }

/** The loader page, beside index.html (web-vault/public/napplet-frame.html). */
export const LOADER_PATH = LOADER_FILE

// mountNapplet({ html, dTag, domains, handlers, container, expectHash?, onRevoke?, loader?, onClose? }) -> { frame, hash, napplet, send, close }
//   loader:   the served loader page (/vault/napplet-frame.html, LOADER_PATH). With it the frame loads that page under
//             its own CSP, which says "nv-loader.ready" once; the shell then posts it the document and it writes
//             itself over: exactly two loads. Without it (dev spike, tests) the frame is a srcdoc: one load. A srcdoc
//             frame inherits the shell's CSP, so on the live site only the loader runs a napplet's scripts.
//   origin:   the napplet's own origin (origin.js, P2). With it the loader comes from there, framed
//             allow-scripts allow-same-origin (a real origin, but the napplet's own), and must report its guards
//             (`needGuards`: navigation cancelled + service worker in front) or the frame is removed. Messages are
//             checked against that origin both ways.
//   domains:  the NAP domains this napplet may use. Only these are injected AND only these are answered: hiding a
//             shim object does not stop a napplet posting any envelope it likes.
//   handlers: { [domain]: (msg, napplet) => reply | Promise<reply> | undefined }. A reply object is posted back as is
//             (it carries its own `type` and `id`); undefined means the handler answers later through napplet.send.
export async function mountNapplet({ html, dTag, domains, handlers, container, expectHash, onRevoke, onClose, loader, origin, needGuards = !!origin, title = dTag }) {
  if (origin && origin === globalThis.location?.origin) throw new Error("a napplet never runs on the vault's own origin")
  const hash = await artifactHash(html)
  if (expectHash && expectHash !== hash) throw new Error(`napplet ${dTag}: artifact hash ${hash} is not the manifest's ${expectHash}`)
  const allowed = new Set(domains)
  const frame = document.createElement("iframe")
  // Never allow-same-origin on our own origin: that would give the napplet the vault. On its own origin it is what
  // makes the origin real (Navigation API, service worker), and the origin is the napplet's alone.
  frame.setAttribute("sandbox", origin ? "allow-scripts allow-same-origin" : "allow-scripts")
  frame.setAttribute("referrerpolicy", "no-referrer")
  frame.title = title
  frame.className = "napplet-frame"
  let port = null, loads = 0, closed = false, ready = false, written = false
  let portUp
  // `ready`: resolves once the napplet has handed over its port (its one napplet.hello), so a send will arrive.
  const napplet = { dTag, hash, send: (m) => port && !closed && port.postMessage(m), ready: new Promise(r => { portUp = r }) }
  const srcdoc = buildSrcdoc(html, preludeFor(domains), frameCsp())
  const maxLoads = loader ? 2 : 1

  const revoke = (why) => {
    if (closed) return
    closed = true
    window.removeEventListener("message", onWindow)
    try { port?.close() } catch {}
    frame.remove()
    try { onClose?.() } catch {}
    onRevoke?.(why)
  }
  const onPort = async (e) => {
    const msg = e.data
    if (!msg || typeof msg.type !== "string") return
    const domain = msg.type.split(".")[0]
    if (!allowed.has(domain)) return // unrecognised or not granted: ignored, as the spec says
    const handler = handlers[domain]
    if (!handler) return
    try {
      const reply = await handler(msg, napplet)
      if (reply) napplet.send(reply)
    } catch (err) {
      if (msg.id) napplet.send({ type: `${msg.type}.result`, id: msg.id, ok: false, error: String(err?.message || err) })
    }
  }
  // The loader's document is written over once it has said ready AND finished loading, so the write's load is the
  // second one whatever order the two arrive in.
  const write = () => {
    if (written || !ready || loads < 1) return
    written = true
    frame.contentWindow.postMessage({ type: "nv-loader.write", html: srcdoc }, origin || "*")
  }
  const onWindow = (e) => {
    if (e.source !== frame.contentWindow) return
    if (origin && e.origin !== origin) return revoke("message from the wrong origin")
    if (loader && !ready) {
      if (e.data?.type !== "nv-loader.ready" || e.ports.length) return revoke("unexpected loader message")
      const g = e.data.guards ?? {}
      if (needGuards && !(g.nav && g.sw)) return revoke(`this browser can't wall it off (${!g.nav ? "no navigation guard" : "no service worker"})`)
      ready = true
      return write()
    }
    if (e.data?.type === "nv-loader.left") return revoke("it tried to leave its frame")
    if (port || (loader && !written) || e.data?.type !== "napplet.hello" || e.ports.length !== 1) return revoke("unexpected window message")
    port = e.ports[0]
    port.onmessage = onPort
    port.start?.()
    portUp()
  }
  window.addEventListener("message", onWindow)
  frame.addEventListener("load", () => { if (++loads > maxLoads) return revoke("document replaced"); if (loader) write() })
  if (loader) frame.src = origin ? new URL(new URL(loader).pathname, origin).href : loader
  else frame.srcdoc = srcdoc
  container.appendChild(frame)
  return { frame, hash, napplet, send: napplet.send, close: () => revoke("closed by shell") }
}

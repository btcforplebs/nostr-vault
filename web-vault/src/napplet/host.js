// The napplet host: runs one NIP-5D napplet (a single self-contained index.html) in a sandboxed srcdoc frame and
// answers its requests. The page that calls mountNapplet is the shell; it owns keys, relays, the vault and storage,
// and passes one handler per NAP domain. A napplet only ever talks over the MessagePort it hands over in its one
// `napplet.hello`; anything else from its window means the document was replaced, and the frame is removed.
// Spec: NIP-5D (nostr-protocol/nips PR #2303), napplet.run/docs "NIP-5D explained". P0 findings: docs/napplets/P0_SPIKE.md.
import { preludeFor } from "./prelude.js"
import { frameCsp } from "./csp.js"
import { artifactHash, buildSrcdoc } from "./srcdoc.js"

export { artifactHash }

// mountNapplet({ html, dTag, domains, handlers, container, expectHash?, onRevoke? }) -> { frame, hash, send, close }
//   domains:  the NAP domains this napplet may use. Only these are injected AND only these are answered: hiding a
//             shim object does not stop a napplet posting any envelope it likes.
//   handlers: { [domain]: (msg, napplet) => reply | Promise<reply> | undefined }. A reply object is posted back as is
//             (it carries its own `type` and `id`); undefined means the handler answers later through napplet.send.
export async function mountNapplet({ html, dTag, domains, handlers, container, expectHash, onRevoke, title = dTag }) {
  const hash = await artifactHash(html)
  if (expectHash && expectHash !== hash) throw new Error(`napplet ${dTag}: artifact hash ${hash} is not the manifest's ${expectHash}`)
  const allowed = new Set(domains)
  const frame = document.createElement("iframe")
  frame.setAttribute("sandbox", "allow-scripts") // never allow-same-origin: that would give the napplet our origin
  frame.setAttribute("referrerpolicy", "no-referrer")
  frame.title = title
  frame.className = "napplet-frame"
  let port = null, loads = 0, closed = false
  const napplet = { dTag, hash, send: (m) => port && !closed && port.postMessage(m) }

  const revoke = (why) => {
    if (closed) return
    closed = true
    window.removeEventListener("message", onWindow)
    try { port?.close() } catch {}
    frame.remove()
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
  const onWindow = (e) => {
    if (e.source !== frame.contentWindow) return
    if (port || e.data?.type !== "napplet.hello" || e.ports.length !== 1) return revoke("unexpected window message")
    port = e.ports[0]
    port.onmessage = onPort
    port.start?.()
  }
  window.addEventListener("message", onWindow)
  frame.addEventListener("load", () => { if (++loads > 1) revoke("document replaced") })
  frame.srcdoc = buildSrcdoc(html, preludeFor(domains), frameCsp())
  container.appendChild(frame)
  return { frame, hash, send: napplet.send, close: () => revoke("closed by shell") }
}

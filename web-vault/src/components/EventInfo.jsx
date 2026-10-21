// Event Info, from a note's antenna button, as on the iPhone (EventBroadcastSheet, EventInspector): who and what it
// is, whether its signature holds, its identifiers and raw JSON, which of your relays have it, and a rebroadcast of
// the same signed event to the relays you tick. Nothing is signed here: the event goes out exactly as it came in.
import { useEffect, useRef, useState } from "preact/hooks"
import { neventEncode, noteEncode, npubEncode } from "nostr-tools/nip19"
import { verifyEvent } from "nostr-tools/pure"
import { Dialog } from "./Moderation.jsx"
import { AuthorName } from "./NoteCard.jsx"
import { pool, uniq } from "../net/pool.js"
import { shareLink } from "../net/actions.js"

const CHECK_MS = 6_000, SEND_MS = 15_000
const KIND_NAMES = { 0: "Profile", 1: "Note", 3: "Follow list", 6: "Repost", 7: "Reaction", 16: "Repost", 20: "Picture", 1068: "Poll", 1111: "Comment", 9802: "Highlight", 30023: "Article" }
export const kindName = kind => KIND_NAMES[kind] ?? "Event"

/** The relays the sheet lists (EventInspector): your read relays, then your write relays, once each; write ticked. */
export function infoRelays(account) {
  const read = account?.relays?.read ?? [], write = account?.relays?.write ?? []
  const norm = u => String(u).trim().replace(/\/+$/, "")
  return { relays: uniq([...read, ...write].map(norm)).filter(u => /^wss?:\/\//.test(u)), ticked: new Set(write.map(norm)) }
}

/** The signed event only: what a relay is sent, with no fields a client added. */
export const signedFields = ev => ({ id: ev.id, pubkey: ev.pubkey, created_at: ev.created_at, kind: ev.kind, tags: ev.tags, content: ev.content, sig: ev.sig })

export function EventInfoButton({ event, account }) {
  const [open, setOpen] = useState(false)
  return <>
    <button type="button" class="note-action" aria-label="Event Info" title="Event Info" onClick={e => { e.stopPropagation(); setOpen(true) }}>
      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 13a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3zM12 13v8M8.5 8.5a5 5 0 0 0 0 5M15.5 8.5a5 5 0 0 1 0 5M5.6 5.6a9 9 0 0 0 0 11.8M18.4 5.6a9 9 0 0 1 0 11.8" /></svg>
    </button>
    {open && <EventInfo event={event} account={account} onClose={() => setOpen(false)} />}
  </>
}

function EventInfo({ event, account, onClose }) {
  const ev = signedFields(event)
  const [valid] = useState(() => { try { return verifyEvent({ ...ev }) } catch { return false } })
  const [copied, setCopied] = useState("")
  const [showJson, setShowJson] = useState(false)
  const { relays, ticked: initial } = infoRelays(account)
  const [has, setHas] = useState({}) // url -> "checking" | true | false | { error }
  const [ticked, setTicked] = useState(() => new Set(relays.filter(r => initial.has(r))))
  const [sent, setSent] = useState({}) // url -> "sending" | "sent" | { rejected } | "no answer"
  const live = useRef(true)
  useEffect(() => () => { live.current = false }, [])
  useEffect(() => {
    setHas(Object.fromEntries(relays.map(r => [r, "checking"])))
    for (const url of relays) {
      pool.querySync([url], { ids: [ev.id] }, { maxWait: CHECK_MS })
        .then(found => live.current && setHas(h => ({ ...h, [url]: found.some(f => f.id === ev.id) })))
        .catch(e => live.current && setHas(h => ({ ...h, [url]: { error: String(e?.message ?? e) } })))
    }
  }, [ev.id])
  const copy = (key, text) => async () => { await navigator.clipboard?.writeText(text).catch(() => {}); setCopied(key); setTimeout(() => live.current && setCopied(""), 1200) }
  const missing = relays.filter(r => has[r] === false)
  const flip = url => setTicked(t => { const n = new Set(t); n.has(url) ? n.delete(url) : n.add(url); return n })
  const broadcast = () => {
    const urls = [...ticked]
    setSent(s => ({ ...s, ...Object.fromEntries(urls.map(u => [u, "sending"])) }))
    pool.publish(urls, ev).forEach((p, i) => {
      const url = urls[i]
      const timer = setTimeout(() => live.current && setSent(s => s[url] === "sending" ? { ...s, [url]: "no answer" } : s), SEND_MS)
      p.then(() => { clearTimeout(timer); if (live.current) { setSent(s => ({ ...s, [url]: "sent" })); setHas(h => ({ ...h, [url]: true })) } })
        .catch(e => { clearTimeout(timer); live.current && setSent(s => ({ ...s, [url]: { rejected: String(e?.message ?? e) } })) })
    })
  }
  const nevent = neventEncode({ id: ev.id, author: ev.pubkey, kind: ev.kind })
  const ids = [["Hex", ev.id], ["note1", noteEncode(ev.id)], ["nevent", nevent], ["Share link", shareLink(ev)]]
  const onCount = relays.filter(r => has[r] === true).length
  const busy = Object.values(sent).includes("sending")
  return (
    <Dialog label="Event Info" onClose={onClose}>
      <div class="info-head">
        <h3>Event Info</h3>
        <button type="button" class="small" onClick={onClose}>Done</button>
      </div>
      <div class="info-who">
        <strong><AuthorName pubkey={ev.pubkey} /></strong>
        <span class="muted small">{kindName(ev.kind)} · {ev.kind} · {new Date(ev.created_at * 1000).toLocaleString()}</span>
        <span class={`info-sig ${valid ? "ok" : "bad"}`}>Signature: {valid ? "Valid" : "Invalid"}</span>
      </div>
      <div class="info-tiles">
        <button type="button" onClick={copy("link", shareLink(ev))}>{copied === "link" ? "Copied" : "Copy link"}</button>
        <button type="button" onClick={copy("npub", npubEncode(ev.pubkey))}>{copied === "npub" ? "Copied" : "Copy npub"}</button>
        <button type="button" onClick={copy("json", JSON.stringify(ev, null, 2))}>{copied === "json" ? "Copied" : "Copy JSON"}</button>
      </div>
      <section>
        <h4 class="info-section">IDENTIFIERS</h4>
        {ids.map(([label, value]) => (
          <button type="button" key={label} class="info-id" onClick={copy(label, value)} title={`Copy ${label}`}>
            <span class="muted small">{label}</span><code>{copied === label ? "Copied" : value}</code>
          </button>
        ))}
      </section>
      <section>
        <button type="button" class="info-section info-toggle" aria-expanded={showJson} onClick={() => setShowJson(!showJson)}>RAW EVENT {showJson ? "▾" : "▸"}</button>
        {showJson && <pre class="info-json">{JSON.stringify(sortKeys(ev), null, 2)}</pre>}
      </section>
      <section>
        <h4 class="info-section">RELAYS · On {onCount} of {relays.length}</h4>
        <p class="muted small">Tick the relays to send to.</p>
        {relays.map(url => (
          <label key={url} class="info-relay">
            <input type="checkbox" checked={ticked.has(url)} onChange={() => flip(url)} />
            <span class="info-relay-url">{url.replace(/^wss?:\/\//, "")}</span>
            <span class="info-relay-state muted small">{relayState(has[url], sent[url])}</span>
          </label>
        ))}
        {missing.length > 0 && <button type="button" class="small" onClick={() => setTicked(new Set([...ticked, ...missing]))}>Select missing ({missing.length})</button>}
        <button type="button" class="primary info-send" disabled={!ticked.size || busy} onClick={broadcast}>
          {!ticked.size ? "Pick a relay" : `Broadcast to ${ticked.size} ${ticked.size === 1 ? "relay" : "relays"}`}
        </button>
      </section>
    </Dialog>
  )
}

function relayState(has, sent) {
  if (sent === "sending") return "Sending…"
  if (sent === "sent") return "Sent"
  if (sent === "no answer") return "no answer"
  if (sent?.rejected) return `Rejected: ${sent.rejected}`
  if (has === "checking" || has === undefined) return "Checking…"
  if (has === true) return "Has it"
  if (has === false) return "Doesn't have it"
  return `Couldn't check: ${has.error}`
}

const sortKeys = ev => Object.fromEntries(Object.keys(ev).sort().map(k => [k, ev[k]]))

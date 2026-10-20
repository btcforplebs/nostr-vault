// The Live feed (the iPhone's LiveStreamCardView grid and LiveStreamPlayerView): streams on air now, Following or
// Global (your web of trust; everyone but adult streams until you follow someone), as tiles with a LIVE badge and
// viewers. A tile opens the stream: the video (Safari's own HLS player, hls.js in other browsers, a link out when
// neither can play it), then the chat and its zaps, read-only. Nothing is stored.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { pool } from "../net/pool.js"
import { formatSats } from "../net/notifications.js"
import { receiptTrust } from "../net/zaps.js"
import { Scopes } from "./ArticlesScreen.jsx"
import { attachHls, playMode } from "./hls.js"
import { LIVE_SCOPES, chatFilter, chatRelays, chatRows, fetchStreams, loadScope, saveScope, startScope, streamLink } from "./live.js"

if (import.meta.env) import("./readers.css")

export function LiveScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(() => startScope(loadScope(), follows))
  const [streams, setStreams] = useState(null)
  const [status, setStatus] = useState("")
  const [open, setOpen] = useState(null)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)

  const load = async () => {
    const n = ++seq.current
    if (scope === "following" && !follows.length) { setStreams([]); return setStatus("") }
    if (navigator.onLine === false) return setStatus("Offline: Live needs the network")
    setStatus("Looking for live streams…")
    try {
      const list = await fetchStreams({ scope, me: ctx.session?.pubkey, follows, readRelays: account.relays.read, blocked })
      if (n !== seq.current) return
      setStreams(list ?? [])
      setStatus("")
      if (list?.length) fetchProfiles(vault, list.map(s => s.host), account.relays.read, { save: false }).catch(() => {})
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }
  useEffect(() => { setOpen(null); setStreams(null); load() }, [scope, follows.length, blocked.size])

  if (open) return <LivePlayer ctx={ctx} stream={open} onBack={() => setOpen(null)} />
  const pick = s => { saveScope(s); setScope(s) }
  return (
    <div class="reader-feed">
      <Scopes scopes={LIVE_SCOPES} value={scope} onPick={pick} onRefresh={load} />
      {status && <div class="status-line">{status}</div>}
      {scope === "following" && !follows.length ? <p class="empty">{account.loaded ? "Follow someone to see their streams here, or switch to Global." : "Loading your follows…"}</p>
        : streams === null ? <p class="empty">Looking for live streams…</p>
        : !streams.length ? <p class="empty">{scope === "following" ? "Nobody you follow is live right now." : "No live streams right now."}</p>
        : <div class="live-grid">{streams.map(s => <LiveTile key={s.address} stream={s} onOpen={() => setOpen(s)} />)}</div>}
    </div>
  )
}

/** A tile: the live frame (else the cover), LIVE and viewers over it, then title and host. The title is also a real
 *  link to zap.stream for right-click or middle-click. */
export function LiveTile({ stream: s, onOpen }) {
  const [pic, setPic] = useState(0)
  const src = s.previews[pic]
  return (
    <article class="live-tile" tabindex="0" onClick={onOpen} onKeyDown={e => { if (e.key === "Enter") onOpen() }}>
      <div class="live-thumb">
        {src ? <img src={src} alt="" loading="lazy" referrerpolicy="no-referrer" onError={() => setPic(pic + 1)} /> : <div class="live-blank" aria-hidden="true" />}
        <span class="live-badge">LIVE</span>
        {s.viewers != null && <span class="live-viewers">{s.viewers} watching</span>}
      </div>
      <div class="live-text">
        <h3><a href={streamLink(s)} target="_blank" rel="noopener noreferrer" onClick={e => { e.preventDefault(); e.stopPropagation(); onOpen() }}>{s.title || "Live stream"}</a></h3>
        <span class="muted small"><AuthorName pubkey={s.host} /></span>
      </div>
    </article>
  )
}

/** The stream: video (or the link out), host, title and summary, Open in zap.stream, then the chat. */
export function LivePlayer({ ctx, stream: s, onBack }) {
  const link = streamLink(s)
  return (
    <div class="reader live-player">
      <div class="reader-bar">
        <button type="button" class="small" onClick={onBack}>‹ Back</button>
        <a class="reader-web small" href={link} target="_blank" rel="noopener noreferrer">Open in zap.stream</a>
      </div>
      <LiveVideo stream={s} link={link} />
      <h1 class="reader-title">{s.title || "Live stream"}</h1>
      <a class="reader-byline muted small" href={`#/profile/${s.host}`}>
        <Avatar pubkey={s.host} size={24} /><AuthorName pubkey={s.host} />
        {s.viewers != null && <><span>·</span><span>{s.viewers} watching</span></>}
      </a>
      {s.summary && <p class="reader-summary">{s.summary}</p>}
      <LiveChat ctx={ctx} stream={s} />
    </div>
  )
}

/** The video: Safari's own HLS player, hls.js elsewhere, and the link out when neither can play it. */
export function LiveVideo({ stream: s, link, mode: forced }) {
  const ref = useRef(null)
  const [mode, setMode] = useState(() => forced ?? playMode(globalThis.document?.createElement("video")))
  useEffect(() => {
    if (mode !== "hlsjs" || !ref.current) return
    return attachHls(ref.current, s.streaming, () => setMode("none"))
  }, [mode, s.streaming])
  if (mode === "none") return (
    <a class="live-out" href={link} target="_blank" rel="noopener noreferrer">
      {s.image && <img src={s.image} alt="" referrerpolicy="no-referrer" />}
      <span>This browser can't play the stream here. Watch it on zap.stream ›</span>
    </a>
  )
  return <video ref={ref} class="live-video" src={mode === "native" ? s.streaming : undefined} poster={s.image ?? undefined} controls autoplay playsinline />
}

/** The stream's chat and zaps, read-only, newest at the bottom, live while open. Zap receipts only count once their
 *  zap request checks out and the payee's zap service published them (net/zaps.js trustedReceipts). */
function LiveChat({ ctx, stream: s }) {
  const [rows, setRows] = useState(null)
  const { blocked } = useBlocks(ctx)
  const box = useRef(null)
  useEffect(() => {
    const evs = new Map()
    const trust = receiptTrust(ctx)
    let live = true, sub
    const redraw = async () => {
      const ok = await trust([...evs.values()])
      if (!live) return
      const shown = chatRows(ok, blocked)
      setRows(shown)
      fetchProfiles(ctx.vault, shown.map(r => r.who), ctx.account.relays.read, { save: false }).catch(() => {})
    }
    pool.querySync(chatRelays(s), chatFilter(s), { maxWait: 8000 }).then(list => {
      if (!live) return
      for (const ev of list) evs.set(ev.id, ev)
      redraw()
      sub = pool.subscribeMany(chatRelays(s), chatFilter(s, Math.floor(Date.now() / 1000)), {
        onevent: ev => { if (!evs.has(ev.id)) { evs.set(ev.id, ev); redraw() } },
      })
    }).catch(() => live && setRows([]))
    return () => { live = false; sub?.close() }
  }, [s.address, blocked.size])
  useEffect(() => { const el = box.current; if (el) el.scrollTop = el.scrollHeight }, [rows?.length])
  return (
    <section class="live-chat" aria-label="Live chat">
      <h2 class="live-chat-head">Chat</h2>
      <div class="live-chat-rows" ref={box}>
        {rows === null ? <p class="muted small">Loading chat…</p>
          : !rows.length ? <p class="muted small">No messages yet.</p>
          : rows.map(r => (
            <div key={r.id} class={r.sats ? "live-row zap" : "live-row"}>
              <Avatar pubkey={r.who} size={22} load={false} />
              <span class="live-who"><AuthorName pubkey={r.who} /></span>
              {r.sats > 0 && <span class="live-sats">⚡ {formatSats(r.sats)}</span>}
              {r.text && <span class="live-msg">{r.text}</span>}
            </div>
          ))}
      </div>
    </section>
  )
}

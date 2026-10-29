// A live stream's chat (the iPhone's LiveStreamPlayerView chat column and LiveChatRowView since #1306): messages and
// zaps, newest at the bottom, live while open. A name or face opens that person's profile; a row's ⋯ has View
// profile, Mute and Report. Photos, GIFs and videos in a message show under its text (four at most, live-chat.js).
// The composer sends a kind 1311 to the stream's chat relays, attaches a photo, GIF or video by uploading it to your
// media servers (its link goes into the message), and zaps the host for this stream. Read-only accounts read only.
// Every row is checked first: signed by who it says, tagged with this stream (live-chat.js chatRow).
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { Dialog, ReportDialog } from "../components/Moderation.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useWallet } from "../components/ZapButton.jsx"
import { fetchProfiles, getProfile } from "../net/profiles.js"
import { pool } from "../net/pool.js"
import { formatSats } from "../net/notifications.js"
import { receiptTrust, zap, zapPublisherOf, PRESET_SATS } from "../net/zaps.js"
import { setBlock } from "../net/blocks.js"
import { mediaServers, uploadPhoto } from "../net/upload.js"
import { appendClientTag } from "../net/client-tag.js"
import { checkSigned } from "../net/sync.js"
import { mediaType } from "../net/media.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { chatFilter, chatRelays } from "./live.js"
import { chatRows, chatTemplate, rowOffers, splitMedia } from "./live-chat.js"
import { Spinner } from "../components/Loading.jsx"

if (import.meta.env) import("./live.css")

const nameOf = pk => { const p = getProfile(pk); return p?.display_name || p?.name || `${pk.slice(0, 8)}…` }

/** "9:41 PM": the iPhone's short time on each chat line. */
export const chatTime = (at, locale) => new Date(at * 1000).toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" })

/** The chat's rows, read once per stream and kept live; the page and the full-screen overlay share one copy, so
 *  going full screen doesn't read the chat again. -> { rows: [row] | null, sent(event), mute(pubkey), muted } */
export function useLiveChat(ctx, s) {
  const [rows, setRows] = useState(null)
  const [muted, setMuted] = useState(() => new Set()) // muted from this chat while it is open; the block list catches up
  const { blocked } = useBlocks(ctx)
  const store = useRef(null) // { evs: Map, redraw }
  useEffect(() => {
    const evs = new Map()
    const trust = receiptTrust(ctx)
    let live = true, sub
    const redraw = async () => {
      // Receipts also have to come from the payee's zap service (net/zaps.js trustedReceipts) to count at all.
      const ok = await trust([...evs.values()])
      // Each payee's zap service, resolved once: a zap names its payer only from a receipt that service published.
      const payees = [...new Set(ok.filter(ev => ev.kind === 9735).map(ev => ev.tags.find(t => t[0] === "p")?.[1]).filter(Boolean))]
      const publishers = new Map(await Promise.all(payees.map(async pk => [pk, await zapPublisherOf(ctx, pk).catch(() => null)])))
      if (!live) return
      const shown = chatRows(ok, s.address, blocked, 200, publishers)
      setRows(shown)
      fetchProfiles(ctx.vault, shown.map(r => r.who).filter(Boolean), ctx.account.relays.read, { save: false }).catch(() => {})
    }
    store.current = { evs, redraw }
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
  return {
    rows: rows && rows.filter(r => !(r.who && muted.has(r.who))),
    sent: ev => { store.current?.evs.set(ev.id, ev); store.current?.redraw() },
    mute: pk => setMuted(m => new Set([...m, pk])),
  }
}

/** The chat column: rows, newest at the bottom, then the composer. `chat` is useLiveChat's. */
export function LiveChat({ ctx, stream: s, chat, overlay = false }) {
  const box = useRef(null)
  const { rows } = chat
  useEffect(() => { const el = box.current; if (el) el.scrollTop = el.scrollHeight }, [rows?.length])
  return (
    <section class={`live-chat${overlay ? " overlay" : ""}`} aria-label="Live chat">
      {!overlay && <h2 class="live-chat-head">Chat</h2>}
      <div class="live-chat-rows" ref={box}>
        {rows === null ? <p class="muted small"><Spinner /> Loading chat…</p>
          : !rows.length ? <p class="muted small">No messages yet. Say hello.</p>
          : rows.map(r => <ChatRow key={r.id} ctx={ctx} row={r} onMuted={chat.mute} />)}
      </div>
      <Composer ctx={ctx} stream={s} onSent={chat.sent} />
    </section>
  )
}

/** One row (LiveChatRowView): face and name open the profile; a zap is the same row in gold with ⚡ and the amount.
 *  A zap that names nobody shows "Someone" and nothing to open, mute or report. */
export function ChatRow({ ctx, row: r, onMuted }) {
  const [menu, setMenu] = useState(false)
  const [dialog, setDialog] = useState(null) // "mute" | "report"
  const { text, media } = splitMedia(r.text)
  const o = rowOffers(r, ctx.session?.pubkey, !ctx.signer || ctx.signer.readOnly)
  const profile = o.profile
  return (
    <div class={r.zap ? "live-row zap" : "live-row"}>
      {profile ? <a href={profile} class="live-face" aria-label={`Open ${nameOf(r.who)}'s profile`}><Avatar pubkey={r.who} size={22} load={false} /></a>
        : <span class="live-face live-bolt" aria-hidden="true">⚡</span>}
      {r.zap && <span class="live-sats">⚡ {r.sats > 0 ? formatSats(r.sats) : ""}</span>}
      {profile ? <a class="live-who" href={profile}><AuthorName pubkey={r.who} /></a> : <span class="live-who">{o.label}</span>}
      <time class="live-time" datetime={new Date(r.at * 1000).toISOString()}>{chatTime(r.at)}</time>
      {profile && (
        <span class="live-row-more">
          <button type="button" class="live-more-btn" aria-label="Message options" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(m => !m)}>⋯</button>
          {menu && (
            <span class="live-menu" role="menu" onMouseLeave={() => setMenu(false)}>
              <a role="menuitem" href={profile}>View {nameOf(r.who)}'s profile</a>
              {o.mute && <button role="menuitem" onClick={() => { setMenu(false); setDialog("mute") }}>Mute {nameOf(r.who)}</button>}
              {o.report && <button role="menuitem" onClick={() => { setMenu(false); setDialog("report") }}>Report message</button>}
            </span>
          )}
        </span>
      )}
      {text && <span class="live-msg">{text}</span>}
      {media.length > 0 && <span class="live-media">{media.map(u => <ChatMedia key={u} url={u} />)}</span>}
      {dialog === "mute" && <MuteDialog ctx={ctx} pubkey={r.who} onDone={ok => { setDialog(null); if (ok) onMuted?.(r.who) }} />}
      {dialog === "report" && <ReportDialog ctx={ctx} note={r.event} pubkey={r.who} name={nameOf(r.who)} onClose={() => setDialog(null)} />}
    </div>
  )
}

/** A photo, GIF or video in a message, all at one size; a tap opens it full size in a new tab. */
function ChatMedia({ url }) {
  if (mediaType(url) === "video") return <video class="live-media-item" src={url} controls muted playsinline preload="metadata" />
  return <a href={url} target="_blank" rel="noopener noreferrer"><img class="live-media-item" src={url} alt="" loading="lazy" referrerpolicy="no-referrer" /></a>
}

/** "Mute X?" (the iPhone's mute: the block list). Their messages leave this chat at once. */
function MuteDialog({ ctx, pubkey, onDone }) {
  const [busy, setBusy] = useState(false), [err, setErr] = useState("")
  const go = async () => {
    setBusy(true); setErr("")
    try { await setBlock(ctx, pubkey, { block: true }); onDone(true) } catch (e) { setErr(String(e?.message ?? e)); setBusy(false) }
  }
  // A native <dialog> (Moderation.jsx Dialog) sits in the top layer: drawn inside a chat row, a fixed box would be
  // held by the row's scroll and full-screen containers.
  return (
    <Dialog label={`Mute ${nameOf(pubkey)}?`} onClose={() => onDone(false)}>
      <h3>Mute {nameOf(pubkey)}?</h3>
      <p class="muted small">Their messages and posts stop appearing for you. Undo it in Settings, Blocked.</p>
      {err && <p class="small live-err">{err}</p>}
      <div class="live-dialog-row"><button type="button" onClick={() => onDone(false)}>Cancel</button><button type="button" class="primary" disabled={busy} onClick={go}>{busy ? "Muting…" : "Mute"}</button></div>
    </Dialog>
  )
}

/** Say something, attach a photo, GIF or video, zap the host. */
function Composer({ ctx, stream: s, onSent }) {
  const [draft, setDraft] = useState("")
  const [busy, setBusy] = useState("") // "send" | "upload" | "zap"
  const [note, setNote] = useState("")
  const [zapping, setZapping] = useState(false)
  const wallet = useWallet()
  const file = useRef(null)
  if (!ctx.signer || ctx.signer.readOnly) return <p class="live-composer muted small">{READ_ONLY_SHORT}</p>
  const run = (what, f) => async () => {
    setBusy(what); setNote("")
    try { await f() } catch (e) { setNote(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const send = run("send", async () => {
    const text = draft.trim()
    if (!text) return
    const t = chatTemplate(s.address, text)
    const template = { ...t, tags: appendClientTag(t.tags, t.kind) }
    const ev = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
    const results = await Promise.allSettled(pool.publish(chatRelays(s), ev))
    if (!results.some(r => r.status === "fulfilled")) throw new Error("No chat relay took it. Try again.")
    setDraft("")
    onSent(ev)
  })
  const attach = e => {
    const f = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!f) return
    run("upload", async () => {
      if (!/^(image|video)\//.test(f.type)) throw new Error("Pick a photo, GIF or video.")
      const { url } = await uploadPhoto(f, { ctx, servers: await mediaServers(ctx) })
      setDraft(d => (d.trim() ? `${d.trim()} ${url}` : url))
    })()
  }
  const sendZap = sats => run("zap", async () => {
    setZapping(false)
    await zap(ctx, { recipient: s.host, sats, address: s.address, comment: draft })
    setDraft("")
    setNote(`Zapped ${formatSats(sats)} sats`)
  })()
  return (
    <div class="live-composer">
      <input ref={file} type="file" accept="image/*,video/*" hidden onChange={attach} />
      <button type="button" class="live-attach" aria-label="Attach a photo, GIF or video" title="Photo, GIF or video" disabled={!!busy} onClick={() => file.current?.click()}>
        {busy === "upload" ? <Spinner /> : "＋"}
      </button>
      <input class="live-input" type="text" placeholder="Say something…" value={draft} maxLength={2000}
        onInput={e => setDraft(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send() } }} />
      {wallet.status === "ready" && (
        <span class="live-zap">
          <button type="button" class="live-zap-btn" aria-label="Zap this stream" aria-haspopup="menu" aria-expanded={zapping} disabled={!!busy} onClick={() => setZapping(z => !z)}>⚡</button>
          {zapping && <span class="live-menu up" role="menu">{PRESET_SATS.slice(0, 5).map(n => <button key={n} role="menuitem" onClick={() => sendZap(n)}>⚡ {formatSats(n)}</button>)}</span>}
        </span>
      )}
      <button type="button" class="live-send primary" aria-label="Send message" disabled={!draft.trim() || !!busy} onClick={send}>{busy === "send" ? "…" : "↑"}</button>
      {note && <p class="live-note small" role="status">{note}</p>}
    </div>
  )
}

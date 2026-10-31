// The Live feed (the iPhone's LiveStreamCardView grid and LiveStreamPlayerView): streams on air now, Following or
// Global (your web of trust; everyone but adult streams until you follow someone), as tiles with a LIVE badge and
// viewers. A tile opens the stream: the video (Safari's own HLS player, hls.js in other browsers, a link out when
// neither can play it), the host with Follow, the ⋯ menu (sharing), full screen with the chat over the video, and the
// chat (LiveChat.jsx). Nothing about the stream is stored.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles, getProfile } from "../net/profiles.js"
import { Scopes } from "./ArticlesScreen.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { attachHls, playMode } from "./hls.js"
import { PlayerBar } from "./PlayerBar.jsx"
import { liveAt, playLive, stop } from "./player.js"
import { LIVE_SCOPES, fetchStreams, loadScope, saveScope, startScope, streamLink } from "./live.js"
import { LiveChat, chatTime, useLiveChat } from "./LiveChat.jsx"
import { FollowHost, LiveMoreMenu } from "./LiveActions.jsx"

export { chatTime }
import { SkeletonGrid } from "../components/Loading.jsx"

if (import.meta.env) import("./readers.css")

export function LiveScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(() => startScope(loadScope(), follows))
  const [streams, setStreams] = useState(null)
  const [status, setStatus] = useState("")
  const [open, setOpen] = useState(null)
  const [failed, setFailed] = useState(false)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)

  const load = async () => {
    const n = ++seq.current
    if (scope === "following" && !follows.length) { setStreams([]); return setStatus("") }
    if (navigator.onLine === false) return setStatus("Offline: Live needs the network")
    setStatus("Looking for live streams…")
    setFailed(false)
    try {
      const list = await fetchStreams({ scope, me: ctx.session?.pubkey, follows, readRelays: account.relays.read, blocked })
      if (n !== seq.current) return
      setStreams(list ?? [])
      setStatus("")
      if (list?.length) fetchProfiles(vault, list.map(s => s.host), account.relays.read, { save: false }).catch(() => {})
    } catch { if (n === seq.current) { setStatus(""); setFailed(true); setStreams([]) } }
  }
  useEffect(() => { setOpen(null); setStreams(null); load() }, [scope, follows.length, blocked.size])

  if (open) return <LivePlayer ctx={ctx} stream={open} onBack={() => setOpen(null)} />
  // A minimized stream (or a song) plays on in the bar; "Back to the stream" opens its window again.
  const pick = s => { saveScope(s); setScope(s) }
  return (
    <div class="reader-feed">
      <Scopes scopes={LIVE_SCOPES} value={scope} onPick={pick} onRefresh={load} />
      {status && streams !== null && <div class="status-line">{status}</div>}
      {scope === "global" && !follows.length && streams?.length > 0 && <div class="status-line">👁 Unfiltered: people you don't know yet</div>}
      {scope === "following" && !follows.length && !account.loaded ? <p class="empty">Loading your follows…</p>
        : streams === null ? <SkeletonGrid count={4} gridClass="live-grid" tileClass="sk-wide" label="Looking for live streams…" />
        : !streams.length ? <LiveEmpty {...liveEmpty({ scope, follows, failed })} onGlobal={() => pick("global")} onRetry={load} />
        : <div class="live-grid">{streams.map(s => <LiveTile key={s.address} stream={s} onOpen={() => setOpen(s)} />)}</div>}
      <PlayerBar onOpenLive={st => setOpen(st)} />
    </div>
  )
}

/** The iPhone's empty Live (LiveChat.emptyLiveText): it says who was asked about, so an empty grid reads as "nobody in
 *  that group is streaming", not as a broken feed. Global with follows is your web of trust; without, everyone. */
export function liveEmpty({ scope, follows, failed }) {
  if (scope === "following" && !follows.length) return { title: "Nobody you follow is live", message: "You don't follow anyone yet. Global shows everyone who is streaming.", action: "global" }
  if (failed) return { title: "Could not reach any relay", message: "Live streams come from other people's relays, so this one needs a connection.", action: "retry" }
  if (scope === "following") return { title: "Nobody you follow is live", message: "Switch to Global to see who else is streaming.", action: "global" }
  if (follows.length) return { title: "Nobody in your network is live", message: "Nobody in your web of trust is streaming right now.", action: "retry" }
  return { title: "Nothing live right now", message: "Nobody is streaming right now. Check back later.", action: "retry" }
}

const LiveEmpty = ({ title, message, action, onGlobal, onRetry }) =>
  <EmptyState title={title} detail={message} action={action === "global" ? { label: "Show Global streams", onClick: onGlobal } : { label: "Try again", onClick: onRetry }} />

/** A tile: the live frame (else the cover), LIVE and viewers over it, then title and host. The title is also a real
 *  link to zap.stream for right-click or middle-click. */
/** `ended`: a stream quoted in a note that is no longer on air (LiveStreamEmbedView): an ENDED pill, dimmed, no tap. */
export function LiveTile({ stream: s, onOpen, ended = false }) {
  const [pic, setPic] = useState(0)
  const src = s.previews[pic]
  if (ended) onOpen = null
  return (
    <article class={`live-tile${ended ? " ended" : ""}`} tabindex={ended ? undefined : "0"} aria-label={ended ? `${s.title || "Untitled stream"}, this stream has ended` : undefined}
      onClick={onOpen ?? undefined} onKeyDown={onOpen ? e => { if (e.key === "Enter") onOpen() } : undefined}>
      <div class="live-thumb">
        {src ? <img src={src} alt="" loading="lazy" referrerpolicy="no-referrer" onError={() => setPic(pic + 1)} /> : <div class="live-blank" aria-hidden="true" />}
        <span class="live-pills">{ended ? <span class="live-badge live-ended">ENDED</span> : <span class="live-badge"><span class="live-dot">●</span> LIVE</span>}
          {!ended && s.viewers != null && <span class="live-viewers" aria-label={`${s.viewers} watching`}>👥 {s.viewers}</span>}</span>
      </div>
      <div class="live-text">
        <h3>{ended ? s.title || "Untitled stream"
          : <a href={streamLink(s)} target="_blank" rel="noopener noreferrer" onClick={e => { e.preventDefault(); e.stopPropagation(); onOpen() }}>{s.title || "Untitled stream"}</a>}</h3>
        <span class="muted small"><AuthorName pubkey={s.host} /></span>
      </div>
    </article>
  )
}

/** The stream: video (or the link out) with Full screen, title, host with Follow, summary, then the chat. Full screen
 *  takes the video and the chat together, the chat down the right over the picture (LiveStreamFullScreen); Chat in
 *  the corner hides or shows it. */
export function LivePlayer({ ctx, stream: s, onBack }) {
  const link = streamLink(s)
  const stage = useRef(null)
  const [full, setFull] = useState(false)
  const [chatOver, setChatOver] = useState(true)
  const chat = useLiveChat(ctx, s)
  // Back from minimized: the window takes the sound over, so it isn't playing twice.
  useEffect(() => { if (liveAt(s.address)) stop() }, [s.address])
  useEffect(() => {
    const f = () => setFull(document.fullscreenElement === stage.current && !!stage.current)
    document.addEventListener("fullscreenchange", f)
    return () => document.removeEventListener("fullscreenchange", f)
  }, [])
  const p = getProfile(s.host)
  const minimize = () => { playLive(s, p?.display_name || p?.name || ""); onBack() }
  const toggleFull = () => (document.fullscreenElement ? document.exitFullscreen() : stage.current?.requestFullscreen?.())?.catch?.(() => {})
  const canFull = !!globalThis.document?.fullscreenEnabled
  return (
    <div class="reader live-player">
      <div class="reader-bar">
        <button type="button" class="small" onClick={onBack}>‹ Back</button>
        {s.streaming && <button type="button" class="small" onClick={minimize} title="Keep listening while you browse">Minimize</button>}
        <LiveMoreMenu ctx={ctx} stream={s} />
      </div>
      <div class={`live-stage${full ? " full" : ""}${full && chatOver ? " with-chat" : ""}`} ref={stage}>
        <LiveVideo stream={s} link={link} />
        {canFull && <button type="button" class="live-full-btn" aria-label={full ? "Exit full screen" : "Full screen"} onClick={toggleFull}>{full ? "⤡" : "⤢"}</button>}
        {full && <button type="button" class="live-chat-btn" aria-pressed={chatOver} onClick={() => setChatOver(c => !c)}>{chatOver ? "Hide chat" : "Chat"}</button>}
        {full && chatOver && <LiveChat ctx={ctx} stream={s} chat={chat} overlay />}
      </div>
      <h1 class="reader-title">{s.title || "Untitled stream"}</h1>
      <div class="reader-byline muted small">
        <a class="live-host" href={`#/profile/${s.host}`}><Avatar pubkey={s.host} size={24} /><AuthorName pubkey={s.host} /></a>
        <FollowHost ctx={ctx} pubkey={s.host} />
        {s.viewers != null && <><span>·</span><span>{s.viewers} watching</span></>}
      </div>
      {s.summary && <p class="reader-summary">{s.summary}</p>}
      {!full && <LiveChat ctx={ctx} stream={s} chat={chat} />}
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


// One page of the diVines feed (the iPhone's ReelPlayerPage): the video, looping, playing only while in view; who posted
// it · when, its title and caption (tap for more); the rail on the right: Post, Like, Reply, Thread, Share, Mute.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { ago } from "../components/time.js"
import { act, actionState, compose, myReaction, onActionState, shareLink } from "../net/actions.js"

const P = {
  plus: "M12 5v14M5 12h14", heart: "M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z",
  reply: "M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z", thread: "M4 5h16v10H8l-4 4zM8 9h8M8 12h5",
  share: "M4 12v8h16v-8M12 3v13M7 8l5-5 5 5", muted: "M11 5 6 9H2v6h4l5 4zM22 9l-6 6M16 9l6 6", sound: "M11 5 6 9H2v6h4l5 4zM15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14",
}
const Glyph = ({ d, fill = false }) => <svg viewBox="0 0 24 24" width="26" height="26" fill={fill ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

export function ReelPage({ reel, index, ctx, active, near, muted, onMute, canPost }) {
  const video = useRef(null)
  const [broken, setBroken] = useState(false)
  const [expanded, setExpanded] = useState(false)
  const [copied, setCopied] = useState(false)
  const [, redraw] = useState(0)
  useEffect(() => onActionState(() => redraw(n => n + 1)), [])
  useEffect(() => {
    const v = video.current
    if (!v) return
    if (active) v.play?.()?.catch?.(() => {})
    else v.pause?.()
  }, [active, near])
  const liked = !!myReaction(reel.id)?.emoji
  const liking = actionState(reel.id).like === "pending"
  const note = reel.event
  const share = async () => {
    const url = shareLink(note)
    try {
      if (navigator.share) await navigator.share({ url })
      else { await navigator.clipboard.writeText(url); setCopied(true); setTimeout(() => setCopied(false), 1500) }
    } catch {}
  }
  return (
    <section class="reel" data-index={index} aria-label="Video">
      {near && !broken
        ? <video ref={video} class="reel-video" src={reel.video} poster={reel.poster ?? undefined} muted={muted} loop playsInline
            preload={active ? "auto" : "metadata"} onError={() => setBroken(true)} onClick={e => (e.currentTarget.paused ? e.currentTarget.play() : e.currentTarget.pause())} />
        : reel.poster && !broken ? <img class="reel-video" src={reel.poster} alt="" loading="lazy" />
        : <div class="reel-video" />}
      {broken && <p class="reel-broken">This video can't be played</p>}
      <div class="reel-shade" aria-hidden="true" />
      <div class="reel-over">
        <div class="reel-details">
          <a class="reel-who" href={`#/profile/${reel.pubkey}`}>
            <Avatar pubkey={reel.pubkey} size={32} />
            <strong><AuthorName pubkey={reel.pubkey} /></strong>
            <span>· {ago(reel.createdAt)}</span>
          </a>
          {reel.title && <p class="reel-title">{reel.title}</p>}
          {reel.caption && <p class={expanded ? "reel-caption open" : "reel-caption"} onClick={() => setExpanded(!expanded)}>{reel.caption}</p>}
        </div>
        <div class="reel-rail">
          {canPost && <a class="reel-post" href="#/compose?type=divine" aria-label="Post a diVine"><span><Glyph d={P.plus} /></span>Post</a>}
          {canPost && <button type="button" class={liked ? "liked" : ""} aria-label={liked ? "Liked" : "Like"} aria-pressed={liked} disabled={liking}
            onClick={() => { if (!liked) act(ctx, "like", note) }}><Glyph d={P.heart} fill={liked} />{liked ? "Liked" : "Like"}</button>}
          {canPost && <button type="button" aria-label="Reply" onClick={() => compose("reply", note)}><Glyph d={P.reply} />Reply</button>}
          <a href={`#/thread/${reel.id}`} aria-label="Thread"><Glyph d={P.thread} />Thread</a>
          <button type="button" aria-label="Share" onClick={share}><Glyph d={P.share} />{copied ? "Copied" : "Share"}</button>
          <button type="button" aria-label={muted ? "Unmute" : "Mute"} onClick={onMute}><Glyph d={muted ? P.muted : P.sound} />{muted ? "Unmute" : "Mute"}</button>
        </div>
      </div>
    </section>
  )
}

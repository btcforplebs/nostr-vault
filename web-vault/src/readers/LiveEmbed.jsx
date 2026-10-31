// A live stream inside a note (nostr:naddr of a 30311), as the iPhone's LiveStreamEmbedView: the Live feed's tile, so
// a stream looks the same wherever it shows up. On air, a tap opens the same player full screen over the note;
// once it has ended, the tile says ENDED, is dimmed and offers nothing to play. Read at each draw, so an embed
// scrolled back to after its stream ended stops offering it.
import { createPortal } from "preact/compat"
import { useEffect, useState } from "preact/hooks"
import { actionContext } from "../net/actions.js"
import { LIVE_KIND, isPlayableLive, parseStream } from "./live.js"
import { LivePlayer, LiveTile } from "./LiveScreen.jsx"

if (import.meta.env) { import("./readers.css"); import("./live.css") }

/** The stream an event is, for an embed, or null when it isn't one. */
export const embeddedStream = ev => (ev?.kind === LIVE_KIND ? parseStream(ev) : null)

export function LiveEmbed({ stream, now = Math.floor(Date.now() / 1000) }) {
  const [playing, setPlaying] = useState(false)
  const live = isPlayableLive(stream, now)
  const ctx = actionContext()
  return (
    <div class="live-embed" onClick={e => e.stopPropagation()}>
      <LiveTile stream={stream} ended={!live} onOpen={() => setPlaying(true)} />
      {playing && live && ctx && <LiveSheet ctx={ctx} stream={stream} onClose={() => setPlaying(false)} />}
    </div>
  )
}

/** The player over everything, as the iPhone's sheet; Esc or Back closes it, Minimize keeps the sound playing. */
function LiveSheet({ ctx, stream, onClose }) {
  useEffect(() => {
    const key = e => { if (e.key === "Escape") onClose() }
    const overflow = document.body.style.overflow
    document.addEventListener("keydown", key)
    document.body.style.overflow = "hidden"
    return () => { document.removeEventListener("keydown", key); document.body.style.overflow = overflow }
  }, [])
  return createPortal(
    <div class="live-embed-sheet" role="dialog" aria-modal="true" aria-label={stream.title || "Live stream"}>
      <LivePlayer ctx={ctx} stream={stream} onBack={onClose} />
    </div>,
    document.body,
  )
}

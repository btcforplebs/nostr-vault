// Vault › Media as the Media napplet (plan P5), when the napplet switch is on (flag.js): your media servers' files,
// listed, copied and deleted through NAP-BLOSSOM (blossom-dispatch.js: the shell signs every Blossom auth) with
// pictures and video as bytes from the shell. The shell asks before any delete, ours too; that sheet is here.
// `filter`: the Vault's Media pill (all, photos, videos, gifs), handed to the napplet by intent (napplet:media/open).
// Switch off, or the "In your notes" pill: the classic page (BlossomGallery.jsx, VaultScreen.jsx).
import { useEffect, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { MEDIA_DTAG } from "./first-party.js"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { askWords } from "./consent-words.js"
import "./napplet.css"

export function MediaPane({ ctx, filter = "all" }) {
  const host = useRef(null)
  const [asking, setAsking] = useState(null) // { words, resolve }
  const filterRef = useRef(filter)
  filterRef.current = filter
  const { live, note } = usePaneNapplet(ctx, host, {
    dTag: MEDIA_DTAG, actions: { media: ["open"] },
    ask: ({ napplet, what, detail }) => new Promise(resolve => setAsking({ words: askWords(what, napplet, detail), resolve })),
    onReady: l => { if (filterRef.current !== "all") l.invoke({ archetype: "media", action: "open", payload: { filter: filterRef.current } }) },
  })

  const sent = useRef(filter)
  useEffect(() => {
    if (filter === sent.current) return
    sent.current = filter
    const l = live.current
    if (l) l.invoke({ archetype: "media", action: "open", payload: { filter } })
  }, [filter])

  const answer = yes => { asking?.resolve(yes); setAsking(null) }
  return (
    <div class="media-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host media-host" ref={host} />
      {asking && (
        <Dialog label={asking.words.title} onClose={() => answer(false)}>
          <h3>{asking.words.title}</h3>
          {asking.words.body && <p class="napplet-preview">{asking.words.body}</p>}
          <div class="mod-row">
            <button type="button" class="napplet-danger" onClick={() => answer(true)}>{asking.words.yes}</button>
            <button type="button" onClick={() => answer(false)}>{asking.words.no}</button>
          </div>
        </Dialog>
      )}
    </div>
  )
}

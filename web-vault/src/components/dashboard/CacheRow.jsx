// "In your vault" › Cache (iPhone VaultContentsSection cacheRow; parity #30), where the web can: the copies of other
// people's data this page keeps for quick loading, your follows' contact lists (net/wot-store.js). Clear cache asks
// first, as the phone does, and they download again when needed. Other people's images and videos are the browser's
// own HTTP cache, which a page can neither size nor clear: the row says where to clear those.
import { useEffect, useState } from "preact/hooks"
import { wotStore } from "../../net/wot-store.js"
import { Dialog } from "../Moderation.jsx"
import { Row, RowButton } from "./parts.jsx"

export const CLEAR_TITLE = "Clear the cache?"
export const CLEAR_TEXT = "Removes the copies of other people's contact lists kept so your web of trust opens at once. Your own notes and media stay. They download again when needed."
export const MEDIA_NOTE = "Other people's images and videos are kept by your browser: clear them in its settings for this site."
export const cacheDetail = n => (n > 0 ? `${n.toLocaleString()} follows' contact lists, kept for quick loading` : "Nothing kept")

export function CacheRow({ me, store = wotStore(me) }) {
  const [n, setN] = useState(null)
  const [asking, setAsking] = useState(false)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)
  useEffect(() => { let live = true; store.count().then(c => { if (live) setN(c) }); return () => { live = false } }, [me])
  const clear = async () => {
    setAsking(false); setBusy(true)
    await store.clear()
    setN(await store.count()); setBusy(false); setDone(true)
  }
  return (
    <>
      <Row icon="stack" title="Cache" detail={n === null ? "Counting…" : done && !n ? "Cleared. They download again when needed." : cacheDetail(n)}>
        <RowButton title="Clear cache" busy={busy} disabled={busy || !n} onClick={() => setAsking(true)} />
      </Row>
      <div class="dash-row dash-note small muted">{MEDIA_NOTE}</div>
      {asking && (
        <Dialog label={CLEAR_TITLE} onClose={() => setAsking(false)}>
          <h3>{CLEAR_TITLE}</h3>
          <p class="muted small">{CLEAR_TEXT}</p>
          <div class="mod-row">
            <button type="button" class="danger" onClick={clear}>Clear</button>
            <button type="button" onClick={() => setAsking(false)}>Cancel</button>
          </div>
        </Dialog>
      )}
    </>
  )
}

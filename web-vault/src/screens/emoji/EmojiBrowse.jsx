// Browse emoji sets: your follows' first, then everyone's from the last month (Amethyst's browse feed), blocked people
// left out; or paste a set's link (naddr). Tapping one opens it, where it can be added.
import { useEffect, useState } from "preact/hooks"
import { browseSets, decodeSetLink, fetchSets, setRelays } from "../../net/emoji-sets.js"
import { useBlocks } from "../../components/useBlocks.js"
import { SkeletonList } from "../../components/Loading.jsx"
import { EmojiSetHead } from "./EmojiSetHead.jsx"
import { EmojiGrid } from "./EmojiGrid.jsx"

export function EmojiBrowse({ ctx, listed, onOpen, onBack }) {
  const { blocked, loaded } = useBlocks(ctx)
  const [found, setFound] = useState(null)
  const [link, setLink] = useState("")
  const [note, setNote] = useState("")
  useEffect(() => {
    if (!loaded) return
    let live = true
    browseSets(ctx, { blocked }).then(s => live && setFound(s), () => live && setFound([]))
    return () => { live = false }
  }, [loaded])
  const openLink = async e => {
    e.preventDefault()
    const d = decodeSetLink(link)
    if (!d) return setNote("That isn't an emoji set link. Paste one that starts with naddr1.")
    setNote("Looking for that set…")
    const got = await fetchSets(ctx, [d.address], { relays: setRelays(ctx, d.relays) }).catch(() => new Map())
    const set = got.get(d.address)
    if (!set) return setNote("No relay had that set.")
    setNote(""); onOpen(set)
  }
  return (
    <section class="emoji-browse">
      <button type="button" class="small" onClick={onBack}>‹ My emoji</button>
      <form class="emoji-link" onSubmit={openLink}>
        <input type="text" placeholder="Paste an emoji set link (naddr1…)" value={link} onInput={e => setLink(e.currentTarget.value)} aria-label="Emoji set link" />
        <button type="submit" class="small" disabled={!link.trim()}>Open</button>
      </form>
      {note && <p class="status-line" role="status">{note}</p>}
      {found === null ? <SkeletonList rowClass="emoji-set" label="Looking for emoji sets…" />
        : !found.length ? <p class="empty">No emoji sets found on your relays.</p>
        : found.map(set => (
          <div key={set.address} class="emoji-set">
            <EmojiSetHead set={set} badge={listed.has(set.address) ? "In your list" : null} onOpen={() => onOpen(set)} />
            <EmojiGrid set={set} limit={12} />
          </div>
        ))}
    </section>
  )
}

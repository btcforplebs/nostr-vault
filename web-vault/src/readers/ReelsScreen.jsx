// The diVines feed (the iPhone's ReelsFeedView): one looping video per page, scrolled up and down page by page, the one
// in view playing (muted until you unmute), Following or Global. Older pages come as you near the end. Over each video:
// who posted it and when, its title and caption, and the iPhone's rail (Post, Like, Reply, Thread, Share, Mute).
// Videos are only loaded near the one in view. Nothing is stored (readers/reels.js).
import { useEffect, useRef, useState } from "preact/hooks"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { Scopes } from "./ArticlesScreen.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { ReelPage } from "./ReelPage.jsx"
import { EMPTY_PAGES_MAX, REEL_SCOPES, fetchReelPage, loadScope, mergeReels, reelsEmpty, saveScope } from "./reels.js"

if (import.meta.env) import("../styles/reels.css")

/** How many pages either side of the one in view keep their video loaded. */
const NEAR = 1

export function ReelsScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadScope)
  const [reels, setReels] = useState(null)
  const [state, setState] = useState({ loading: false, failed: false, noFollows: false })
  const [at, setAt] = useState(0)
  const [muted, setMuted] = useState(true)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)
  const page = useRef({ cursor: null, empty: 0, end: false, busy: false })
  const pager = useRef(null)
  const list = useRef([]) // what is shown, for the next page to add to
  const canPost = !ctx.signer?.readOnly

  const load = async (more = false) => {
    if (page.current.busy && more) return
    const n = more ? seq.current : ++seq.current
    if (!more) { page.current = { cursor: null, empty: 0, end: false, busy: false }; setAt(0) }
    if (navigator.onLine === false) { if (!more) { list.current = []; setReels([]) } return setState({ loading: false, failed: true, noFollows: false }) }
    page.current.busy = true
    setState(s => ({ ...s, loading: true, failed: false }))
    try {
      const got = await fetchReelPage({ scope, me: ctx.session?.pubkey, follows, readRelays: account.relays.read, until: more ? page.current.cursor : null })
      if (n !== seq.current) return
      const base = more ? list.current : []
      const next = mergeReels(base, got.events, { blocked, trust: got.trust })
      const added = next.length - base.length
      list.current = next
      setReels(next)
      page.current.cursor = got.cursor
      page.current.empty = added ? 0 : page.current.empty + 1
      page.current.end = got.cursor === null || page.current.empty >= EMPTY_PAGES_MAX
      setState({ loading: false, failed: !got.answered, noFollows: got.noFollows })
      const authors = [...new Set(got.events.map(e => e.pubkey))].slice(0, 200)
      if (authors.length) fetchProfiles(vault, authors, account.relays.read, { save: false }).catch(() => {})
    } catch {
      if (n === seq.current) { if (!more) { list.current = []; setReels([]) } setState({ loading: false, failed: true, noFollows: false }) }
    } finally { if (n === seq.current) page.current.busy = false }
  }
  useEffect(() => { setReels(null); load() }, [scope, follows.length, blocked.size])

  // The page in view is the one more than half on screen.
  useEffect(() => {
    const box = pager.current
    if (!box || !reels?.length || !globalThis.IntersectionObserver) return
    const io = new IntersectionObserver(entries => {
      for (const e of entries) if (e.isIntersecting) setAt(Number(e.target.dataset.index))
    }, { root: box, threshold: 0.6 })
    for (const el of box.children) if (el.dataset.index) io.observe(el)
    return () => io.disconnect()
  }, [reels?.length])
  // Near the end: the next page, unless one is on its way or the history is spent.
  useEffect(() => {
    if (reels?.length && at >= reels.length - 3 && !page.current.end && !page.current.busy && !state.loading) load(true)
  }, [at, reels?.length])

  const pick = s => { saveScope(s); setScope(s) }
  const empty = reels && !reels.length && !state.loading && reelsEmpty({ scope, noFollows: state.noFollows, failed: state.failed })
  return (
    <div class="reader-feed reels-feed">
      <Scopes scopes={REEL_SCOPES} value={scope} onPick={pick} onRefresh={() => (at === 0 ? load() : undefined)}>
        {canPost && <PostDivineButton />}
      </Scopes>
      {reels === null || (!reels.length && state.loading) ? <div class="reels-pager reels-wait" role="status"><span class="spinner" aria-hidden="true" />Loading videos…</div>
        : empty ? <EmptyState title={empty.title} detail={empty.detail}
            action={empty.action === "global" ? { label: "Show Global videos", onClick: () => pick("global") } : { label: "Try again", onClick: () => load() }} />
        : <div class="reels-pager" ref={pager}>
            {reels.map((r, i) => (
              <ReelPage key={r.id} reel={r} index={i} ctx={ctx} active={i === at} near={Math.abs(i - at) <= NEAR}
                muted={muted} onMute={() => setMuted(!muted)} canPost={canPost} />
            ))}
            {state.loading && <div class="reels-more" role="status"><span class="spinner" aria-hidden="true" /></div>}
          </div>}
    </div>
  )
}

/** The button the iPhone floats over diVines (FeedActions ModeComposer .divine): opens New diVine. */
export const PostDivineButton = () => (
  <a class="reader-compose" href="#/compose?type=divine" aria-label="Post a diVine" title="Post a diVine">
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M23 7l-7 5 7 5V7zM1 5h15v14H1z" /></svg>
    diVine
  </a>
)

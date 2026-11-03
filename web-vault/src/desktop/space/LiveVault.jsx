// Live Vault: the first of "Your space"'s panels. The Vault list's newest lines beside whatever is open, the faces
// behind them on top. What arrives goes on top by itself (live-vault.js place; no "N new" pill, Logen 2026-11-03), and
// lines already drawn keep their slots; scrolled down, the row you are on stays where it is. The Vault is marked seen
// by a look at the Vault list. A line opens what it is about in the left column (notify-watch.js lineHref).
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../../components/Avatar.jsx"
import { Who } from "../../components/ActivityFaces.jsx"
import { ago } from "../../components/time.js"
import { verb } from "../../screens/VaultScreen.jsx"
import { lineHref } from "../../net/notify-watch.js"
import { useVaultLines } from "./useVaultLines.js"
import { place, sameShot, splitShown, topFaces, rowText, facesText, MAX_ROWS } from "./live-vault.js"
import { Icon, ICON } from "../Sidebar.jsx"

export function LiveVault({ ctx, open = true, tools = null }) {
  const { lines, unread, fetched } = useVaultLines(ctx)
  // What is on screen (live-vault.js snapshot), from when the first ask of the relays is done; until then the panel is
  // loading, and draws lines as they come. After that, new lines are placed on top as they arrive.
  const [shown, setShown] = useState(null)
  const list = useRef()
  // The row at the top of the view when lines came in, to hold it there (only when scrolled down: at the top, the
  // new lines show).
  const anchor = useRef(null)
  useEffect(() => {
    if (!lines || !fetched) return
    const next = place(lines, shown)
    if (sameShot(next, shown)) return
    anchor.current = topRow(list.current)
    setShown(next)
  }, [lines, fetched])
  useLayoutEffect(() => {
    const a = anchor.current, ul = list.current
    anchor.current = null
    if (!a || !ul) return
    const el = ul.querySelector(`[data-id="${a.id}"]`)
    if (el) ul.scrollTop = el.offsetTop - a.offset
  }, [shown])
  // Every row's picture loads here (Logen, 2026-11-02 polish): these are people who just liked, replied to, zapped or
  // followed you. The Vault list itself still waits on a stranger's picture.
  const trusted = () => true
  const rows = !lines ? [] : shown ? splitShown(lines, shown).rows : lines.slice(0, MAX_ROWS)
  const news = lines ? lines.filter(r => unread.has(r.id)) : []
  const { faces, more } = topFaces(news.length ? news : rows)
  return (
    <section class={open ? "sp-panel live-vault" : "sp-panel live-vault closed"} aria-label="Live Vault">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={ICON.vault} size={15} /></span>
        <h3>Live Vault</h3>
        <span class="sp-live" title="New lines come in while this page is open"><span class="sp-pulse" />Live</span>
        {!open && unread.size > 0 && <span class="sp-count" role="img" aria-label={`${unread.size} new`}>{unread.size}</span>}
        {tools}
      </header>
      {faces.length > 0 && (
        <div class="sp-faces" aria-hidden="true">
          {faces.map(pk => <Avatar key={pk} pubkey={pk} size={30} load={trusted(pk)} />)}
          <span class="sp-faces-text">{facesText(faces.length + more, news.length > 0)}</span>
        </div>
      )}
      <ul class="sp-rows" ref={list}>
        {!rows.length && !fetched ? <li class="sp-empty">Reading your vault…</li>
          : !rows.length ? <li class="sp-empty">Nothing yet. Likes, replies, zaps and follows show up here as they come in.</li>
          : rows.map(r => <Row key={r.id} row={r} unread={unread.has(r.id)} trusted={trusted} />)}
      </ul>
      <a class="sp-foot" href="#/vault/activity">Open the Vault list ›</a>
    </section>
  )
}

/** One line, one fixed height: the face, who did what, a line of text, when. A click opens it on the left. */
function Row({ row, unread, trusted }) {
  const text = rowText(row.preview ?? "")
  return (
    <li data-id={row.id}>
      <a class={unread ? "sp-row unread" : "sp-row"} href={lineHref(row)}>
        <Avatar pubkey={row.actors[0]} size={32} load={trusted(row.actors[0])} />
        <span class="sp-row-main">
          <span class="sp-row-who"><Who who={row.actors} /> {verb(row)}</span>
          <span class="sp-row-text">{text || " "}</span>
        </span>
        <span class="sp-row-side">
          <time datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
          {unread && <span class="sp-dot" role="img" aria-label="New" />}
        </span>
      </a>
    </li>
  )
}

/** The first row at least partly in view and how far its top is below the view's top; null at the very top. */
function topRow(ul) {
  if (!ul || ul.scrollTop <= 0) return null
  for (const li of ul.children) {
    if (li.offsetTop + li.offsetHeight > ul.scrollTop && li.dataset.id) return { id: li.dataset.id, offset: li.offsetTop - ul.scrollTop }
  }
  return null
}

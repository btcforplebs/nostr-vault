// Live Vault: the first of "Your space"'s panels. The Vault list's newest lines beside whatever is open, the faces
// behind them on top, and a "N new" pill. It holds still while you read it (live-vault.js splitShown): what arrives
// waits behind the pill, which draws it and marks it seen, as a look at the Vault list does. A line opens what it is
// about in the left column (notify-watch.js lineHref).
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../../components/Avatar.jsx"
import { Who } from "../../components/ActivityFaces.jsx"
import { ago } from "../../components/time.js"
import { verb } from "../../screens/VaultScreen.jsx"
import { lineHref } from "../../net/notify-watch.js"
import { readSeen, writeSeen, markSeen } from "../../net/vault-new.js"
import { useVaultLines } from "./useVaultLines.js"
import { snapshot, splitShown, topFaces, pillCount, rowText, facesText, MAX_ROWS } from "./live-vault.js"
import { Icon, ICON } from "../Sidebar.jsx"

export function LiveVault({ ctx }) {
  const me = ctx.session.pubkey
  const { lines, unread, fetched } = useVaultLines(ctx)
  // What is on screen (live-vault.js snapshot), from when the first ask of the relays is done; until then the panel is
  // loading, and draws lines as they come.
  const [shown, setShown] = useState(null)
  useEffect(() => { if (lines && fetched && shown === null) setShown(snapshot(lines)) }, [lines, fetched])
  const list = useRef()
  // Every row's picture loads here (Logen, 2026-11-02 polish): these are people who just liked, replied to, zapped or
  // followed you. The Vault list itself still waits on a stranger's picture.
  const trusted = () => true
  const { rows, held } = !lines ? { rows: [], held: [] } : shown ? splitShown(lines, shown) : { rows: lines.slice(0, MAX_ROWS), held: [] }
  const pill = pillCount(unread.size, held.length)
  const news = lines ? lines.filter(r => unread.has(r.id)) : []
  const { faces, more } = topFaces(news.length ? news : rows)
  const showNew = () => {
    setShown(snapshot(lines))
    writeSeen(me, markSeen(readSeen(me), "activity", Math.floor(Date.now() / 1000)))
    if (list.current) list.current.scrollTop = 0
  }
  return (
    <section class="sp-panel live-vault" aria-label="Live Vault">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={ICON.vault} size={15} /></span>
        <h3>Live Vault</h3>
        <span class="sp-live" title="New lines come in while this page is open"><span class="sp-pulse" />Live</span>
        {pill > 0 && <button type="button" class="sp-new" onClick={showNew} title="Show what's new and mark it seen">{pill} new</button>}
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
    <li>
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

// "In your vault" (VaultContentsSection): how much room it takes, what it holds by kind, and its media files. The
// phone's Cache row is left out: other people's media is the browser's own HTTP cache here, which a page can neither
// size nor clear. The browser's own warning (it may clear the copy) closes the card.
import { ExpandingRow, Line, RowButton, Section } from "./parts.jsx"
import { StorageNote } from "../StorageNote.jsx"
import { groupRows, kindName, MEDIA_BUCKETS, sizeText } from "../../net/vault-contents.js"

const GROUP_ICONS = { notes: "note", articles: "article", highlights: "highlight", reactions: "heart", zaps: "bolt", messages: "envelope", profile: "person", other: "more" }

/** "1,234 events · 5.2 MB", or the size alone before the count. */
export const headerDetail = (contents, size) => (contents ? `${contents.total.toLocaleString()} ${contents.total === 1 ? "event" : "events"} · ${sizeText(size)}` : sizeText(size))

/** The bar's parts: everything Haven keeps that isn't a media file, and the media files. */
export const storageParts = (usage, media) => [
  { title: "Notes and data", size: Math.max(0, (usage ?? 0) - (media ?? 0)), cls: "data" },
  { title: "Media", size: media ?? 0, cls: "media" },
]

// The phone's "Public events only" never applies: this browser's device key is whitelisted on every route.
export const statusText = ({ counting }) => (counting ? "Counting…" : "Couldn't count.")

export function ContentsSection({ contents, counting, failed, usage, media, kept, onRetry }) {
  const parts = storageParts(usage, media?.size)
  const total = Math.max(1, parts.reduce((n, p) => n + p.size, 0))
  const status = counting || failed
  return (
    <Section title="In your vault" detail={headerDetail(contents, usage)}>
      <div class="dash-storage" role="img" aria-label={`Storage: ${parts.map(p => `${p.title} ${sizeText(p.size)}`).join(", ")}`}>
        <div class="dash-bar">{parts.filter(p => p.size > 0).map(p => <i key={p.cls} class={p.cls} style={{ width: `${Math.max(1, (100 * p.size) / total)}%` }} />)}</div>
        <div class="dash-legend">{parts.map(p => <span key={p.cls}><b class={p.cls} />{p.title}<em>{sizeText(p.size)}</em></span>)}</div>
      </div>
      {contents && groupRows(contents).map(r => (
        <ExpandingRow key={r.id} icon={GROUP_ICONS[r.id]} title={r.title} value={r.count.toLocaleString()}
          detail={r.yours != null ? `${r.yours.toLocaleString()} yours` : undefined} canExpand={r.kinds.length > 1}>
          {r.kinds.map(k => <Line key={k.kind ?? "x"} title={kindName(k.kind)} value={k.count.toLocaleString()} />)}
        </ExpandingRow>
      ))}
      {(!contents || status) && <div class="dash-row dash-note">{counting && <span class="dash-spin" aria-hidden="true" />}<span class="dash-text">{statusText({ counting })}</span>{!counting && <RowButton title="Try again" onClick={onRetry} />}</div>}
      <ExpandingRow icon="photo" title="Media files" value={media ? media.count.toLocaleString() : "—"} detail={media ? sizeText(media.size) : undefined} canExpand={(media?.count ?? 0) > 0}>
        {MEDIA_BUCKETS.filter(([k]) => media?.buckets[k].count > 0).map(([k, t]) => <Line key={k} title={t} value={`${media.buckets[k].count.toLocaleString()} · ${sizeText(media.buckets[k].size)}`} />)}
      </ExpandingRow>
      <div class="dash-row dash-note"><StorageNote kept={kept} /></div>
    </Section>
  )
}

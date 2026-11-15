// + Add for the side columns (plan NV_WEB_ONE_PLAN.md step 3): what can go in a column, in three groups (columns.js
// addGroups): our cards not shown, apps this account installed, and apps other people published on the user's relays
// (kind 35129, the catalog the Apps pane read). Adding one is the whole install: an app's bytes are fetched and
// hash-checked (catalog.js fetchArtifact), kept, and its card goes in the column; the card then asks the consent sheet
// the first time it opens, and an app you say no to is not kept (AppCard.jsx), as on the Apps pane.
import { useEffect, useMemo, useState } from "preact/hooks"
import { Dialog } from "../../components/Moderation.jsx"
import { readCatalog, fetchAppArtifact } from "../../napplet/shell-deps.js"
import { appStore } from "../../napplet/catalog.js"
import { parseManifest } from "../../napplet/manifest.js"
import { idbArtifacts } from "../../napplet/storage-idb.js"
import { addGroups, addCard, appCardId, LEFT, RIGHT } from "./columns.js"
import { PANEL_IDS } from "./panel-ids.js"
import "../../napplet/napplet.css"

const short = pk => `${pk.slice(0, 8)}…`

/** side: the column it adds to first; canLeft: the left column shows at this width; names: our cards' names by id. */
export function AddSheet({ ctx, layout, change, side: first, canLeft, names, onClose }) {
  const me = ctx.session.pubkey
  const apps = useMemo(() => appStore(localStorage, me), [me])
  const artifacts = useMemo(() => idbArtifacts(me), [me])
  const [side, setSide] = useState(canLeft ? first : RIGHT)
  const [catalog, setCatalog] = useState(null) // null: looking
  const [busy, setBusy] = useState("")
  const [note, setNote] = useState("")
  const [query, setQuery] = useState("")
  const look = () => { setCatalog(null); readCatalog(ctx).then(setCatalog, () => setCatalog([])) }
  useEffect(look, [me])
  const groups = addGroups({ layout, ids: PANEL_IDS, installed: apps.list(), catalog: catalog ?? [], manifestOf: parseManifest })
  const q = query.trim().toLowerCase()
  const match = (title, more = "") => !q || `${title} ${more}`.toLowerCase().includes(q)
  const put = id => change(l => addCard(l, id, side))
  async function install(entry) {
    setBusy(entry.line); setNote("")
    try {
      const html = await fetchAppArtifact(ctx, entry.event)
      await artifacts.put(entry.manifest.hash, html)
      apps.put(entry.event)
      put(appCardId(entry.line))
      onClose()
    } catch (e) {
      setNote(`Couldn't add ${entry.manifest.title}: ${e?.message ?? e}`)
    } finally { setBusy("") }
  }
  const where = side === LEFT ? "the left column" : "Your space"
  return (
    <Dialog label="Add a card" onClose={onClose}>
      <div class="sp-addsheet">
        <h3>Add to {where}</h3>
        {canLeft && (
          <div class="sp-addsheet-side" role="radiogroup" aria-label="Which column">
            {[[LEFT, "Left"], [RIGHT, "Right"]].map(([s, word]) => (
              <button key={s} type="button" role="radio" aria-checked={side === s} class={side === s ? "on" : ""} onClick={() => setSide(s)}>{word}</button>
            ))}
          </div>
        )}
        <input type="search" class="apps-search" placeholder="Find a card or an app" value={query} onInput={e => setQuery(e.currentTarget.value)} />
        {note && <p class="muted small" role="status">{note}</p>}

        <section aria-label="Ours">
          <h4>Nostr Vault's</h4>
          {groups.ours.filter(id => match(names[id])).length === 0
            ? <p class="muted small">{q ? "None matches." : "All of ours are showing."}</p>
            : <ul class="apps-list">{groups.ours.filter(id => match(names[id])).map(id => (
              <li key={id} class="apps-row">
                <span class="apps-icon" aria-hidden="true">{names[id].slice(0, 1)}</span>
                <div class="apps-what"><b>{names[id]}</b><span class="muted small">Nostr Vault's own</span></div>
                <div class="apps-acts"><button type="button" class="primary" onClick={() => { put(id); onClose() }}>Add</button></div>
              </li>
            ))}</ul>}
        </section>

        {groups.installed.some(a => match(a.manifest.title)) && (
          <section aria-label="Installed">
            <h4>Your apps</h4>
            <ul class="apps-list">{groups.installed.filter(a => match(a.manifest.title)).map(a => (
              <li key={a.line} class="apps-row">
                <span class="apps-icon" aria-hidden="true">{a.manifest.title.slice(0, 1).toUpperCase()}</span>
                <div class="apps-what"><b>{a.manifest.title}</b><span class="muted small">by {short(a.manifest.publisher)} · {a.surface.widget ? "made as a card" : "a full app, shown as a panel"}</span></div>
                <div class="apps-acts"><button type="button" class="primary" onClick={() => { put(appCardId(a.line)); onClose() }}>Add</button></div>
              </li>
            ))}</ul>
          </section>
        )}

        <section aria-label="Other people's">
          <div class="apps-head"><h4>Other people's</h4><button type="button" class="sp-link" onClick={look} disabled={catalog === null}>{catalog === null ? "Looking…" : "Look again"}</button></div>
          <p class="muted small">Cards and apps people published to your relays. Nostr Vault hasn't checked them: each runs walled off, sees public data only, and asks before it gets anything.</p>
          {catalog !== null && groups.catalog.filter(e => match(e.manifest.title, e.summary)).length === 0 && <p class="muted small">{q ? "None matches." : "None found on your relays."}</p>}
          <ul class="apps-list">{groups.catalog.filter(e => match(e.manifest.title, e.summary)).map(e => (
            <li key={e.line} class="apps-row">
              {/* Letter icon only: a publisher-named icon host would see the IP of everyone who opens this sheet. */}
              <span class="apps-icon" aria-hidden="true">{e.manifest.title.slice(0, 1).toUpperCase()}</span>
              <div class="apps-what"><b>{e.manifest.title}</b><span class="muted small">by {short(e.manifest.publisher)}{e.surface.widget ? " · made as a card" : ""}{e.summary ? ` · ${e.summary}` : ""}</span></div>
              <div class="apps-acts"><button type="button" class="primary" disabled={!!busy} onClick={() => install(e)}>{busy === e.line ? "Adding…" : "Add"}</button></div>
            </li>
          ))}</ul>
        </section>
        <div class="mod-row"><button type="button" onClick={onClose}>Done</button></div>
      </div>
    </Dialog>
  )
}

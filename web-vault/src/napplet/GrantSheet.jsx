// The consent sheet and the "may it…?" ask, shared by the Apps pane (NappletShell.jsx) and the app cards in the side
// columns (desktop/space/AppCard.jsx): one sheet, so a grant is made the same way wherever an app is opened. The sheet
// only reports what the user ticked; runtime.js turns it into the grant (policy.js outsideGrant), as it always did.
import { useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { domainWord, PUBLIC_WORDS } from "./consent-words.js"
import { outsideGrant } from "./policy.js"

/** Access saved: the same shape the consent sheet makes (runtime.js outsideGrant); only what it may ask for changes.
 *  The one place an app's grant is changed after it first opened (the Apps pane and the app cards both call it). */
export const saveAccessGrant = (grants, key, grant, domains) => grants.set(key, outsideGrant({ ...grant, domains }))

/** The consent sheet, first time (no `grant`) or again from Access (`grant`: what the user said before). */
export function GrantSheet({ title, from, domains, grant = null, yes, onDone }) {
  const offered = domains.filter(d => d !== "shell")
  const [on, setOn] = useState(() => new Set(grant ? offered.filter(d => grant.domains.includes(d)) : offered))
  const toggle = d => setOn(s => { const n = new Set(s); n.has(d) ? n.delete(d) : n.add(d); return n })
  return (
    <Dialog label={title} onClose={() => onDone(null)}>
      <h3>{title}</h3>
      <p class="muted small">From {from}. It runs walled off: no network and no keys of its own. Choose what it may ask Nostr Vault for.</p>
      <ul class="napplet-grants">
        {offered.map(d => <li key={d}><label><input type="checkbox" checked={on.has(d)} onChange={() => toggle(d)} /> {domainWord(d)}</label></li>)}
      </ul>
      <p class="muted small napplet-private">{PUBLIC_WORDS}</p>
      <div class="mod-row">
        <button type="button" class="primary" onClick={() => onDone({ domains: ["shell", ...on] })}>{yes}</button>
        <button type="button" onClick={() => onDone(null)}>Cancel</button>
      </div>
    </Dialog>
  )
}

/** A napplet asking for one thing (consent-words.js askWords): yes or no. */
export function AskDialog({ words, onDone }) {
  return (
    <Dialog label={words.title} onClose={() => onDone(false)}>
      <h3>{words.title}</h3>
      {words.image && <img class="napplet-ask-image" src={words.image} alt="" referrerpolicy="no-referrer" style="max-width:100%;max-height:220px;border-radius:8px;object-fit:contain" />}
      {words.body && <p class="napplet-preview">{words.body}</p>}
      <div class="mod-row">
        <button type="button" class="primary" onClick={() => onDone(true)}>{words.yes}</button>
        <button type="button" onClick={() => onDone(false)}>{words.no}</button>
      </div>
    </Dialog>
  )
}

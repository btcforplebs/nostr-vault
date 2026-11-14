// The napplet shell page, hidden behind ?shell=1 (main.jsx) until the Apps pane (P3). Opens our own napplets and a
// napplet file the user picks, and answers both through the runtime (runtime.js): the consent sheet the first time an
// outside napplet opens, the ask sheet before anything is signed, uploaded or notified for it.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { FIRST_PARTY } from "./first-party.js"
import { domainWord, PRIVATE_WORDS, askWords } from "./consent-words.js"
import "./napplet.css"

const MAX_FILE = 5 * 1024 * 1024

export function NappletShell({ ctx }) {
  const host = useRef(null)
  const [open, setOpen] = useState(null) // { ident, domains, grant, mounted }
  const [consent, setConsent] = useState(null) // { ident, domains, resolve }
  const [asking, setAsking] = useState(null) // { words, resolve }
  const [note, setNote] = useState("")
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const bus = useMemo(() => createBus(), [])
  const ask = ({ napplet, what, detail }) => new Promise(resolve => setAsking({ words: askWords(what, napplet, detail), resolve }))
  useEffect(() => () => open?.mounted.close(), [open])

  async function launch(source) {
    open?.mounted.close()
    setOpen(null)
    setNote("")
    try {
      const r = await openNapplet({
        ...source, container: host.current, grants,
        consent: ({ ident, domains }) => new Promise(resolve => setConsent({ ident, domains, resolve })),
        makeDeps: saveGrant => shellDeps(ctx, { ask, saveGrant, bus }),
        onRevoke: why => { setOpen(null); if (why !== "closed by shell") setNote(`Closed: ${why}.`) },
      })
      setOpen(r)
    } catch (e) {
      setNote(String(e?.message ?? e))
    }
  }
  async function pickFile(e) {
    const f = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!f) return
    if (f.size > MAX_FILE) return setNote("That file is over 5 MB; a napplet is one small index.html.")
    launch({ html: await f.text(), name: f.name.replace(/\.html?$/i, "") || "napplet" })
  }

  return (
    <main class="screen napplet-shell">
      <header class="screen-head"><h2>Napplets <span class="muted small">preview</span></h2></header>
      <div class="napplet-bar">
        {FIRST_PARTY.map(n => <button type="button" key={n.dTag} onClick={() => launch({ html: n.html, name: n.dTag, title: n.title, firstParty: true })}>{n.title}</button>)}
        <label class="button">Open a file…<input type="file" accept=".html,text/html" hidden onChange={pickFile} /></label>
        {open && <button type="button" onClick={() => open.mounted.close()}>Close {open.ident.title}</button>}
      </div>
      {open && <p class="muted small napplet-who">{open.ident.title} · {open.grant.firstParty ? "Nostr Vault's own" : open.grant.privateData ? "can see your vault's private data" : "public data only"} · {open.ident.hash.slice(0, 12)}</p>}
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host" ref={host} />
      {consent && <ConsentSheet {...consent} onDone={g => { consent.resolve(g); setConsent(null) }} />}
      {asking && (
        <Dialog label={asking.words.title} onClose={() => { asking.resolve(false); setAsking(null) }}>
          <h3>{asking.words.title}</h3>
          {asking.words.body && <p class="napplet-preview">{asking.words.body}</p>}
          <div class="mod-row">
            <button type="button" class="primary" onClick={() => { asking.resolve(true); setAsking(null) }}>{asking.words.yes}</button>
            <button type="button" onClick={() => { asking.resolve(false); setAsking(null) }}>{asking.words.no}</button>
          </div>
        </Dialog>
      )}
    </main>
  )
}

function ConsentSheet({ ident, domains, onDone }) {
  const offered = domains.filter(d => d !== "shell")
  const [on, setOn] = useState(() => new Set(offered))
  const [priv, setPriv] = useState(false)
  const toggle = d => setOn(s => { const n = new Set(s); n.has(d) ? n.delete(d) : n.add(d); return n })
  const from = ident.publisher === "local" ? "a file you picked" : `${ident.publisher.slice(0, 8)}…`
  return (
    <Dialog label={`Open ${ident.title}?`} onClose={() => onDone(null)}>
      <h3>Open {ident.title}?</h3>
      <p class="muted small">From {from}. It runs walled off: no network and no keys of its own. Choose what it may ask Nostr Vault for.</p>
      <ul class="napplet-grants">
        {offered.map(d => <li key={d}><label><input type="checkbox" checked={on.has(d)} onChange={() => toggle(d)} /> {domainWord(d)}</label></li>)}
      </ul>
      <label class="napplet-private"><input type="checkbox" checked={priv} onChange={e => setPriv(e.currentTarget.checked)} /> <span><b>{PRIVATE_WORDS.label}</b><br /><span class="muted small">{PRIVATE_WORDS.help}</span></span></label>
      <div class="mod-row">
        <button type="button" class="primary" onClick={() => onDone({ domains: ["shell", ...on], privateData: priv })}>Open</button>
        <button type="button" onClick={() => onDone(null)}>Cancel</button>
      </div>
    </Dialog>
  )
}

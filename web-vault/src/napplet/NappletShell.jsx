// The Apps pane (plan P3): the napplets this account installed, the catalog (kind 35129 manifests on the user's
// relays), Nostr Vault's own napplets and a napplet file the user picks, all opened through the runtime (runtime.js).
// Reached at #/apps from the Vault menu when the napplet switch is on, and at /vault/?shell=1 (where the switch is).
// The consent sheet asks the first time an outside napplet opens; "Access" shows that answer again and lets the user
// change it; Remove takes the app, its grants, its storage and its kept bytes away (catalog.js removeApp).
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps, readCatalog, fetchAppArtifact } from "./shell-deps.js"
import { FIRST_PARTY } from "./first-party.js"
import { nappletsOn, setNappletsOn } from "./flag.js"
import { domainWord, PRIVATE_WORDS, askWords } from "./consent-words.js"
import { appStore, updateFor, removeApp, retireVersion, MAX_ARTIFACT } from "./catalog.js"
import { parseManifest, nappletKey, domainsFor } from "./manifest.js"
import { idbNappletStorage, idbArtifacts } from "./storage-idb.js"
import { VaultPagesMenu } from "../screens/VaultPagesMenu.jsx"
import "./napplet.css"

const short = pk => `${pk.slice(0, 8)}…`
const keyOf = event => { const m = parseManifest(event); return nappletKey({ publisher: m.publisher, dTag: m.dTag, hash: m.hash }) }

export function NappletShell({ ctx, showSwitch = true, vaultMenu = false }) {
  const host = useRef(null)
  const account = ctx.session.pubkey
  const [open, setOpen] = useState(null) // { ident, domains, grant, mounted, line? }
  const [consent, setConsent] = useState(null) // { ident, domains, resolve }
  const [asking, setAsking] = useState(null) // { words, resolve }
  const [access, setAccess] = useState(null) // { app, key, grant, domains }
  const [note, setNote] = useState("")
  const [busy, setBusy] = useState("")
  const [mounting, setMounting] = useState(false)
  const [inApp, setInApp] = useState(nappletsOn)
  const [catalog, setCatalog] = useState(null) // null: looking
  const [query, setQuery] = useState("")
  const [, bump] = useState(0)
  const grants = useMemo(() => grantStore(localStorage, account), [account])
  const apps = useMemo(() => appStore(localStorage, account), [account])
  const storage = useMemo(() => idbNappletStorage(account), [account])
  const artifacts = useMemo(() => idbArtifacts(account), [account])
  const bus = useMemo(() => createBus(), [])
  const ask = ({ napplet, what, detail }) => new Promise(resolve => setAsking({ words: askWords(what, napplet, detail), resolve }))
  useEffect(() => () => open?.mounted.close(), [open])
  const loadCatalog = () => { setCatalog(null); readCatalog(ctx).then(setCatalog, () => setCatalog([])) }
  useEffect(loadCatalog, [account])

  async function launch(source) {
    open?.mounted.close()
    setOpen(null)
    setNote("")
    setMounting(true)
    try {
      const r = await openNapplet({
        ...source, container: host.current, grants,
        consent: ({ ident, domains }) => new Promise(resolve => setConsent({ ident, domains, resolve })),
        makeDeps: saveGrant => shellDeps(ctx, { ask, saveGrant, bus, storage }),
        onRevoke: why => { setOpen(null); if (why !== "closed by shell") setNote(`Closed: ${why}.`) },
      })
      setOpen({ ...r, line: source.line })
      return r
    } catch (e) {
      setNote(String(e?.message ?? e))
      return null
    } finally { setMounting(false) }
  }
  async function pickFile(e) {
    const f = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!f) return
    if (f.size > MAX_ARTIFACT) return setNote("That file is over 5 MB; a napplet is one small index.html.")
    launch({ html: await f.text(), name: f.name.replace(/\.html?$/i, "") || "napplet" })
  }
  // Install: the bytes (hash-checked), then open it, which asks the consent sheet. Kept only if the user said yes.
  async function install(entry, replacing = null) {
    setBusy(entry.line); setNote("")
    try {
      const html = await fetchAppArtifact(ctx, entry.event)
      const r = await launch({ html, manifestEvent: entry.event, line: entry.line })
      if (!r) return
      await artifacts.put(entry.manifest.hash, html)
      apps.put(entry.event)
      if (replacing) await retireVersion(replacing.event, entry.manifest.hash, { grants, storage, artifacts })
      bump(n => n + 1)
    } catch (e) {
      setNote(`Couldn't install ${entry.manifest.title}: ${e?.message ?? e}`)
    } finally { setBusy("") }
  }
  async function openApp(app) {
    setBusy(app.line); setNote("")
    try {
      const m = parseManifest(app.event)
      let html = await artifacts.get(m.hash).catch(() => null)
      if (!html) { html = await fetchAppArtifact(ctx, app.event); await artifacts.put(m.hash, html) }
      await launch({ html, manifestEvent: app.event, line: app.line })
    } catch (e) {
      setNote(`Couldn't open ${parseManifest(app.event).title}: ${e?.message ?? e}`)
    } finally { setBusy("") }
  }
  async function remove(app) {
    if (open?.line === app.line) open.mounted.close()
    await removeApp(app.line, { apps, grants, storage, artifacts })
    setNote(`Removed ${parseManifest(app.event).title}, with what it kept and what it was allowed.`)
    bump(n => n + 1)
  }
  function showAccess(app) {
    const key = keyOf(app.event)
    let domains = []
    try { domains = domainsFor(parseManifest(app.event)) } catch {}
    setAccess({ app, key, grant: grants.get(key), domains })
  }
  function saveAccess({ domains, privateData }) {
    const { app, key, grant } = access
    // Same shape the consent sheet makes (runtime.js); only what it may ask for and the private-data answer change.
    grants.set(key, { ...grant, domains, privateData: !!privateData })
    if (open?.line === app.line) { open.mounted.close(); setNote("Closed it so the new access applies; open it again.") }
    setAccess(null)
    bump(n => n + 1)
  }

  const installed = apps.list()
  const entries = catalog ?? []
  const q = query.trim().toLowerCase()
  const shown = q ? entries.filter(e => `${e.manifest.title} ${e.summary}`.toLowerCase().includes(q)) : entries
  const has = new Set(installed.map(a => a.line))

  return (
    <main class="screen napplet-shell">
      <header class="screen-head">{vaultMenu ? <><VaultPagesMenu ctx={ctx} current="apps" /><h2 class="sr-only">Apps</h2></> : <h2>Apps <span class="muted small">preview</span></h2>}</header>
      {showSwitch && <label class="napplet-inapp muted small"><input type="checkbox" checked={inApp} onChange={e => { setNappletsOn(e.currentTarget.checked); setInApp(e.currentTarget.checked) }} /> Use napplets in the app (preview): Apps in the Vault menu, and Compose's emoji button opens the Emoji napplet</label>}
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      {open && (
        <div class="napplet-running">
          <p class="muted small napplet-who">{open.ident.title} · {open.grant.firstParty ? "Nostr Vault's own" : open.grant.privateData ? "can see your vault's private data" : "public data only"} · {open.ident.hash.slice(0, 12)}</p>
          <button type="button" onClick={() => open.mounted.close()}>Close {open.ident.title}</button>
        </div>
      )}
      <div class={`napplet-host${open || mounting ? " on" : ""}`} ref={host} />

      <section class="apps-section" aria-label="Installed">
        <h3>Installed</h3>
        {installed.length === 0 ? <p class="muted small">Nothing yet. Install one from the catalog below.</p> : (
          <ul class="apps-list">
            {installed.map(app => {
              const m = parseManifest(app.event), grant = grants.get(keyOf(app.event)), upd = updateFor(app, entries)
              return (
                <li key={app.line} class="apps-row">
                  <span class="apps-icon" aria-hidden="true">{m.title.slice(0, 1).toUpperCase()}</span>
                  <div class="apps-what"><b>{m.title}</b><span class="muted small">by {short(m.publisher)} · {grant?.privateData ? "can see your vault's private data" : "public data only"}</span></div>
                  <div class="apps-acts">
                    <button type="button" class="primary" disabled={busy === app.line} onClick={() => openApp(app)}>{busy === app.line ? "Opening…" : "Open"}</button>
                    {upd && <button type="button" disabled={!!busy} onClick={() => install(upd, app)}>Update</button>}
                    <button type="button" disabled={!grant} onClick={() => showAccess(app)}>Access</button>
                    <button type="button" class="danger" onClick={() => remove(app)}>Remove</button>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </section>

      <section class="apps-section" aria-label="Nostr Vault's own">
        <h3>Nostr Vault's own</h3>
        <div class="napplet-bar">
          {FIRST_PARTY.map(n => <button type="button" key={n.dTag} onClick={() => launch({ html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains })}>{n.title}</button>)}
          <label class="button">Open a file…<input type="file" accept=".html,text/html" hidden onChange={pickFile} /></label>
        </div>
      </section>

      <section class="apps-section" aria-label="Catalog">
        <div class="apps-head"><h3>Catalog</h3><button type="button" onClick={loadCatalog} disabled={catalog === null}>{catalog === null ? "Looking…" : "Look again"}</button></div>
        <p class="muted small">Napplets people published to your relays. Nostr Vault hasn't checked them: each runs walled off and asks before it gets anything.</p>
        {entries.length > 6 && <input type="search" class="apps-search" placeholder="Find an app" value={query} onInput={e => setQuery(e.currentTarget.value)} />}
        {catalog !== null && shown.length === 0 && <p class="muted small">{q ? "No app matches." : "None found on your relays."}</p>}
        <ul class="apps-list">
          {shown.map(e => (
            <li key={e.line} class="apps-row">
              {/* Letter icon only: a publisher-named icon host would see the IP of everyone who opens the catalog. */}
              <span class="apps-icon" aria-hidden="true">{e.manifest.title.slice(0, 1).toUpperCase()}</span>
              <div class="apps-what"><b>{e.manifest.title}</b><span class="muted small">by {short(e.manifest.publisher)}{e.summary ? ` · ${e.summary}` : ""}</span>{!e.runs && <span class="muted small">{e.why}</span>}</div>
              <div class="apps-acts">
                {has.has(e.line) ? <span class="muted small">Installed</span>
                  : <button type="button" class="primary" disabled={!e.runs || !!busy} onClick={() => install(e)}>{busy === e.line ? "Installing…" : "Install"}</button>}
              </div>
            </li>
          ))}
        </ul>
      </section>

      {consent && <GrantSheet title={`Open ${consent.ident.title}?`} from={consent.ident.publisher === "local" ? "a file you picked" : short(consent.ident.publisher)} domains={consent.domains} yes="Open" onDone={g => { consent.resolve(g); setConsent(null) }} />}
      {access && <GrantSheet title={`What ${parseManifest(access.app.event).title} may do`} from={short(parseManifest(access.app.event).publisher)} domains={access.domains} grant={access.grant} yes="Save" onDone={g => (g ? saveAccess(g) : setAccess(null))} />}
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

/** The consent sheet, first time (no `grant`) or again from Access (`grant`: what the user said before). */
function GrantSheet({ title, from, domains, grant = null, yes, onDone }) {
  const offered = domains.filter(d => d !== "shell")
  const [on, setOn] = useState(() => new Set(grant ? offered.filter(d => grant.domains.includes(d)) : offered))
  const [priv, setPriv] = useState(!!grant?.privateData)
  const toggle = d => setOn(s => { const n = new Set(s); n.has(d) ? n.delete(d) : n.add(d); return n })
  return (
    <Dialog label={title} onClose={() => onDone(null)}>
      <h3>{title}</h3>
      <p class="muted small">From {from}. It runs walled off: no network and no keys of its own. Choose what it may ask Nostr Vault for.</p>
      <ul class="napplet-grants">
        {offered.map(d => <li key={d}><label><input type="checkbox" checked={on.has(d)} onChange={() => toggle(d)} /> {domainWord(d)}</label></li>)}
      </ul>
      <label class="napplet-private"><input type="checkbox" checked={priv} onChange={e => setPriv(e.currentTarget.checked)} /> <span><b>{PRIVATE_WORDS.label}</b><br /><span class="muted small">{PRIVATE_WORDS.help}</span></span></label>
      <div class="mod-row">
        <button type="button" class="primary" onClick={() => onDone({ domains: ["shell", ...on], privateData: priv })}>{yes}</button>
        <button type="button" onClick={() => onDone(null)}>Cancel</button>
      </div>
    </Dialog>
  )
}

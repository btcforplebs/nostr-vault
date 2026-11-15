// An installed app as a card in a side column (plan NV_WEB_ONE_PLAN.md step 3): the shell draws the header (letter
// icon, name, the edit tools or collapse and ···), the app draws the body in its own walled-off frame. It opens the way
// the Apps pane opens one (runtime.js openNapplet): the bytes kept at install, hash-checked; the consent sheet the
// first time (GrantSheet.jsx, the same sheet); public data only for anyone else's app (shell rule 1).
// Cost (plan §2): at most MAX_FRAMES app frames run at once (frames.js); a collapsed card's frame closes after a
// minute, and none runs while the columns are being edited (a frame would swallow the drag).
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { openNapplet } from "../../napplet/runtime.js"
import { grantStore } from "../../napplet/policy.js"
import { createBus } from "../../napplet/bus.js"
import { shellDeps, fetchAppArtifact } from "../../napplet/shell-deps.js"
import { useLiveCtx } from "../../napplet/usePaneNapplet.js"
import { appStore, removeApp } from "../../napplet/catalog.js"
import { parseManifest, nappletKey, domainsFor } from "../../napplet/manifest.js"
import { idbNappletStorage, idbArtifacts } from "../../napplet/storage-idb.js"
import { askWords, PUBLIC_ONLY } from "../../napplet/consent-words.js"
import { GrantSheet, AskDialog, saveAccessGrant } from "../../napplet/GrantSheet.jsx"
import { SIZE_PX, appSize, surfaceOf, lineOfCard } from "./columns.js"
import { claimFrame, whenFree } from "./frames.js"
import "../../napplet/napplet.css"

export const CLOSE_AFTER_MS = 60_000
const MORE = "M5 12h.01M12 12h.01M19 12h.01"
const short = pk => `${pk.slice(0, 8)}…`

/** The app's name for a card id, from what this account installed ("" when it isn't installed any more). */
export function appTitle(me, id) {
  const app = appStore(localStorage, me).get(lineOfCard(id))
  try { return app ? parseManifest(app.event).title : "" } catch { return "" }
}

/**
 * id: "napplet:<line>"; open: false = collapsed to its header; size: the saved one (columns.js); tools: the column's
 * edit buttons while editing (null otherwise); onGone(): the app was removed or never allowed, take its card away.
 */
export function AppCard({ ctx, id, open, size, editing, tools, onGone }) {
  const me = ctx.session.pubkey
  const line = lineOfCard(id)
  const apps = useMemo(() => appStore(localStorage, me), [me])
  const grants = useMemo(() => grantStore(localStorage, me), [me])
  const storage = useMemo(() => idbNappletStorage(me), [me])
  const artifacts = useMemo(() => idbArtifacts(me), [me])
  const liveCtx = useLiveCtx(ctx)
  const app = apps.get(line)
  const manifest = useMemo(() => { try { return app && parseManifest(app.event) } catch { return null } }, [app?.event?.id])
  const sizes = surfaceOf(app?.event).sizes
  const drawn = appSize(size, sizes)
  const host = useRef(null)
  const [note, setNote] = useState("")
  const [consent, setConsent] = useState(null) // { ident, domains, resolve }
  const [asking, setAsking] = useState(null) // { words, resolve }
  const [access, setAccess] = useState(null) // { key, grant, domains }
  const [menu, setMenu] = useState(false)
  const [tries, setTries] = useState(0)
  // Runs while open and not editing; after a collapse it keeps running a minute, in case it opens again.
  const [wanted, setWanted] = useState(open && !editing)
  useEffect(() => {
    if (open && !editing) { setWanted(true); return }
    if (editing) { setWanted(false); return }
    const t = setTimeout(() => setWanted(false), CLOSE_AFTER_MS)
    return () => clearTimeout(t)
  }, [open, editing])

  useEffect(() => {
    if (!wanted || !manifest) return
    const release = claimFrame(id)
    if (!release) { setNote("full"); return whenFree(() => setTries(t => t + 1)) }
    setNote("")
    let mounted = null, gone = false
    const bus = createBus()
    const ask = ({ napplet, what, detail }) => new Promise(resolve => setAsking({ words: askWords(what, napplet, detail), resolve }))
    ;(async () => {
      try {
        let html = await artifacts.get(manifest.hash).catch(() => null)
        if (!html) { html = await fetchAppArtifact(ctx, app.event); await artifacts.put(manifest.hash, html) }
        if (gone) return
        const r = await openNapplet({
          html, manifestEvent: app.event, container: host.current, grants,
          consent: ({ ident, domains }) => new Promise(resolve => setConsent({ ident, domains, resolve })),
          makeDeps: saveGrant => shellDeps(liveCtx, { ask, saveGrant, bus, storage }),
          onRevoke: why => { if (!gone && why !== "closed by shell") setNote(`Closed: ${why}.`) },
        })
        mounted = r.mounted
        if (gone) mounted.close()
      } catch (e) {
        if (gone) return
        const why = String(e?.message ?? e)
        // Added from the catalog and then not allowed: as on the Apps pane, an app is kept only once you said yes.
        if (/the user said no/.test(why) && !grants.get(nappletKey(manifest))) {
          await removeApp(line, { apps, grants, storage, artifacts }).catch(() => {})
          onGone?.()
          return
        }
        setNote(`Couldn't open it: ${why}`)
      }
    })()
    return () => { gone = true; mounted?.close(); release() }
  }, [wanted, manifest?.hash, me, tries])

  if (!manifest) return null
  const title = manifest.title
  const showAccess = () => {
    setMenu(false)
    const key = nappletKey(manifest)
    let domains = []
    try { domains = domainsFor(manifest) } catch {}
    setAccess({ key, grant: grants.get(key), domains })
  }
  const remove = async () => {
    setMenu(false)
    await removeApp(line, { apps, grants, storage, artifacts })
    onGone?.()
  }
  const running = wanted && note !== "full"
  return (
    <section class={open ? "sp-panel sp-app" : "sp-panel sp-app closed"} aria-label={title} style={open && !editing ? { height: `${SIZE_PX[drawn]}px` } : undefined}>
      <header class="sp-head">
        <span class="sp-icon sp-app-icon" aria-hidden="true">{title.slice(0, 1).toUpperCase()}</span>
        <h3 title={`${title} · by ${short(manifest.publisher)} · ${PUBLIC_ONLY}`}>{title}</h3>
        {!editing && (
          <span class="sp-app-more">
            <button type="button" class="sp-btn" aria-haspopup="menu" aria-expanded={menu} title={`More for ${title}`} aria-label={`More for ${title}`} onClick={() => setMenu(!menu)}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d={MORE} /></svg>
            </button>
            {menu && (
              <span class="sp-app-menu" role="menu">
                <button type="button" role="menuitem" disabled={!grants.get(nappletKey(manifest))} onClick={showAccess}>What it may do…</button>
                <button type="button" role="menuitem" class="danger" onClick={remove}>Remove {title}</button>
              </span>
            )}
          </span>
        )}
        {tools}
      </header>
      {open && !editing && (
        <div class="sp-app-body">
          {note === "full" ? <p class="sp-empty">Too many apps are open. Collapse one and this opens.</p>
            : note ? <p class="sp-empty">{note} <button type="button" class="sp-link" onClick={() => { setNote(""); setTries(t => t + 1) }}>Try again</button></p>
            : null}
          <div class={running && !note ? "napplet-host sp-app-host on" : "napplet-host sp-app-host"} ref={host} />
        </div>
      )}
      {consent && <GrantSheet title={`Open ${consent.ident.title}?`} from={short(consent.ident.publisher)} domains={consent.domains} yes="Open" onDone={g => { consent.resolve(g); setConsent(null) }} />}
      {access && <GrantSheet title={`What ${title} may do`} from={short(manifest.publisher)} domains={access.domains} grant={access.grant} yes="Save"
        onDone={g => { if (g) { saveAccessGrant(grants, access.key, access.grant, g.domains); setTries(t => t + 1) } setAccess(null) }} />}
      {asking && <AskDialog words={asking.words} onDone={yes => { asking.resolve(yes); setAsking(null) }} />}
    </section>
  )
}

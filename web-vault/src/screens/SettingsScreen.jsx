// Settings (iPhone SettingsView, the phone's single list): the relay status card first, then the groups of rows in
// the phone's order (ORDER), then About. Close goes back to Profile, where the gear opened it (the phone shows Settings as a sheet from there). A row opens its page at "#/settings/<page>"; the Accounts & backup row opens the Accounts screen
// (#/accounts).
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { StorageNote } from "../components/StorageNote.jsx"
import { BackupCard } from "../components/BackupCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { RelaysPage } from "./RelaysPage.jsx"
import { MediaServersPage } from "./MediaServersPage.jsx"
import { RecentlyDeletedPage } from "./RecentlyDeletedPage.jsx"
import { FollowingBackupPage } from "./FollowingBackupPage.jsx"
import { RecoverListPage } from "./RecoverListPage.jsx"
import { YourKeyPage } from "./YourKeyPage.jsx"
import { UnblockDialog } from "../components/Moderation.jsx"
import { useProfile } from "../components/useProfile.js"
import { fetchProfiles } from "../net/profiles.js"
import { importOwn, importLine, IMPORT_START_DATE } from "../net/sync.js"
import { ownPostRelays } from "../net/own-relays.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { learn } from "../shell.js"
import { RESET_ALL_QUESTION } from "../net/reset-all.js"
import { BOX, BoxLink } from "../box/BoxLink.jsx"
import { AppearancePage } from "./settings/AppearancePage.jsx"
import { MediaCachePage } from "./settings/MediaCachePage.jsx"
import { PrivacyPage } from "./settings/PrivacyPage.jsx"
import { FeedSettingsPage } from "./settings/FeedSettingsPage.jsx"
import { NotificationsPage } from "./settings/NotificationsPage.jsx"
import { RelayAccessPage } from "./settings/RelayAccessPage.jsx"
import { BlockSomeone } from "./settings/BlockSomeone.jsx"
import { MutedWordsPage } from "./settings/MutedWordsPage.jsx"
import { blockedSections } from "./settings/block-someone.js"
import {
  SETTINGS_GROUPS, SETTINGS_ICONS, PAGES, isPage, APP_VERSION, APP_COMMIT, commitUrl, SUPPORT_NPUB, PRIVACY_URL,
  logLines,
} from "../net/settings.js"

const ICONS = SETTINGS_ICONS
// SettingsView.swift iOSBody's sections, top to bottom. The web has no Mesh or Help rows yet.
const ORDER = ["Account", "Feed & Display", "Notifications", "Relays", "Your Vault", "Mesh", "Help", "Advanced"]
const rank = g => { const i = ORDER.indexOf(g.title); return i < 0 ? ORDER.length : i }
const GROUPS = [...SETTINGS_GROUPS].sort((a, b) => rank(a) - rank(b))
const Icon = ({ d, size = 16 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

// A key made in this browser has its own page ("#/settings/key"), outside PAGES: no other sign-in keeps a key here.
export const hasKeyPage = ctx => ctx.session.method === "local"

export function SettingsScreen({ ctx, page }) {
  if (page === "key" && hasKeyPage(ctx)) return <KeyPage ctx={ctx} />
  if (isPage(page)) return <Page ctx={ctx} page={page} />
  return <Index ctx={ctx} />
}

function Index({ ctx }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => { await navigator.clipboard.writeText(SUPPORT_NPUB); setCopied(true); setTimeout(() => setCopied(false), 1500) }
  return (
    <main class="screen settings">
      <header class="screen-head"><a class="button small" href="#/profile">Close</a><h2>Settings</h2><span style="width: 64px" /></header>
      {BOX ? <BoxLink /> : <RelayStatusCard ctx={ctx} />}
      <section class="settings-group">
        <div class="section-label">Learn</div>
        <div class="settings-rows">
          <a class="settings-row" href="/#about" onClick={e => { e.preventDefault(); learn() }}>
            <span class="settings-icon" style={{ background: "var(--accent)" }}><Icon d={ICONS.learn} /></span>
            <span class="settings-title">Learn about Nostr Vault</span>
            <Chevron />
          </a>
          {/* A new tab: leaving this page would stop the relay running in it. */}
          <a class="settings-row" href="/docs/" target="_blank" rel="noopener">
            <span class="settings-icon" style={{ background: "#0a84ff" }}><Icon d={ICONS.docs} /></span>
            <span class="settings-title">Docs</span>
            <span class="muted small">New tab</span>
            <Chevron />
          </a>
        </div>
      </section>
      {hasKeyPage(ctx) && <section class="settings-group">
        <div class="section-label">Your Key</div>
        <div class="settings-rows">
          <a class="settings-row" href="#/settings/key">
            <span class="settings-icon" style={{ background: "#ff9f0a" }}><Icon d={ICONS.secretKey} /></span>
            <span class="settings-title">Your Secret Key</span>
            <Chevron />
          </a>
        </div>
      </section>}
      {GROUPS.map(g => (
        <section key={g.title} class="settings-group">
          <div class="section-label">{g.title}</div>
          <div class="settings-rows">
            {g.rows.map(r => (
              <a key={r.id} class="settings-row" href={r.href}>
                <span class="settings-icon" style={{ background: r.color }}><Icon d={ICONS[r.icon]} /></span>
                <span class="settings-title">{r.title}</span>
                <Chevron />
              </a>
            ))}
          </div>
        </section>
      ))}
      <section class="settings-group">
        <div class="section-label">About</div>
        <div class="settings-about">
          <div class="settings-app">Nostr Vault</div>
          <div class="muted small">Version {APP_VERSION} (web){APP_COMMIT && <> · {commitUrl(APP_COMMIT) ? <a href={commitUrl(APP_COMMIT)} class="mono">{APP_COMMIT}</a> : <span class="mono">{APP_COMMIT}</span>}</>}</div>
          <hr />
          <div class="settings-support">Support &amp; Abuse Reporting</div>
          <p class="muted small">To report objectionable content or abusive users, contact the developer via Nostr</p>
          <button class="settings-npub" onClick={copy} title="Copy">{SUPPORT_NPUB}</button>
          <div class="muted" style="font-size: 10px">{copied ? "Copied" : "(Tap to copy)"}</div>
          <hr />
          <a href={PRIVACY_URL} target="_blank" rel="noopener" class="small">Privacy Policy</a>
        </div>
      </section>
    </main>
  )
}

const Chevron = () => <svg class="settings-chevron" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>

/** The phone's RelayStatusCard: whether this browser's relay is running and where it answers. */
function RelayStatusCard({ ctx }) {
  const { vault } = ctx
  const [kept, setKept] = useState(undefined)
  const [count, setCount] = useState(null)
  useEffect(() => {
    navigator.storage?.persisted?.().then(setKept).catch(() => setKept(null))
    vault.outbox.count({ authors: [ctx.session.pubkey] }).then(setCount).catch(() => {})
  }, [])
  return (
    <div class="card relay-card">
      <div class="relay-card-head">
        <span class="settings-icon big"><Icon d={ICONS.server} size={20} /></span>
        <div class="relay-card-text">
          <div class="relay-card-title">Your Vault</div>
          <div class="mono muted">in this browser · {count === null ? "…" : `${count} event${count === 1 ? "" : "s"}`}</div>
        </div>
        <span class="relay-card-state"><span class="dot on" />Running</span>
      </div>
      <StorageNote kept={kept} />
    </div>
  )
}

function KeyPage({ ctx }) {
  return (
    <main class="screen settings">
      <header class="screen-head"><a class="button small" href="#/settings">‹ Settings</a><h2>Your Secret Key</h2><span style="width: 92px" /></header>
      <YourKeyPage ctx={ctx} />
    </main>
  )
}

function Page({ ctx, page }) {
  const title = PAGES[page].title
  return (
    <main class="screen settings">
      <header class="screen-head"><a class="button small" href="#/settings">‹ Settings</a><h2>{title}</h2><span style="width: 92px" /></header>
      {page === "blocked" && <><BlockSomeone ctx={ctx} /><Blocked ctx={ctx} /></>}
      {page === "muted-words" && <MutedWordsPage ctx={ctx} />}
      {page === "feed" && <FeedSettingsPage />}
      {page === "appearance" && <AppearancePage />}
      {page === "media" && <MediaCachePage />}
      {page === "privacy" && <PrivacyPage />}
      {page === "notifications" && <NotificationsPage />}
      {page === "recently-deleted" && <RecentlyDeletedPage ctx={ctx} />}
      {page === "following-backup" && <FollowingBackupPage ctx={ctx} />}
      {page === "recover-list" && <RecoverListPage ctx={ctx} />}
      {page === "relays" && <RelaysPage ctx={ctx} />}
      {page === "media-servers" && <MediaServersPage ctx={ctx} />}
      {page === "relay-access" && <RelayAccessPage />}
      {page === "import" && <Import ctx={ctx} />}
      {page === "backup" && <BackupCard ctx={ctx} />}
      {page === "database" && <Database ctx={ctx} />}
      {page === "logs" && <Logs />}
    </main>
  )
}

/** People the user blocked (their kind 10000 mute list, the one the phone keeps), each with Unblock, in Public and
 *  Private sections as on the iPhone (BlockedSettingsView). Blocking is done above, or from a note's or a profile's
 *  ⋯ menu. */
function Blocked({ ctx }) {
  const blocks = useBlocks(ctx)
  const { privateNote } = blocks
  const { publicBlocks, privateBlocks } = blockedSections(blocks)
  const all = [...publicBlocks, ...privateBlocks]
  useEffect(() => { if (all.length) fetchProfiles(ctx.vault, all, uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])).catch(() => {}) }, [all.length])
  return (
    <>
      <p class="settings-note muted small">Your block list, the same one your phone uses. Blocked people's notes, replies and messages are hidden. Block someone above by their npub, or from the ⋯ menu on their note or profile.</p>
      <section class="settings-group">
        <div class="section-label">Public</div>
        {publicBlocks.length ? publicBlocks.map(pk => <BlockedRow key={pk} ctx={ctx} pubkey={pk} />)
          : <p class="empty blocked-empty">No public blocks.</p>}
        <p class="settings-note muted small">Anyone can see these in your block list.</p>
      </section>
      <section class="settings-group">
        <div class="section-label">Private</div>
        {privateBlocks.length ? privateBlocks.map(pk => <BlockedRow key={pk} ctx={ctx} pubkey={pk} />)
          : <p class="empty blocked-empty">{privateNote ? `Private blocks aren't shown: ${privateNote}.` : "No private blocks."}</p>}
        <p class="settings-note muted small">Only you can see these. They are encrypted in your block list.</p>
      </section>
    </>
  )
}

function BlockedRow({ ctx, pubkey }) {
  const [asking, setAsking] = useState(false)
  const p = useProfile(pubkey)
  const name = p?.display_name || p?.name || npubEncode(pubkey).slice(0, 12) + "…"
  return (
    <div class="person-row blocked-row">
      <a class="blocked-who" href={`#/profile/${pubkey}`}>
        <Avatar pubkey={pubkey} size={40} />
        <span class="person-names"><AuthorName pubkey={pubkey} /><span class="person-sub">{npubEncode(pubkey).slice(0, 20)}…</span></span>
      </a>
      <button type="button" class="small" onClick={() => setAsking(true)}>Unblock</button>
      {asking && <UnblockDialog ctx={ctx} pubkey={pubkey} name={name} onClose={() => setAsking(false)} />}
    </div>
  )
}

/**
 * Pull everything the user wrote from their relays into this browser's relay, back to a start date, with the phone's
 * progress lines (RelayLogParser: "Looking through notes from …", "Found notes from …", "Import Complete!").
 */
function Import({ ctx }) {
  const [startDate, setStartDate] = useState(IMPORT_START_DATE)
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState(0)
  const [state, setState] = useState("")
  const run = async () => {
    if (!navigator.onLine) { setState("You're offline."); return }
    setBusy(true); setProgress(0); setState("Connecting to relays...")
    try {
      const relays = ownPostRelays(ctx.account)
      const r = await importOwn(ctx.vault, ctx.session.pubkey, relays, {
        startDate,
        onProgress: p => { setProgress(p.progress); setState(`${p.empty ? "Looking through" : "Found"} notes from ${p.from}... (${p.found} found)`) },
      })
      setProgress(1)
      setState(importLine(r))
    } catch (e) { setState(`Couldn't import (${e?.message ?? e})`) }
    setBusy(false)
  }
  const pct = Math.round(progress * 100)
  return (
    <div class="card">
      <h3>Import your notes</h3>
      <p class="muted small">Fetches everything you've posted since the start date from your relays and keeps it in this browser's relay, so it's here offline and in the Vault tab.</p>
      <label class="small">Start date <input type="date" value={startDate} max={new Date().toISOString().slice(0, 10)} disabled={busy}
        onInput={e => e.currentTarget.value && setStartDate(e.currentTarget.value)} /></label>
      <p><button class="primary" disabled={busy} onClick={run}>{busy ? "Importing…" : "Import from my relays"}</button></p>
      {busy && <p class="small"><progress max="100" value={pct} aria-label="Import progress" /> {pct}%</p>}
      {state && <p class="muted small" style="margin-top: 10px">{state}</p>}
    </div>
  )
}

export const RESET_QUESTION = "Delete notes, messages, drafts and paired vaults from this browser and sign out? Your phone's vault is untouched."

/** A key made here goes with the rest: the question says so, and where to save it first. */
export const RESET_KEY_WARNING = "This account's secret key is kept only in this browser, so save it first (Settings › Your Secret Key) or you can't use this account again. The web app can't sign in with it: add it to a Nostr browser extension, or import it in the Nostr Vault app."

/** Asks first; nothing is deleted on Cancel. -> whether the wipe was started */
export function resetBrowser(ctx, ask = q => globalThis.confirm(q)) {
  if (!ask(hasKeyPage(ctx) ? `${RESET_QUESTION} ${RESET_KEY_WARNING}` : RESET_QUESTION)) return false
  ctx.signOut()
  return true
}

/** The phone's Factory Reset: every account here and this app's settings. Asks first; nothing goes on Cancel. */
export function resetAll(ctx, ask = q => globalThis.confirm(q)) {
  if (!ask(RESET_ALL_QUESTION)) return false
  ctx.signOut({ all: true })
  return true
}

/** The phone's Database & Reset: what this browser keeps, sign-out for this account, and Reset Everything. */
function Database({ ctx }) {
  const [usage, setUsage] = useState(null)
  useEffect(() => { navigator.storage?.estimate?.().then(e => setUsage((e.usage / 1048576).toFixed(1))).catch(() => {}) }, [])
  return (
    <div class="card">
      <h3>This browser's copy</h3>
      <div class="stats"><div><div class="k">storage</div><div class="v">{usage ?? "–"} MB</div></div></div>
      <p class="muted small">Your vault's data lives in this browser's storage. Signing out deletes it all: notes, messages, keys and paired vaults. Your phone's vault is untouched.</p>
      <button onClick={() => resetBrowser(ctx)}>Sign out and delete this browser's copy</button>
      <h3 class="danger-zone">Danger Zone</h3>
      <p class="muted small">Reset Everything signs every account on this browser out and deletes all of it, keys kept here included, and puts every setting back.</p>
      <button class="danger" onClick={() => resetAll(ctx)}>Reset Everything</button>
    </div>
  )
}

function Logs() {
  const lines = logLines()
  const copy = () => navigator.clipboard.writeText(lines.join("\n"))
  return (
    <div class="card">
      <div class="row" style="margin: 0 0 10px"><button class="small" onClick={copy} disabled={!lines.length}>Copy</button></div>
      {lines.length ? <pre class="settings-log">{lines.join("\n")}</pre> : <p class="muted small">Nothing logged yet.</p>}
    </div>
  )
}

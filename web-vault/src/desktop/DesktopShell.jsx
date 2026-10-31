// The web Vault at 760px and up (OUTBOX NV_WEB_VAULT_DESKTOP_DESIGN.md, picks A1 · B1 · C1): the iPad's sidebar,
// list column and note column. Feed, Search, Profile, Vault and Messages get list + note; WoT and the Dashboard take
// the full width; New Post is a dialog and replies are written under the open thread. Every screen is the phone's
// own screen component, so the two layouts can't drift apart.
import { useEffect, useRef, useState } from "preact/hooks"
import { FeedScreen } from "../screens/FeedScreen.jsx"
import { ComposeScreen } from "../screens/ComposeScreen.jsx"
import { ProfileScreen } from "../screens/ProfileScreen.jsx"
import { PersonScreen } from "../screens/PersonScreen.jsx"
import { SearchScreen } from "../screens/SearchScreen.jsx"
import { NotificationsScreen } from "../screens/NotificationsScreen.jsx"
import { ThreadScreen } from "../screens/ThreadScreen.jsx"
import { MessagesScreen } from "../screens/MessagesScreen.jsx"
import { ConversationScreen } from "../screens/ConversationScreen.jsx"
import { VaultScreen } from "../screens/VaultScreen.jsx"
import { SettingsScreen, hasKeyPage } from "../screens/SettingsScreen.jsx"
import { AccountsScreen } from "../screens/AccountsScreen.jsx"
import { WalletScreen } from "../screens/WalletScreen.jsx"
import { WotScreen } from "../screens/WotScreen.jsx"
import { isPage } from "../net/settings.js"
import { compose } from "../net/actions.js"
import { parseHash, withParam, sideOf, SPLIT, FULL } from "./routes.js"
import { keyCommand, SHEET } from "./keys.js"
import { noteById } from "./noteIndex.js"
import { Sidebar } from "./Sidebar.jsx"
import { SplitPane } from "./SplitPane.jsx"
import { PeekCard } from "./PeekCard.jsx"
import { ContextMenu } from "./ContextMenu.jsx"
import { MagicPasteIcon } from "../components/MagicPasteIcon.jsx"
import "../styles/desktop.css"

const HEX = /^[0-9a-f]{64}$/
const LABEL = { feed: "Feed", search: "Search", profile: "Profile", vault: "Vault", messages: "Messages", notifications: "Notifications", settings: "Settings", wot: "WoT", relay: "Who Can Reach You" }
const ROW = ".note, .dm-row, .person-row, .settings-row, .media-tile, .vault-thumb"
const OVERLAY = "dialog[open], .dash-sheet, .ctx-menu, .side-pop, .vault-menu-list, .more-menu, .zap-picker, #mention-picker"

function useStored(key, initial) {
  const [v, setV] = useState(() => { const s = localStorage.getItem(key); return s == null ? initial : s === "1" })
  return [v, x => { setV(x); localStorage.setItem(key, x ? "1" : "0") }]
}

/** `mode`: "single" | "rail" | "full". `hash` is the address shown; `lastList` the list screen Compose opened over. */
export function DesktopShell({ ctx, mode, hash, lastList }) {
  const me = ctx.session.pubkey
  const composing = parseHash(hash).route === "compose"
  // Compose is a dialog over the screen it was opened from, which stays as it was underneath.
  // An address that names no screen (a bare #/, right after sign-in) is the Feed, as on the phone.
  const parsed = parseHash(composing ? lastList || "#/feed" : hash)
  const view = SPLIT.has(parsed.route) || FULL.has(parsed.route) ? parsed : parseHash("#/feed")
  const [sideFolded, setSideFolded] = useStored("nv.desk.sideFolded", false)
  const [noteHidden, setNoteHidden] = useStored("nv.desk.noteHidden", false)
  const [help, setHelp] = useState(false)
  const rail = mode !== "full" || sideFolded
  const other = view.route === "profile" && HEX.test(view.arg) && view.arg !== me
  const side = sideOf(view.route, other)
  const note = HEX.test(view.params.get("note") ?? "") ? view.params.get("note") : null
  const dm = HEX.test(view.params.get("dm") ?? "") ? view.params.get("dm") : null

  // Feed and Search stay mounted once opened, so going back to them keeps the list, its results and where you were.
  const [kept, setKept] = useState({ feed: view.route === "feed", search: view.route === "search" })
  useEffect(() => { if ((view.route === "feed" || view.route === "search") && !kept[view.route]) setKept(k => ({ ...k, [view.route]: true })) }, [view.route])
  // The screen a person was opened from names the crumb back to it.
  const from = useRef("search")
  if (!other && LABEL[view.route]) from.current = view.route
  // Opening a note brings a folded note column back.
  useEffect(() => { if ((note || dm) && noteHidden) setNoteHidden(false) }, [note, dm])

  const closeDetail = () => {
    if (["settings", "accounts", "wallet"].includes(view.route)) { location.hash = "#/settings"; return }
    location.hash = withParam(withParam(composing ? lastList : hash, "note", null), "dm", null)
  }
  const cameIn = useRef(false) // Compose reached by navigating here (Back closes it), not opened cold from a link
  useEffect(() => { if (!composing) cameIn.current = true }, [composing])
  const closeCompose = () => { if (cameIn.current) history.back(); else location.replace(lastList || "#/feed") }

  useShortcuts({ ctx, composing, closeCompose, closeDetail, hasDetail: !!(note || dm), help, setHelp,
    foldSide: () => setSideFolded(!sideFolded), foldNote: () => setNoteHidden(!noteHidden) })

  const settingsish = ["settings", "accounts", "wallet"].includes(view.route)
  const listKey = other ? `person:${view.arg}` : settingsish ? "settings" : view.route
  const list = (
    <>
      {kept.feed && <div class="desk-pane" hidden={listKey !== "feed"}><FeedScreen ctx={ctx} /></div>}
      {kept.search && <div class="desk-pane" hidden={listKey !== "search"}><SearchScreen ctx={ctx} onProfile={pk => { location.hash = `#/profile/${pk}` }} /></div>}
      {listKey !== "feed" && listKey !== "search" && (
        <div class="desk-pane" key={listKey}>
          {other && <div class="desk-crumb"><button type="button" class="small" onClick={() => history.back()}>‹ {LABEL[from.current] ?? "Back"}</button></div>}
          {other ? <PersonScreen key={view.arg} ctx={ctx} pubkey={view.arg} />
            : view.route === "profile" ? <ProfileScreen ctx={ctx} />
            : view.route === "vault" ? <VaultScreen ctx={ctx} desk />
            : view.route === "messages" ? <MessagesScreen ctx={ctx} />
            : view.route === "notifications" ? <NotificationsScreen ctx={ctx} />
            : settingsish ? <SettingsScreen ctx={ctx} />
            : null}
        </div>
      )}
    </>
  )

  let detail = null, placeholder = "Pick a note to read it here."
  if (view.route === "messages") {
    placeholder = "Pick a conversation."
    if (dm) detail = <div class="desk-pane"><ConversationScreen key={dm} ctx={ctx} peer={dm} /></div>
  } else if (settingsish) {
    placeholder = "Pick a setting."
    if (view.route === "settings" && (isPage(view.arg) || (view.arg === "key" && hasKeyPage(ctx)))) detail = <div class="desk-pane"><SettingsScreen key={view.arg} ctx={ctx} page={view.arg} /></div>
    if (view.route === "accounts") detail = <div class="desk-pane"><AccountsScreen ctx={ctx} /></div>
    if (view.route === "wallet") detail = <div class="desk-pane"><WalletScreen /></div>
  } else if (note) {
    detail = <ThreadPane key={note} ctx={ctx} id={note} onClose={closeDetail} />
  }

  const full = view.route === "wot" || view.route === "relay"
  return (
    <div class={`desk ${mode}${rail ? " rail" : ""}`}>
      <Sidebar ctx={ctx} side={side} rail={rail} />
      <section class="desk-main">
        {view.route === "wot" ? <div class="desk-full"><WotScreen ctx={ctx} pubkey={/^[0-9a-f]{64}$/.test(view.arg) ? view.arg : undefined} /></div>
          : full ? null /* the Dashboard: main.jsx keeps the relay screen mounted and lays it over this area */
          : <SplitPane single={mode === "single"} list={list} detail={detail} placeholder={placeholder}
              noteHidden={noteHidden} setNoteHidden={setNoteHidden} onBack={closeDetail} />}
        <Current note={note} dm={dm} page={settingsish ? (view.route === "settings" ? `settings/${view.arg}` : view.route) : null} />
      </section>
      {composing && <ComposeDialog ctx={ctx} onClose={closeCompose} />}
      {help && <ShortcutSheet onClose={() => setHelp(false)} />}
      <PeekCard ctx={ctx} />
      <ContextMenu ctx={ctx} />
    </div>
  )
}

/** Marks the list row whose note, conversation or setting is open, by attribute, so rows that load later are marked too. */
function Current({ note, dm, page }) {
  const rules = []
  if (note) rules.push(`.desk-list [data-note-id="${note}"]`)
  if (dm) rules.push(`.desk-list a.dm-row[href="#/dm/${dm}"]`)
  if (page && /^[a-z/-]+$/.test(page)) rules.push(`.desk-list a.settings-row[href="#/${page}"]`)
  if (!rules.length) return null
  return <style>{`${rules.join(", ")} { background: var(--s2); border-color: var(--accent); box-shadow: inset 3px 0 0 var(--accent); }`}</style>
}

/** The open note's thread, and the reply box under it (design §4: the thread stays on screen while you type). */
function ThreadPane({ ctx, id, onClose }) {
  return (
    <div class="desk-pane desk-thread">
      <header class="desk-detail-head">
        <b>Thread</b>
        <button type="button" class="desk-x" aria-label="Close the note (Esc)" title="Close (Esc)" onClick={onClose}>
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </header>
      <ThreadScreen ctx={ctx} id={id} />
      {!ctx.signer?.readOnly && <div class="desk-reply"><ComposeScreen ctx={ctx} fixed={{ mode: "reply", id }} inline /></div>}
    </div>
  )
}

/** New Post, Quote and the card's Reply button: a 600px dialog over the dimmed page. The draft outlives closing it. */
function ComposeDialog({ ctx, onClose }) {
  const box = useRef()
  useEffect(() => {
    const back = document.activeElement
    requestAnimationFrame(() => box.current?.querySelector("textarea")?.focus())
    return () => back?.focus?.()
  }, [])
  return (
    <div class="desk-compose-back" onPointerDown={e => { if (e.target === e.currentTarget) onClose() }}>
      <div class="desk-compose" role="dialog" aria-modal="true" aria-label="New Post" ref={box}>
        <button type="button" class="desk-x" aria-label="Close (Esc)" title="Close (Esc)" onClick={onClose}>
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
        <ComposeScreen ctx={ctx} />
        <p class="muted small desk-compose-hint"><MagicPasteIcon size={14} style={{ verticalAlign: "-2px", marginRight: 4 }} />Drop or paste images · ⌘/Ctrl Enter posts</p>
      </div>
    </div>
  )
}

function ShortcutSheet({ onClose }) {
  const ref = useRef()
  useEffect(() => { ref.current?.showModal?.() }, [])
  return (
    <dialog ref={ref} class="mod-dialog desk-keys" aria-label="Keyboard shortcuts" onClose={onClose} onCancel={e => { e.preventDefault(); onClose() }}
      onClick={e => { if (e.target === ref.current) onClose() }}>
      <div class="mod-body">
        <h3>Keyboard shortcuts</h3>
        <p class="muted small">Single keys, off while you type in a field.</p>
        <dl>
          {SHEET.map(([k, what]) => (
            <div key={k} class="desk-keys-row">
              <dt>{k.split(" ").map((p, i) => (p === "/" || p === "·") && k !== "/" ? <span key={i} class="muted"> {p} </span> : <kbd key={i}>{p}</kbd>)}</dt>
              <dd>{what}</dd>
            </div>
          ))}
        </dl>
        <div class="mod-row"><button type="button" onClick={onClose}>Done</button></div>
      </div>
    </dialog>
  )
}

const typingIn = el => !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))

/** The visible list column's rows, outermost only (a quoted note inside a card isn't a row of its own). */
function listRows() {
  const pane = document.querySelector(".desk-list:not([hidden]) .desk-pane:not([hidden])")
  return pane ? [...pane.querySelectorAll(ROW)].filter(r => !r.parentElement.closest(".note") && r.getClientRects().length) : []
}

function useShortcuts(o) {
  const ref = useRef(o)
  ref.current = o
  useEffect(() => {
    let pending = null, timer
    const selected = () => { const r = document.querySelector(".kbd-on"); return r?.isConnected && listRows().includes(r) ? r : null }
    const select = r => {
      document.querySelector(".kbd-on")?.classList.remove("kbd-on")
      r.classList.add("kbd-on")
      if (r.tabIndex < 0 && !/^(A|BUTTON)$/.test(r.tagName)) r.tabIndex = -1
      r.focus({ preventScroll: true })
      r.scrollIntoView({ block: "nearest" })
    }
    // The card a like or zap goes to: the selected row, or else the note opened in the note column.
    // Two lookups, not one selector list: a list matches in tree order, and the thread draws its root first, so an
    // open reply would hand a like or zap to the root's author.
    const card = () => selected()?.closest("[data-note-id]")
      ?? document.querySelector(".desk-thread [aria-current] [data-note-id]") ?? document.querySelector(".desk-thread [data-note-id]")
    const openRow = r => { if (r.matches("[data-note-id]") || r.tagName === "A") r.click() }
    const run = (c, e) => {
      const s = ref.current
      if (document.querySelector("dialog[open]")) return false // a block, report or shortcuts dialog has the keys
      // A menu, zap amount picker or mention list is open: it owns the keys (Escape closes it itself). A stray z
      // over the zap picker would otherwise pay the default amount.
      if (document.querySelector(OVERLAY)) return false
      switch (c.cmd) {
        case "close":
          if (s.composing) return s.closeCompose()
          if (typingIn(document.activeElement)) return document.activeElement.blur()
          if (s.hasDetail) return s.closeDetail()
          return false
        case "send": {
          const el = document.activeElement, form = el.closest("form")
          if (form) return form.requestSubmit()
          const btn = el.closest(".screen")?.querySelector("button.primary:not(:disabled)")
          return btn ? btn.click() : false
        }
      }
      if (s.composing) return false
      switch (c.cmd) {
        case "next": case "prev": {
          const rows = listRows()
          if (!rows.length) return false
          const i = rows.indexOf(selected())
          const r = rows[i < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, i + (c.cmd === "next" ? 1 : -1)))]
          select(r)
          // With a note open, moving along the list reads the next one, as Mail does.
          if (s.hasDetail && r.matches("[data-note-id]")) r.click()
          return
        }
        case "open": {
          const r = selected()
          if (!r || (document.activeElement !== r && document.activeElement !== document.body)) return false
          return openRow(r)
        }
        case "search": {
          location.hash = "#/search"
          // The Search pane mounts on its first visit, so the field may take a few frames to exist.
          let tries = 0
          const focus = () => { const el = document.querySelector(".desk-pane:not([hidden]) .search-form input"); if (el) el.focus(); else if (++tries < 30) requestAnimationFrame(focus) }
          return requestAnimationFrame(focus)
        }
        case "go": location.hash = `#/${c.arg}`; return
        case "compose": if (s.ctx.signer?.readOnly) return false; location.hash = "#/compose"; return
        case "reply": {
          const box = document.querySelector(".desk-reply textarea")
          if (box && !selected()) return box.focus()
          const n = noteById(selected()?.closest("[data-note-id]")?.dataset.noteId)
          if (n && !s.ctx.signer?.readOnly) return compose("reply", n)
          return box ? box.focus() : false
        }
        case "like": { const b = card()?.querySelector(".note-action.like"); return b ? b.click() : false }
        case "zap": { const b = card()?.querySelector(".zap-button"); return b ? b.click() : false }
        case "foldSide": return s.foldSide()
        case "foldNote": return s.foldNote()
        case "help": return s.setHelp(true)
      }
      return false
    }
    const onKey = e => {
      if (e.defaultPrevented || e.isComposing) return
      const c = keyCommand({ key: e.key, metaKey: e.metaKey, ctrlKey: e.ctrlKey, altKey: e.altKey, typing: typingIn(document.activeElement), pending })
      pending = null; clearTimeout(timer)
      if (!c) return
      if (c.pending) { pending = c.pending; timer = setTimeout(() => { pending = null }, 1200); return }
      if (run(c, e) !== false) e.preventDefault()
    }
    addEventListener("keydown", onKey)
    return () => { removeEventListener("keydown", onKey); clearTimeout(timer) }
  }, [])
}

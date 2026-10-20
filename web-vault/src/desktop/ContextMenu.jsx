// Right-click menus (design §3). On a note: Open in new tab · Copy link · Copy note ID · Copy text · Quote · Report ·
// Block author. On a person: Open profile · Message · Copy npub · Follow/Unfollow · Block. Over a plain link, media,
// a text field or selected text, or with Shift held, the browser's own menu shows instead.
import { useEffect, useRef, useState } from "preact/hooks"
import { neventEncode, npubEncode } from "nostr-tools/nip19"
import { BlockDialog, ReportDialog } from "../components/Moderation.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { getProfile } from "../net/profiles.js"
import { compose } from "../net/actions.js"
import { setFollow } from "../net/follows.js"
import { noteById } from "./noteIndex.js"

const HEX = /^[0-9a-f]{64}$/
const nameOf = pk => getProfile(pk)?.display_name || getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
export const threadLink = id => `${location.origin}${location.pathname}#/thread/${id}`

/** What a right-click at `target` is on: { note } | { pubkey } | null (leave it to the browser). */
export function menuTarget(target, { shiftKey = false, selection = "" } = {}) {
  if (shiftKey || selection || !target?.closest?.(".desk-main")) return null
  if (target.closest("input, textarea, select, [contenteditable], img, video, audio")) return null
  const person = target.closest('a[href^="#/profile/"]')
  if (person) {
    const pk = person.getAttribute("href").slice("#/profile/".length)
    return HEX.test(pk) ? { pubkey: pk } : null
  }
  if (target.closest("a[href]")) return null
  const id = target.closest("[data-note-id]")?.dataset.noteId
  const note = id && noteById(id)
  return note ? { note } : null
}

export function ContextMenu({ ctx }) {
  const [menu, setMenu] = useState(null) // { x, y, note?, pubkey? }
  const [dialog, setDialog] = useState(null) // { kind, pubkey, note? }
  const [toast, setToast] = useState("")
  const box = useRef()
  const { blocked } = useBlocks(ctx)

  useEffect(() => {
    const open = e => {
      const t = menuTarget(e.target, { shiftKey: e.shiftKey, selection: String(getSelection?.() ?? "") })
      if (!t) return
      e.preventDefault()
      setMenu({ x: e.clientX, y: e.clientY, ...t })
    }
    document.addEventListener("contextmenu", open)
    return () => document.removeEventListener("contextmenu", open)
  }, [])
  useEffect(() => {
    if (!menu) return
    const items = () => [...(box.current?.querySelectorAll("[role=menuitem]:not([disabled])") ?? [])]
    items()[0]?.focus()
    // Kept on screen: flipped left or up when it would run off the edge.
    const r = box.current.getBoundingClientRect()
    if (r.right > innerWidth - 8) box.current.style.left = `${Math.max(8, menu.x - r.width)}px`
    if (r.bottom > innerHeight - 8) box.current.style.top = `${Math.max(8, menu.y - r.height)}px`
    const close = () => setMenu(null)
    const away = e => { if (!box.current?.contains(e.target)) close() }
    const key = e => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); return }
      if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return
      e.preventDefault()
      const list = items(), i = list.indexOf(document.activeElement)
      list[(i + (e.key === "ArrowDown" ? 1 : -1) + list.length) % list.length]?.focus()
    }
    addEventListener("pointerdown", away, true); addEventListener("keydown", key, true)
    addEventListener("scroll", close, true); addEventListener("resize", close); addEventListener("blur", close)
    return () => {
      removeEventListener("pointerdown", away, true); removeEventListener("keydown", key, true)
      removeEventListener("scroll", close, true); removeEventListener("resize", close); removeEventListener("blur", close)
    }
  }, [menu])

  const say = text => { setToast(text); setTimeout(() => setToast(t => (t === text ? "" : t)), 1600) }
  const copy = (text, done) => async () => {
    setMenu(null)
    try { await navigator.clipboard.writeText(text); say(done) } catch { say("Couldn't copy: the browser said no") }
  }
  const run = f => () => { setMenu(null); f() }

  const me = ctx.session.pubkey, readOnly = ctx.signer?.readOnly
  let items = null
  if (menu?.note) {
    const n = menu.note
    items = [
      ["Open in new tab", run(() => open(`#/thread/${n.id}`, "_blank", "noopener"))],
      ["Copy link", copy(threadLink(n.id), "Link copied")],
      ["Copy note ID", copy(neventEncode({ id: n.id, author: n.pubkey, kind: n.kind }), "Note ID copied")],
      ["Copy text", copy(n.content ?? "", "Text copied")],
      "-",
      !readOnly && ["Quote", run(() => compose("quote", n))],
      !readOnly && n.pubkey !== me && ["Report…", run(() => setDialog({ kind: "report", pubkey: n.pubkey, note: n })), "danger"],
      !readOnly && n.pubkey !== me && !blocked.has(n.pubkey) && ["Block author…", run(() => setDialog({ kind: "block", pubkey: n.pubkey })), "danger"],
    ]
  } else if (menu?.pubkey) {
    const pk = menu.pubkey, iFollow = ctx.account.follows.includes(pk)
    items = [
      ["Open profile", run(() => { location.hash = `#/profile/${pk}` })],
      pk !== me && ["Message", run(() => { location.hash = `#/dm/${pk}` })],
      ["Copy npub", copy(npubEncode(pk), "npub copied")],
      !readOnly && pk !== me && "-",
      !readOnly && pk !== me && ctx.account.loaded && [iFollow ? "Unfollow" : "Follow", run(() => follow(ctx, pk, !iFollow, say))],
      !readOnly && pk !== me && !blocked.has(pk) && ["Block…", run(() => setDialog({ kind: "block", pubkey: pk })), "danger"],
    ]
  }
  const shown = items?.filter(Boolean).filter((x, i, a) => x !== "-" || (i > 0 && i < a.length - 1 && a[i - 1] !== "-"))

  return <>
    {menu && (
      <div class="ctx-menu" role="menu" ref={box} style={{ left: `${menu.x}px`, top: `${menu.y}px` }} onContextMenu={e => e.preventDefault()}>
        {shown.map((x, i) => x === "-" ? <hr key={i} /> : <button key={x[0]} type="button" role="menuitem" class={x[2] ?? ""} onClick={x[1]}>{x[0]}</button>)}
      </div>
    )}
    {dialog?.kind === "block" && <BlockDialog ctx={ctx} pubkey={dialog.pubkey} name={nameOf(dialog.pubkey)} onClose={() => setDialog(null)} />}
    {dialog?.kind === "report" && <ReportDialog ctx={ctx} note={dialog.note} pubkey={dialog.pubkey} name={nameOf(dialog.pubkey)} onClose={() => setDialog(null)} />}
    {toast && <div class="desk-toast" role="status">{toast}</div>}
  </>
}

async function follow(ctx, pk, on, say) {
  const { vault, account, session, signer } = ctx
  say(on ? "Following…" : "Unfollowing…")
  try {
    await setFollow({ vault, signer, pubkey: session.pubkey, target: pk, follow: on,
      readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
    await ctx.reloadAccount()
    say(on ? `Following ${nameOf(pk)}` : `Unfollowed ${nameOf(pk)}`)
  } catch (e) { say(String(e?.message ?? e)) }
}

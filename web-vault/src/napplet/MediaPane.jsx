// Vault › Media as the Media napplet (plan P5), when the napplet switch is on (flag.js): your media servers' files,
// listed, copied and deleted through NAP-BLOSSOM (blossom-dispatch.js: the shell signs every Blossom auth) with
// pictures and video as bytes from the shell. The shell asks before any delete, ours too; that sheet is here.
// `filter`: the Vault's Media pill (all, photos, videos, gifs), handed to the napplet by intent (napplet:media/open).
// Switch off, or the "In your notes" pill: the classic page (BlossomGallery.jsx, VaultScreen.jsx).
// Gap run: the shell answers "Posted in N notes" (napplet:media/postedIn -> media/notes, net/media-notes.js, read from
// your vault only) and runs the classic page's live file notes (watchFileNotes -> media/tiles); a note row opens the
// thread (napplet:note/open).
import { useEffect, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { vaultNotesUsing, notePreview } from "../net/media-notes.js"
import { watchFileNotes } from "../net/file-notes-live.js"
import { sealMeshAuth } from "../net/pair-hello.js"
import { fetchProfiles, getProfile } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { MEDIA_DTAG } from "./first-party.js"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { askWords, oneAskAtATime } from "./consent-words.js"
import "./napplet.css"

const HEX = /^[0-9a-f]{64}$/
export const MAX_POSTED = 50

/** media-notes.js notes -> what the napplet draws: id, author, when, a preview line (no tags, no signature). */
export const postedRows = (notes, profile = getProfile) => notes.slice(0, MAX_POSTED).map(ev => {
  const p = profile(ev.pubkey)
  return { id: ev.id, pubkey: ev.pubkey, createdAt: ev.created_at, name: String(p?.display_name || p?.name || "").slice(0, 80), preview: notePreview(ev.content).slice(0, 160) }
})
/** file-notes-live.js tiles -> the napplet's rows (its withNoteTiles merges them as the classic mergeNoteTiles). */
export const tileRows = tiles => tiles.filter(t => t?.urls?.length).map(t => ({ sha256: t.sha256, url: t.urls[0], type: t.mime, size: t.size, uploaded: t.createdAt, ...(t.dim ? { dim: t.dim } : {}) }))

export function MediaPane({ ctx, filter = "all" }) {
  const host = useRef(null)
  const ctxRef = useRef(ctx)
  ctxRef.current = ctx
  const tilesNow = useRef(null) // the latest live tiles, handed over when the napplet is up
  const [asking, setAsking] = useState(null) // { words, resolve }
  const [oneAsk] = useState(() => oneAskAtATime(setAsking))
  const filterRef = useRef(filter)
  filterRef.current = filter
  const { live, note } = usePaneNapplet(ctx, host, {
    dTag: MEDIA_DTAG, actions: { media: ["open", "notes", "tiles"] },
    ask: ({ napplet, what, detail }) => oneAsk(askWords(what, napplet, detail)),
    handlers: [
      { id: "shell-media-posted", title: "Posted in", archetype: "media", actions: ["postedIn"], conventions: [], deliver: p => {
        if (!HEX.test(p?.sha256 ?? "") || typeof p.url !== "string" || !/^https?:\/\//i.test(p.url)) return { ok: false, error: "invalid request" }
        const blob = { sha256: p.sha256, url: p.url.slice(0, 2048) }
        const send = notes => live.current?.invoke({ archetype: "media", action: "notes", payload: { sha256: blob.sha256, notes: postedRows(notes) } })
        vaultNotesUsing(ctxRef.current.vault, blob).then(notes => {
          send(notes)
          // Names that aren't here yet: fetched once, then the list again with them.
          const missing = uniq(notes.slice(0, MAX_POSTED).map(n => n.pubkey)).filter(pk => !getProfile(pk)?.name)
          if (missing.length) fetchProfiles(ctxRef.current.vault, missing, uniq([...ctxRef.current.account.relays.read, ...DEFAULT_RELAYS])).then(() => send(notes)).catch(() => {})
        }, () => send([]))
        return { ok: true }
      } },
      { id: "shell-note-open", title: "Note", archetype: "note", actions: ["open"], conventions: [], deliver: p => {
        if (!HEX.test(p?.id ?? "")) return { ok: false, error: "not a note id" }
        location.hash = `#/thread/${p.id}`
        return { ok: true }
      } },
    ],
    onReady: l => {
      if (filterRef.current !== "all") l.invoke({ archetype: "media", action: "open", payload: { filter: filterRef.current } })
      if (tilesNow.current) l.invoke({ archetype: "media", action: "tiles", payload: tilesNow.current })
    },
  })

  // Live file notes on this browser vault's /files, as the classic page watches them (the in-page vault only).
  const vault = ctx.vault, me = ctx.session.pubkey
  useEffect(() => {
    tilesNow.current = null
    if (!vault?.owners) return
    const onChange = (tiles, state) => {
      tilesNow.current = { tiles: tileRows(tiles), emojiOnly: [...(state?.emojiOnly() ?? [])] }
      live.current?.invoke({ archetype: "media", action: "tiles", payload: tilesNow.current })
    }
    return watchFileNotes({ haven: vault.haven, owner: me, auth: challenge => sealMeshAuth({ challenge }), onChange })
  }, [me, vault])

  const sent = useRef(filter)
  useEffect(() => {
    if (filter === sent.current) return
    sent.current = filter
    const l = live.current
    if (l) l.invoke({ archetype: "media", action: "open", payload: { filter } })
  }, [filter])

  const answer = yes => { asking?.resolve(yes); setAsking(null) }
  return (
    <div class="media-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host media-host" ref={host} />
      {asking && (
        <Dialog label={asking.words.title} onClose={() => answer(false)}>
          <h3>{asking.words.title}</h3>
          {asking.words.body && <p class="napplet-preview">{asking.words.body}</p>}
          <div class="mod-row">
            <button type="button" class="napplet-danger" onClick={() => answer(true)}>{asking.words.yes}</button>
            <button type="button" onClick={() => answer(false)}>{asking.words.no}</button>
          </div>
        </Dialog>
      )}
    </div>
  )
}

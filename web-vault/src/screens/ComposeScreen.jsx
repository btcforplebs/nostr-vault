// Post a note: signed by the user's signer, stored in the in-page Haven first, then sent to the relays
// publishRelays picks (write list + the iPhone app's broadcast set). "#/compose?reply=<id>" and "?quote=<id>"
// (a note card's Reply and Quote) post a reply with NIP-10 tags, or a quote with a q tag and the nevent.
// As on the iPhone: photos and videos (picked, dropped or pasted) go up to the account's media servers as they're added
// and into the note as links with imeta tags, each with its own ALT description; "@" suggests people and tags them;
// what isn't posted yet is kept as a draft.
import { useCallback, useEffect, useRef, useState } from "preact/hooks"
import { publishNote } from "../net/sync.js"
import { composeTarget, findNote, quoteOf, replyTags } from "../net/actions.js"
import { MAX_PHOTOS, imetaTag, mediaServers, uploadPhoto } from "../net/upload.js"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { MentionPicker, mentionAt, mentionedPubkeys, toNostr, uniqueToken } from "../components/MentionPicker.jsx"
import { getProfile } from "../net/profiles.js"
import { hashtagTags } from "../net/hashtags.js"
import { Dialog } from "../components/Moderation.jsx"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/compose.css")

const host = url => url.replace(/^wss?:\/\//, "")

// The count reached first, then what failed. This machine's own relay is reported apart, and quietly:
// it being off doesn't mean the note didn't go out.
function PostResult({ result }) {
  const network = result.relays.filter(r => !r.local)
  const reached = network.filter(r => r.ok)
  const failed = network.filter(r => !r.ok)
  return (
    <div class="result" role="status">
      <strong class={reached.length ? "" : "error"}>
        {reached.length ? `✓ Sent to ${reached.length} of ${network.length} relays` : `✗ No relay took it (0 of ${network.length})`}
      </strong>
      {reached.length > 0 && <div class="muted small">{reached.map(r => host(r.url)).join(" · ")}</div>}
      {failed.map(r => <div key={r.url} class="error small">✗ {host(r.url)}: {r.message}</div>)}
      <div class="muted small">✓ Saved to your relay in this browser</div>
      {result.relays.filter(r => r.local).map(r => (
        <div key={r.url} class="muted small">{r.ok ? "✓ Also on this Mac's vault relay" : `This Mac's vault relay (${host(r.url)}) didn't answer. That doesn't change the relays above.`}</div>
      ))}
      <a href="#/profile">See it on your profile</a>
    </div>
  )
}

// The note being replied to or quoted, under a label saying which.
function ComposeTarget({ mode, note }) {
  return (
    <div class="compose-target">
      <div class="compose-label">{mode === "reply" ? "Replying to" : "Quoting"} <AuthorName pubkey={note.pubkey} /></div>
      <NoteText content={note.content} />
    </div>
  )
}

// Drafts: one per account and per target (a new note, or a reply or quote to one note), in an IndexedDB database named
// like Haven's own, "haven:<pubkey>:drafts", so sign-out's wipe (vault.js storeNames) deletes it with the rest.
// Each write is its own short connection, and one asked to close for a delete closes, so it never blocks sign-out.
export const draftKey = target => (target ? `${target.mode}:${target.id}` : "new")

export function idbDrafts(pubkey, idb = globalThis.indexedDB) {
  const run = (mode, op) => new Promise((resolve, reject) => {
    const req = idb.open(`haven:${pubkey}:drafts`, 1)
    req.onupgradeneeded = () => req.result.createObjectStore("drafts")
    req.onerror = () => reject(req.error)
    req.onsuccess = () => {
      const db = req.result
      db.onversionchange = () => db.close()
      const tx = db.transaction("drafts", mode)
      const r = op(tx.objectStore("drafts"))
      tx.oncomplete = () => { db.close(); resolve(r?.result) }
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error) }
    }
  })
  return {
    get: key => run("readonly", s => s.get(key)),
    put: (key, value) => run("readwrite", s => s.put(value, key)),
    delete: key => run("readwrite", s => s.delete(key)),
  }
}

/** What a draft keeps: the text as shown (with @Name tokens), whose each token is, and the media already uploaded. */
export const draftOf = (text, mentions, photos) => ({
  text, mentions: Object.fromEntries(Object.entries(mentions).filter(([t]) => text.includes(t))),
  photos: photos.filter(p => p.url).map(({ url, sha256, mime, size, width, height, alt }) => ({ url, sha256, mime, size, width, height, ...(alt?.trim() ? { alt } : {}) })),
})

/** What the picker, a drop or a paste may attach: photos and videos (ComposeView+Attachments), nothing else. */
export const isMedia = f => /^(image|video)\//.test(f?.type ?? "")
export const isVideo = m => /^video\//.test(m?.mime ?? m?.type ?? m?.file?.type ?? "")
const emptyDraft = d => !d.text.trim() && !d.photos.length

/** Content and tags for a post: tokens -> nostr:npub, photo links appended (as the iPhone does), then the reply or
 *  quote's tags, a p tag per mention still in the text, one imeta per photo. */
export function buildPost({ text, mentions, photos, target, parent }) {
  const urls = photos.map(p => p.url)
  const body = [toNostr(text.trim(), mentions), ...urls].filter(Boolean).join("\n")
  const base = !parent ? { content: body, tags: [] } : target.mode === "reply" ? { content: body, tags: replyTags(parent) } : quoteOf(parent, body)
  const tags = [...base.tags]
  for (const pk of mentionedPubkeys(text, mentions)) if (!tags.some(t => t[0] === "p" && t[1] === pk)) tags.push(["p", pk])
  for (const p of photos) { const t = imetaTag(p); if (t) tags.push(t) }
  // NIP-24 t tags for the typed #hashtags (ComposeView+Posting), so hashtag feeds find the note.
  for (const t of hashtagTags(text)) if (!tags.some(x => x[0] === "t" && x[1] === t[1])) tags.push(t)
  return { content: base.content, tags }
}

// Pixel size, so readers can reserve the box before the photo or video loads.
async function pixelSize(file) {
  if (/^video\//.test(file.type)) return videoSize(file)
  try { const b = await createImageBitmap(file); const s = { width: b.width, height: b.height }; b.close?.(); return s } catch { return {} }
}

// A video's size from its metadata. A file the browser can't read (or that never answers) just goes without one.
function videoSize(file) {
  return new Promise(resolve => {
    const v = document.createElement("video"), url = URL.createObjectURL(file)
    const done = s => { clearTimeout(timer); v.removeAttribute("src"); v.load(); URL.revokeObjectURL(url); resolve(s) }
    const timer = setTimeout(() => done({}), 5000)
    v.preload = "metadata"; v.muted = true
    v.onloadedmetadata = () => done(v.videoWidth > 0 && v.videoHeight > 0 ? { width: v.videoWidth, height: v.videoHeight } : {})
    v.onerror = () => done({})
    v.src = url
  })
}

let nextPhoto = 0

/** `fixed`: the reply or quote to write, instead of the one in the address (the desktop's inline reply under a thread).
 *  `inline`: drawn small, with no title and no copy of the note above it, since the thread is right there. */
export function ComposeScreen({ ctx, fixed = null, inline = false }) {
  const [text, setText] = useState("")
  const [mentions, setMentions] = useState({}) // { "@Name": pubkey }
  const [photos, setPhotos] = useState([]) // photos and videos: { id, preview, status: "uploading" | "done" | "failed", error?, file?, url?, alt?, ... }
  const [altFor, setAltFor] = useState(null) // the id whose ALT is being written
  const [mention, setMention] = useState(null) // the "@query" at the caret
  const [dragging, setDragging] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  // Read on every render: going from a reply to the Post button keeps this screen mounted and only changes the hash.
  const target = fixed ?? composeTarget()
  const [note, setNote] = useState(null) // { id, event } once looked up; event null when not found

  useEffect(() => {
    setNote(null); setResult(null); setErr("")
    if (!target) return
    let live = true
    findNote(ctx, target.id).catch(() => null).then(event => { if (live) setNote({ id: target.id, event }) })
    return () => { live = false }
  }, [target?.mode, target?.id])

  const parent = target && note?.id === target.id ? note.event : null
  const waiting = target && note?.id !== target.id

  // The draft for this target: loaded when the target changes, saved on every change after that.
  const drafts = useRef(null)
  drafts.current ??= idbDrafts(ctx.session.pubkey)
  const key = draftKey(target)
  const [loaded, setLoaded] = useState(null) // the key whose draft is in the box
  useEffect(() => {
    let live = true
    setLoaded(null); setText(""); setMentions({}); setPhotos([]); setMention(null)
    drafts.current.get(key).catch(() => null).then(d => {
      if (!live) return
      if (d) { setText(d.text ?? ""); setMentions(d.mentions ?? {}); setPhotos((d.photos ?? []).map(p => ({ ...p, id: ++nextPhoto, status: "done", preview: p.url }))) }
      setLoaded(key)
    })
    return () => { live = false }
  }, [key])
  const saving = useRef(Promise.resolve())
  useEffect(() => {
    if (loaded !== key) return
    const d = draftOf(text, mentions, photos)
    // One write after another, so an older one can't land last.
    saving.current = saving.current.then(() => (emptyDraft(d) ? drafts.current.delete(key) : drafts.current.put(key, d))).catch(() => {})
  }, [text, mentions, photos, loaded])

  // Photos: hashed, signed and uploaded one at a time (one signer prompt after another), as they're added.
  const servers = useRef(null)
  const queue = useRef(Promise.resolve())
  const update = (id, patch) => setPhotos(ps => ps.map(p => (p.id === id ? { ...p, ...patch } : p)))
  const upload = (id, file) => {
    update(id, { status: "uploading", error: "" })
    queue.current = queue.current.then(async () => {
      try {
        servers.current ??= await mediaServers(ctx)
        const [size, up] = await Promise.all([pixelSize(file), uploadPhoto(file, { ctx, servers: servers.current })])
        update(id, { ...size, ...up, status: "done", file: null })
      } catch (e) { update(id, { status: "failed", error: String(e?.message ?? e) }) }
    })
  }
  const addFiles = files => {
    const media = [...files].filter(isMedia)
    if (!media.length) return
    setErr("")
    setPhotos(ps => {
      const room = MAX_PHOTOS - ps.length
      if (media.length > room) setErr(`A note can carry ${MAX_PHOTOS} attachments.`)
      const added = media.slice(0, Math.max(0, room)).map(file => ({ id: ++nextPhoto, file, preview: URL.createObjectURL(file), status: "queued" }))
      queueMicrotask(() => added.forEach(p => upload(p.id, p.file)))
      return [...ps, ...added]
    })
  }
  const removePhoto = id => setPhotos(ps => ps.filter(p => { if (p.id === id && p.preview.startsWith("blob:")) URL.revokeObjectURL(p.preview); return p.id !== id }))
  const picker = useRef(null)

  // Mentions: the "@query" at the caret opens the picker; picking swaps it for the person's "@Name" token.
  const box = useRef(null)
  const track = el => setMention(mentionAt(el.value, el.selectionStart))
  const pick = useCallback(pk => {
    const el = box.current, at = mentionAt(el.value, el.selectionStart)
    if (!at) return setMention(null)
    const token = uniqueToken(getProfile(pk)?.name, pk, mentions)
    const next = el.value.slice(0, at.start) + token + " " + el.value.slice(at.end)
    const caret = at.start + token.length + 1
    setText(next); setMentions(m => ({ ...m, [token]: pk })); setMention(null)
    requestAnimationFrame(() => { el.focus(); el.setSelectionRange(caret, caret) })
  }, [mentions])
  const closePicker = useCallback(() => setMention(null), [])

  const uploading = photos.some(p => p.status !== "done" && p.status !== "failed")
  const ready = photos.filter(p => p.status === "done")
  const canPost = !busy && !uploading && (text.trim() || ready.length) && (!target || parent)

  const post = async () => {
    setBusy(true); setErr(""); setResult(null)
    try {
      const { content, tags } = buildPost({ text, mentions, photos: ready, target, parent })
      setResult(await publishNote(ctx.vault, ctx.signer, ctx.session.pubkey, content, ctx.account.relays.write, tags))
      setText(""); setMentions({}); setPhotos([]); setMention(null)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  const title = !target ? "New note" : target.mode === "reply" ? "Reply" : "Quote"
  return (
    <main class={inline ? "screen compose-inline" : "screen"}>
      {!inline && <header class="screen-head"><h2>{title}</h2></header>}
      {waiting && !inline && <p class="status-line">Finding the note…</p>}
      {target && note?.id === target.id && !parent && <p class="error status-line">That note couldn't be found, so there's nothing to {target.mode} to.</p>}
      {parent && !inline && <ComposeTarget mode={target.mode} note={parent} />}
      <div class={dragging ? "compose-area dragging" : "compose-area"}
        onDragOver={e => { if ([...(e.dataTransfer?.types ?? [])].includes("Files")) { e.preventDefault(); setDragging(true) } }}
        onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget)) setDragging(false) }}
        onDrop={e => { e.preventDefault(); setDragging(false); addFiles(e.dataTransfer.files) }}>
        <textarea ref={box} class="compose" rows={inline ? 2 : 6} value={text} aria-label={title}
          placeholder={target?.mode === "reply" ? "Write your reply" : target ? "Add your comment" : "What's happening?"}
          aria-autocomplete="list" aria-expanded={!!mention} aria-controls={mention ? "mention-picker" : undefined}
          onInput={e => { setText(e.currentTarget.value); track(e.currentTarget) }}
          onKeyUp={e => { if (e.key.startsWith("Arrow") && !mention) track(e.currentTarget) }} onClick={e => track(e.currentTarget)}
          onPaste={e => { const files = [...(e.clipboardData?.files ?? [])]; if (files.some(isMedia)) { e.preventDefault(); addFiles(files) } }} />
        {mention && <MentionPicker ctx={ctx} query={mention.query} onPick={pick} onClose={closePicker} input={box} />}
        {photos.length > 0 && (
          <ul class="compose-photos" aria-label="Attachments">
            {photos.map((p, i) => {
              const kind = isVideo(p) ? "Video" : "Photo", described = !!p.alt?.trim()
              return (
              <li key={p.id} class={`compose-photo ${p.status}`}>
                {kind === "Video"
                  ? <video src={p.preview} muted playsinline preload="metadata" aria-label={described ? p.alt : `${kind} ${i + 1}`} />
                  : <img src={p.preview} alt={described ? p.alt : `${kind} ${i + 1}`} />}
                {kind === "Video" && <span class="compose-photo-kind" aria-hidden="true">
                  <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M8 5.5v13l11-6.5z" /></svg>
                </span>}
                {p.status !== "done" && p.status !== "failed" && <span class="compose-photo-state" role="status">Uploading…</span>}
                {p.status === "failed" && <span class="compose-photo-state" title={p.error}>Didn't upload</span>}
                {p.status === "failed" && p.file && <button type="button" class="compose-photo-retry" onClick={() => upload(p.id, p.file)}>Retry</button>}
                {/* Filled once described, hollow while not, so an undescribed one shows at a glance (ComposeView+Chrome altChip). */}
                {p.status !== "failed" && <button type="button" class={described ? "compose-alt described" : "compose-alt"}
                  aria-label={described ? `Edit description of ${kind.toLowerCase()} ${i + 1}` : `Add description to ${kind.toLowerCase()} ${i + 1}`}
                  title={described ? p.alt : "Describe this for screen readers"} onClick={() => setAltFor(p.id)}>ALT</button>}
                <button type="button" class="compose-photo-remove" aria-label={`Remove ${kind.toLowerCase()} ${i + 1}`} onClick={() => removePhoto(p.id)}>
                  <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
                </button>
              </li>
              )
            })}
          </ul>
        )}
        {altFor != null && photos.some(p => p.id === altFor) && (
          <AltDialog value={photos.find(p => p.id === altFor).alt ?? ""} video={isVideo(photos.find(p => p.id === altFor))}
            onSave={alt => { update(altFor, { alt }); setAltFor(null) }} onClose={() => setAltFor(null)} />
        )}
        {photos.filter(p => p.status === "failed").map(p => <p key={p.id} class="error small compose-photo-error">{p.error}</p>)}
        <div class="compose-tools">
          <button type="button" class="small compose-add-photo" disabled={photos.length >= MAX_PHOTOS} onClick={() => picker.current.click()}>
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2.5" /><circle cx="9" cy="10" r="1.6" /><path d="M21 16l-5-5-8 8" /></svg>
            Photo or video
          </button>
          <input ref={picker} type="file" accept="image/*,video/*" multiple hidden onChange={e => { addFiles(e.currentTarget.files); e.currentTarget.value = "" }} />
          {photos.length > 0 && <span class="muted small">{photos.length} of {MAX_PHOTOS}</span>}
          {loaded === key && (text.trim() || ready.length > 0) && !result && <span class="muted small compose-draft">Draft saved</span>}
        </div>
      </div>
      <button class="primary" disabled={!canPost} onClick={post} aria-busy={busy || uploading || undefined}>{busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Posting…") : uploading ? "Uploading…" : target?.mode === "reply" ? "Reply" : "Post"}</button>
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}

/** Writing one attachment's NIP-92 alt (ComposeView+Chrome altEditorSheet). */
function AltDialog({ value, video, onSave, onClose }) {
  const [text, setText] = useState(value)
  const box = useRef(null)
  useEffect(() => { box.current?.focus() }, [])
  return (
    <Dialog label="Describe this media" onClose={onClose}>
      <h3>Describe this {video ? "video" : "photo"}</h3>
      <p class="muted small">Published as its ALT text. Screen readers read this instead of the {video ? "video" : "picture"}.</p>
      <textarea ref={box} class="compose-alt-text" rows={4} value={text} aria-label="Media description"
        onInput={e => setText(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); onSave(text.trim()) } }} />
      <div class="mod-row">
        <button type="button" onClick={onClose}>Cancel</button>
        <button type="button" class="primary" onClick={() => onSave(text.trim())}>Save</button>
      </div>
    </Dialog>
  )
}

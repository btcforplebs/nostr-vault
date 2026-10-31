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
import { Avatar } from "../components/Avatar.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { PostResult } from "./compose/PostResult.jsx"
import { canGoBack } from "../components/nav-depth.js"
import { takeKeyboard } from "./compose/keyboard.js"
import { draftKey, idbDrafts } from "./compose/drafts.js"
import { ComposeKinds, composeType } from "./compose/ComposeKinds.jsx"
import { ArticleCompose } from "./compose/ArticleCompose.jsx"
import { PollCompose } from "./compose/PollCompose.jsx"
import { SEND_ACTIONS, countdownText, sendAction, sendDelaySeconds, startCountdown } from "../net/send-delay.js"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/compose.css")

/** The iPhone's countdown pill (PostActionPill): "Posting in 5s", a bar running down, Undo. */
function SendPill({ pending, onUndo }) {
  const text = countdownText(pending.action, pending.remaining)
  return (
    <div class="send-pill" role="status" aria-label={`${SEND_ACTIONS[pending.action].label} in ${Math.max(1, Math.ceil(pending.remaining))} seconds`}>
      <span class="send-pill-text">{text}</span>
      <span class="send-pill-bar" aria-hidden="true"><span style={{ width: `${Math.min(100, (pending.remaining / pending.total) * 100)}%` }} /></span>
      <button type="button" class="send-pill-undo" onClick={onUndo}>Undo</button>
    </div>
  )
}

// The note being replied to or quoted, under a label saying which.
function ComposeTarget({ mode, note }) {
  // A reply gets the iPhone's compact strip (ComposeView+Chrome): their picture, "Replying to Name", a few lines of
  // the text and no media. A quote keeps the whole note, since it is part of what you post.
  if (mode === "reply") {
    const snippet = replySnippet(note.content)
    return (
      <div class="compose-target compose-replying">
        <Avatar pubkey={note.pubkey} size={32} />
        <div class="compose-replying-text">
          <div class="compose-label">Replying to <AuthorName pubkey={note.pubkey} /></div>
          {snippet && <p class="compose-replying-snippet">{snippet}</p>}
        </div>
      </div>
    )
  }
  return (
    <div class="compose-target">
      <div class="compose-label">{mode === "reply" ? "Replying to" : "Quoting"} <AuthorName pubkey={note.pubkey} /></div>
      <NoteText content={note.content} />
    </div>
  )
}

/** The text of the note being replied to, without its media links and nostr: references, on one line. */
export const replySnippet = content => content.replace(/https?:\/\/\S+|nostr:\S+/g, " ").replace(/\s+/g, " ").trim()

export { draftKey, idbDrafts } from "./compose/drafts.js"

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

// An on-screen keyboard shrinks only the visual viewport, so 100vh can't see it, and iOS Safari scrolls the page to
// the caret instead: the sheet's bar went up under the status bar and the tools down under the keyboard. While a
// keyboard is up, the sheet is pinned to what's visible. Zoom shrinks the visual viewport too, so the keyboard is
// what's left of the layout viewport once zoom is cancelled (height * scale).
const KEYBOARD_MIN = 120
export function keyboardFrame(vv, layoutHeight) {
  if (!vv || layoutHeight - vv.height * vv.scale < KEYBOARD_MIN) return null
  return { top: vv.offsetTop, height: vv.height }
}

function useKeyboardFrame(on) {
  const [frame, setFrame] = useState(null)
  useEffect(() => {
    const vv = globalThis.visualViewport
    if (!on || !vv) return
    const update = () => setFrame(f => {
      const next = keyboardFrame(vv, document.documentElement.clientHeight)
      return f?.top === next?.top && f?.height === next?.height ? f : next
    })
    update()
    vv.addEventListener("resize", update)
    vv.addEventListener("scroll", update)
    return () => { vv.removeEventListener("resize", update); vv.removeEventListener("scroll", update) }
  }, [on])
  return frame
}

/** `fixed`: the reply or quote to write, instead of the one in the address (the desktop's inline reply under a thread).
 *  `inline`: drawn small, with no title and no copy of the note above it, since the thread is right there. */
export function ComposeScreen(props) {
  const type = props.fixed || props.inline ? "note" : composeType()
  if (type === "article") return <ArticleCompose ctx={props.ctx} />
  if (type === "poll") return <PollCompose ctx={props.ctx} />
  return <NoteCompose {...props} />
}

function NoteCompose({ ctx, fixed = null, inline = false }) {
  const [text, setText] = useState("")
  const [mentions, setMentions] = useState({}) // { "@Name": pubkey }
  const [photos, setPhotos] = useState([]) // photos and videos: { id, preview, status: "uploading" | "done" | "failed", error?, file?, url?, alt?, ... }
  const [altFor, setAltFor] = useState(null) // the id whose ALT is being written
  const [mention, setMention] = useState(null) // the "@query" at the caret
  const [dragging, setDragging] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [finished, setFinished] = useState(false) // sent, with no page of this app to go back to: Done shows
  const [err, setErr] = useState("")
  // The send counting down: { action, total, remaining }. Nothing is signed until it ends; Undo drops it.
  const [pending, setPending] = useState(null)
  const countdown = useRef(null)
  const [undone, setUndone] = useState(false)
  const [leaving, setLeaving] = useState(false) // the iPhone's "Save this note as a draft?" on Cancel
  // Leaving the composer mid-countdown is an Undo: the note stays as a draft, nothing is signed.
  useEffect(() => () => countdown.current?.cancel(), [])
  // Read on every render: going from a reply to the Post button keeps this screen mounted and only changes the hash.
  const target = fixed ?? composeTarget()
  const [note, setNote] = useState(null) // { id, event } once looked up; event null when not found

  useEffect(() => {
    setNote(null); setResult(null); setErr(""); setUndone(false)
    if (!target) return
    let live = true
    findNote(ctx, target.id).catch(() => null).then(event => { if (live) setNote({ id: target.id, event }) })
    return () => { live = false }
  }, [target?.mode, target?.id])

  const parent = target && note?.id === target.id ? note.event : null
  useEffect(() => {
    if (parent) fetchProfiles(ctx.vault, [parent.pubkey], uniq([...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {})
  }, [parent?.pubkey])
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
  // Opened from Reply or Quote: the composer starts at its top (not at the thread's scroll, which hid the "Replying
  // to" strip) and the cursor goes in the box with the keyboard up (compose/keyboard.js). The reply box under a thread
  // (inline) waits to be tapped.
  useEffect(() => {
    if (inline) return
    globalThis.scrollTo?.(0, 0)
    takeKeyboard(box.current)
  }, [target?.mode, target?.id])
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
  const canPost = !busy && !pending && !uploading && (text.trim() || ready.length) && (!target || parent)

  // The iPhone's send delay: the note as it is now waits a few seconds (Settings › Send Delay), then is signed and sent.
  const post = () => {
    setErr(""); setResult(null); setUndone(false)
    let built
    try { built = buildPost({ text, mentions, photos: ready, target, parent }) } catch (e) { return setErr(String(e?.message ?? e)) }
    const action = sendAction(target), seconds = sendDelaySeconds()
    if (seconds > 0) setPending({ action, total: seconds, remaining: seconds })
    countdown.current = startCountdown({
      seconds,
      onTick: remaining => setPending(p => p && { ...p, remaining }),
      onDone: () => { countdown.current = null; setPending(null); send(built) },
    })
  }
  // Cancel: an empty box just closes; one with a note asks, as the iPhone does. The draft is already saved, so Save
  // Draft only closes; Discard deletes it first. A countdown running is stopped either way.
  const cancel = () => {
    undo()
    if (text.trim() || ready.length) setLeaving(true)
    else history.back()
  }
  const discard = async () => {
    await saving.current
    await drafts.current.delete(key).catch(() => {})
    setLoaded(null) // so the cleared box isn't saved back over it
    setText(""); setMentions({}); setPhotos([]); setLeaving(false)
    history.back()
  }
  const undo = () => { if (countdown.current?.cancel()) { countdown.current = null; setPending(null); setUndone(true); box.current?.focus() } }
  // Once a relay has the note, the composer closes back to where it was opened, as the iPhone's sheet does. Opened as
  // the first page there's nowhere to go back to, so the result stays with a Done button. A note no relay took stays
  // here with its errors; the reply box under a thread (inline) just clears.
  const send = async ({ content, tags }) => {
    setBusy(true)
    try {
      const sent = await publishNote(ctx.vault, ctx.signer, ctx.session.pubkey, content, ctx.account.relays.write, tags)
      setResult(sent)
      setText(""); setMentions({}); setPhotos([]); setMention(null)
      if (!inline && reachedRelay(sent)) {
        if (canGoBack()) history.back()
        else setFinished(true)
      }
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  const title = !target ? "New Note" : target.mode === "reply" ? "Reply" : "Quote"
  const postLabel = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : `${SEND_ACTIONS[sendAction(target)].label}…`) : uploading ? "Uploading…" : target?.mode === "reply" ? "Reply" : "Post"
  const keyboard = useKeyboardFrame(!inline)
  const postButton = cls => <button class={cls} disabled={!canPost} onClick={post} aria-busy={busy || uploading || undefined}>{postLabel}</button>
  return (
    <main class={inline ? "screen compose-inline" : keyboard ? "screen compose-sheet keyboard" : "screen compose-sheet"}
      style={keyboard ? { "--kb-top": `${keyboard.top}px`, "--kb-height": `${keyboard.height}px` } : undefined}>
      {pending && <SendPill pending={pending} onUndo={undo} />}
      {/* The iPhone's compose sheet: Cancel, the title, and Post at the top right (ComposeView+Chrome). */}
      {!inline && <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2>{title}</h2>
        {postButton("compose-post")}
      </header>}
      {!target && !inline && <ComposeKinds type="note" />}
      {waiting && !inline && <p class="status-line">Finding the note…</p>}
      {target && note?.id === target.id && !parent && <p class="error status-line">That note couldn't be found, so there's nothing to {target.mode} to.</p>}
      {parent && !inline && <ComposeTarget mode={target.mode} note={parent} />}
      <div class={dragging ? "compose-area dragging" : "compose-area"}
        onDragOver={e => { if ([...(e.dataTransfer?.types ?? [])].includes("Files")) { e.preventDefault(); setDragging(true) } }}
        onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget)) setDragging(false) }}
        onDrop={e => { e.preventDefault(); setDragging(false); addFiles(e.dataTransfer.files) }}>
        {!inline && <span class="compose-avatar" aria-hidden="true"><Avatar pubkey={ctx.session.pubkey} size={40} /></span>}
        <textarea ref={box} class="compose" rows={inline ? 2 : 6} value={text} aria-label={title} readOnly={!!pending || busy}
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
          <button type="button" class="small compose-add-photo" disabled={photos.length >= MAX_PHOTOS || !!pending || busy} onClick={() => picker.current.click()}
            aria-label="Photo or video" title="Photo or video">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2.5" /><circle cx="9" cy="10" r="1.6" /><path d="M21 16l-5-5-8 8" /></svg>
            <span class="compose-add-photo-label">Photo or video</span>
          </button>
          <input ref={picker} type="file" accept="image/*,video/*" multiple hidden onChange={e => { addFiles(e.currentTarget.files); e.currentTarget.value = "" }} />
          {photos.length > 0 && <span class="muted small">{photos.length} of {MAX_PHOTOS}</span>}
          {loaded === key && (text.trim() || ready.length > 0) && !result && <span class="muted small compose-draft">Draft saved</span>}
        </div>
      </div>
      {inline && postButton("primary")}
      {leaving && (
        <Dialog label="Save this note as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this note as a draft?</h3>
          <div class="mod-row compose-leave">
            <button type="button" class="primary" onClick={() => { setLeaving(false); history.back() }}>Save Draft</button>
            <button type="button" class="danger" onClick={discard}>Discard</button>
          </div>
        </Dialog>
      )}
      {undone && !pending && !result && <p class="muted small compose-undone" role="status">Not sent. Nothing was signed, and your note is still here.</p>}
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
      {finished && <button type="button" class="primary compose-done" onClick={() => { location.hash = "#/feed" }}>Done</button>}
    </main>
  )
}

/** Whether any relay other than this machine's own took the note. */
export const reachedRelay = result => !!result?.relays?.some(r => !r.local && r.ok)

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

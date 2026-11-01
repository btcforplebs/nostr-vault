// Post a note: signed by the user's signer, stored in the in-page Haven first, then sent to the relays
// publishRelays picks (write list + the iPhone app's broadcast set). "#/compose?reply=<id>" and "?quote=<id>"
// (a note card's Reply and Quote) post a reply with NIP-10 tags, or a quote with a q tag and the nevent.
// As on the iPhone: photos and videos (picked, dropped or pasted) go up to the account's media servers as they're added
// and into the note as links with imeta tags, each with its own ALT description; "@" suggests people and tags them;
// what isn't posted yet is kept as a draft. A photo picked while there's text goes in at the cursor
// (compose/draft-model.js), and a live preview draws the note as the feed will (side by side on a wide screen, a
// Write / Preview switch on a phone, where the keyboard owns the bottom half).
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
import { EMPTY_DRAFT, addPhotos, photoToken, placeBody, removePhoto as dropPhoto, updatePhoto, withoutStaleTokens } from "./compose/draft-model.js"
import { ComposeAttachments } from "./compose/ComposeAttachments.jsx"
import { ComposePreview } from "./compose/ComposePreview.jsx"
import { isMedia, isVideo } from "./compose/media-kind.js"

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

export { isMedia, isVideo } from "./compose/media-kind.js"
const emptyDraft = d => !d.text.trim() && !d.photos.length

/** Content and tags for a post: tokens -> nostr:npub, photo links where they were placed and the rest appended (as
 *  the iPhone does; draft-model.js placeBody), then the reply or quote's tags, a p tag per mention still in the text,
 *  one imeta per photo. `photos`: the uploaded ones. */
export function buildPost({ text, mentions, photos, target, parent }) {
  const body = toNostr(placeBody(text, photos), mentions)
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
  // The draft, one model: { text, mentions: { "@Name": pubkey }, photos: [{ id, preview, status: "queued" | "uploading" |
  // "done" | "failed", progress?, error?, file?, url?, alt?, ... }] }. A photo's upload and its place in the text change
  // together (draft-model.js).
  const [draft, setDraft] = useState(EMPTY_DRAFT)
  const { text, mentions, photos } = draft
  const setText = t => setDraft(d => ({ ...d, text: t }))
  const setMentions = f => setDraft(d => ({ ...d, mentions: typeof f === "function" ? f(d.mentions) : f }))
  const clearDraft = () => setDraft(EMPTY_DRAFT)
  const [view, setView] = useState("write") // phone: "write" | "preview"; wide screens show both
  const [waitPost, setWaitPost] = useState(false) // Post tapped while photos are still going up
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
    setLoaded(null); clearDraft(); setMention(null); setWaitPost(false)
    drafts.current.get(key).catch(() => null).then(d => {
      if (!live) return
      if (d) setDraft({ text: withoutStaleTokens(d.text ?? ""), mentions: d.mentions ?? {}, photos: (d.photos ?? []).map(p => ({ ...p, id: ++nextPhoto, status: "done", preview: p.url })) })
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

  // Photos: hashed, signed and uploaded one at a time (one signer prompt after another), the moment they're added. A
  // photo removed before its turn is skipped (no signer prompt); one going up is stopped.
  const servers = useRef(null)
  const queue = useRef(Promise.resolve())
  const stops = useRef(new Map()) // id -> AbortController, while it waits or goes up
  useEffect(() => () => { for (const c of stops.current.values()) c.abort() }, [])
  const update = (id, patch) => setDraft(d => updatePhoto(d, id, patch))
  const upload = (id, file) => {
    const stop = new AbortController()
    stops.current.get(id)?.abort()
    stops.current.set(id, stop)
    update(id, { status: "uploading", error: "", progress: undefined })
    queue.current = queue.current.then(async () => {
      if (stop.signal.aborted) return
      try {
        servers.current ??= await mediaServers(ctx)
        const onProgress = progress => update(id, { progress })
        const [size, up] = await Promise.all([pixelSize(file), uploadPhoto(file, { ctx, servers: servers.current, signal: stop.signal, onProgress })])
        if (!stop.signal.aborted) { keepCaret(photoToken(id), up.url); update(id, { ...size, ...up, status: "done", file: null, progress: undefined }) }
      } catch (e) { if (!stop.signal.aborted) update(id, { status: "failed", error: String(e?.message ?? e), progress: undefined }) }
      finally { if (stops.current.get(id) === stop) stops.current.delete(id) }
    })
  }
  // A placeholder becoming its link changes the text under someone typing: the caret stays where it was in their words
  // (a value set from code would otherwise throw it to the end).
  const keepCaret = (token, url) => {
    const el = box.current
    if (!el || document.activeElement !== el) return
    const at = el.value.indexOf(token)
    if (at < 0) return
    const shift = n => (n > at ? n + url.length - token.length : n)
    const [a, b] = [shift(el.selectionStart), shift(el.selectionEnd)]
    requestAnimationFrame(() => { if (document.activeElement === el) el.setSelectionRange(a, b) })
  }
  // After a pick the caret goes back in the text, just after what went in, to keep typing.
  const caretAfter = token => requestAnimationFrame(() => {
    const el = box.current, at = el?.value.indexOf(token) ?? -1
    if (at < 0) return
    const c = at + token.length + (el.value[at + token.length] === "\n" ? 1 : 0)
    el.focus(); el.setSelectionRange(c, c)
  })
  const addFiles = files => {
    const media = [...files].filter(isMedia)
    if (!media.length) return
    setErr("")
    const el = box.current
    setDraft(d => {
      const room = MAX_PHOTOS - d.photos.length
      if (media.length > room) setErr(`A note can carry ${MAX_PHOTOS} attachments.`)
      const added = media.slice(0, Math.max(0, room)).map(file => ({ id: ++nextPhoto, file, preview: URL.createObjectURL(file), status: "queued" }))
      queueMicrotask(() => added.forEach(p => upload(p.id, p.file)))
      const next = addPhotos(d, added, el?.selectionStart, el?.selectionEnd)
      if (added.length && next.text !== d.text) caretAfter(photoToken(added[added.length - 1].id))
      return next
    })
  }
  const removePhoto = id => {
    stops.current.get(id)?.abort(); stops.current.delete(id)
    const p = photos.find(x => x.id === id)
    if (p?.preview?.startsWith("blob:")) URL.revokeObjectURL(p.preview)
    setDraft(d => dropPhoto(d, id))
  }
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

  const goingUp = photos.filter(p => p.status !== "done" && p.status !== "failed").length
  const uploading = goingUp > 0
  const ready = photos.filter(p => p.status === "done")
  // Post waits only on uploads still going: tapped meanwhile, it posts by itself once they're up.
  const canPost = !busy && !pending && !waitPost && (text.trim() || photos.length) && (!target || parent)
  const failed = photos.filter(p => p.status === "failed").length
  useEffect(() => {
    if (!waitPost || uploading) return
    setWaitPost(false)
    if (failed) setErr(failed === 1 ? "A photo didn't upload. Retry it or remove it, then post." : `${failed} photos didn't upload. Retry or remove them, then post.`)
    else post()
  }, [waitPost, uploading])

  // The iPhone's send delay: the note as it is now waits a few seconds (Settings › Send Delay), then is signed and sent.
  const post = () => {
    setErr(""); setResult(null); setUndone(false)
    if (uploading) return setWaitPost(true)
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
    undo(); setWaitPost(false)
    if (text.trim() || ready.length) setLeaving(true)
    else history.back()
  }
  const discard = async () => {
    await saving.current
    await drafts.current.delete(key).catch(() => {})
    setLoaded(null) // so the cleared box isn't saved back over it
    clearDraft(); setLeaving(false)
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
      clearDraft(); setMention(null)
      if (!inline && reachedRelay(sent)) {
        if (canGoBack()) history.back()
        else setFinished(true)
      }
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  const title = !target ? "New Note" : target.mode === "reply" ? "Reply" : "Quote"
  const postLabel = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : `${SEND_ACTIONS[sendAction(target)].label}…`) : waitPost ? "Waiting for uploads…" : target?.mode === "reply" ? "Reply" : "Post"
  const keyboard = useKeyboardFrame(!inline)
  const postButton = cls => <button class={cls} disabled={!canPost} onClick={post} aria-busy={busy || waitPost || undefined}>{postLabel}</button>
  const preview = !inline && <ComposePreview pubkey={ctx.session.pubkey} uploading={goingUp} deps={[text, mentions, ready.length, ready.map(p => p.alt).join("\u0000"), parent?.id]}
    build={() => buildPost({ text, mentions, photos: ready, target, parent })} />
  return (
    <main class={`screen ${inline ? "compose-inline" : `compose-sheet${keyboard ? " keyboard" : ""} view-${view}`}`}
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
      {/* Phone: the keyboard owns the bottom half, so the preview takes the editor's place instead of squeezing it. */}
      {!inline && <div class="compose-view-switch" role="tablist" aria-label="Write or preview">
        {["write", "preview"].map(v => <button key={v} type="button" role="tab" aria-selected={view === v} class={view === v ? "on" : ""}
          onClick={() => { setView(v); if (v === "write") requestAnimationFrame(() => box.current?.focus()) }}>{v === "write" ? "Write" : "Preview"}</button>)}
      </div>}
      <div class={inline ? "compose-split-off" : "compose-split"}>
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
        <ComposeAttachments photos={photos} onAlt={setAltFor} onRetry={id => { const p = photos.find(x => x.id === id); if (p?.file) upload(id, p.file) }} onRemove={removePhoto} />
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
      {preview}
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

// New diVine, the iPhone's DivineComposeView: a looping video up to 6 seconds, recorded (a phone's camera through the
// file picker) or chosen, a title and a caption. The video and a cover frame go up to the account's media servers, then
// a kind 34236 in diVine's own shape goes to the write relays and diVine's (divine.js), followed by the account's profile
// so diVine can show a name. A browser can't trim a video, so a longer one is turned away with the reason.
import { useEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { mediaServers, uploadPhoto } from "../../net/upload.js"
import { localProfile } from "../../net/profile-edit.js"
import { pool } from "../../net/pool.js"
import { PostResult } from "./PostResult.jsx"
import { DIVINE_RELAY, LIMIT_SECONDS, REEL_KIND, clipProblem, divineAnswer, divineRefused, divineRelays, divineTags, lengthShare, lengthText } from "./divine.js"

if (import.meta.env) import("../../styles/divine-compose.css")

/** Length, size and a cover frame (a JPEG near the start) of a picked video, read in the page. */
export function readClip(file, doc = document) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file)
    const v = doc.createElement("video")
    v.muted = true; v.playsInline = true; v.preload = "auto"; v.src = url
    const fail = () => { URL.revokeObjectURL(url); reject(new Error("Couldn't read that video.")) }
    v.onerror = fail
    v.onloadedmetadata = () => { v.currentTime = Math.min(0.1, (v.duration || 0) / 2) }
    v.onseeked = () => {
      const scale = Math.min(1, 1080 / Math.max(v.videoWidth, v.videoHeight, 1))
      const c = doc.createElement("canvas")
      c.width = Math.max(1, Math.round(v.videoWidth * scale)); c.height = Math.max(1, Math.round(v.videoHeight * scale))
      c.getContext("2d").drawImage(v, 0, 0, c.width, c.height)
      c.toBlob(poster => {
        if (!poster) return fail()
        resolve({ url, file, mime: file.type, duration: v.duration, width: v.videoWidth, height: v.videoHeight, poster })
      }, "image/jpeg", 0.8)
    }
  })
}

export function DivineCompose({ ctx }) {
  const [clip, setClip] = useState(null)
  const [preparing, setPreparing] = useState(false)
  const [title, setTitle] = useState("")
  const [caption, setCaption] = useState("")
  const [status, setStatus] = useState(null)
  const [err, setErr] = useState("")
  const [warn, setWarn] = useState("")
  const [result, setResult] = useState(null)
  const recorder = useRef(null), chooser = useRef(null)
  const phone = globalThis.matchMedia?.("(pointer: coarse)").matches
  const posting = !!status
  useEffect(() => () => { if (clip) URL.revokeObjectURL(clip.url) }, [clip])

  const take = async file => {
    if (!file) return
    setErr(""); setPreparing(true)
    try {
      const c = await readClip(file)
      const no = clipProblem(c)
      if (no) { URL.revokeObjectURL(c.url); setErr(no) } else setClip(c)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setPreparing(false) }
  }

  const post = async () => {
    if (!clip || posting) return
    setErr(""); setWarn(""); setResult(null)
    try {
      const servers = await mediaServers(ctx)
      setStatus("Uploading video…")
      const video = await uploadPhoto(clip.file, { ctx, servers, onProgress: f => setStatus(`Uploading video… ${Math.round(f * 100)}%`) })
      setStatus("Uploading cover…")
      const poster = await uploadPhoto(new File([clip.poster], "cover.jpg", { type: "image/jpeg" }), { ctx, servers })
      setStatus("Posting…")
      const t = title.trim(), c = caption.trim()
      const tags = divineTags({ video, poster: poster.url, clip, title: t, caption: c, publishedAt: Math.floor(Date.now() / 1000) })
      const sent = await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, REEL_KIND, c, divineRelays(ctx.account.relays.write), tags)
      setResult(sent)
      const divine = divineAnswer(sent.relays)
      if (divine && !divine.ok) setWarn(divineRefused(divine.message))
      // Without the profile diVine shows the post with no name and can't find the account in search.
      localProfile(ctx.vault, ctx.session.pubkey).then(p => p && Promise.allSettled(pool.publish([DIVINE_RELAY], p))).catch(() => {})
      URL.revokeObjectURL(clip.url)
      setClip(null); setTitle(""); setCaption("")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setStatus(null) }
  }

  const label = status ? "Posting…" : "Post"
  return (
    <main class="screen compose-sheet compose-divine">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={() => history.back()}>Cancel</button>
        <h2>New diVine</h2>
        <button type="button" class="compose-post" disabled={!clip || posting} aria-busy={posting || undefined} onClick={post}>{label}</button>
      </header>
      <div class="divine-form">
        <div class="divine-head">
          <strong>A looping video, up to {LIMIT_SECONDS} seconds</strong>
          <span>{phone ? "Record one, or choose a video." : "Choose a video."} Longer videos need trimming first: a browser can't cut them.</span>
        </div>
        <div class="divine-video">
          {clip ? <video src={clip.url} muted autoplay loop playsInline controls={false} aria-label="Your video" />
            : preparing ? <p role="status"><span class="spinner" aria-hidden="true" />Getting the video ready…</p>
            : <p class="divine-limit" aria-label={`Up to ${LIMIT_SECONDS} seconds`}><b>{LIMIT_SECONDS}s</b><span>max length</span></p>}
        </div>
        {clip && <div class="divine-meter">
          <div class="divine-bar"><span style={{ width: `${Math.max(2, lengthShare(clip.duration) * 100)}%` }} /></div>
          <div class="divine-meter-row"><b>{lengthText(clip.duration)}</b><span>Fits</span></div>
        </div>}
        {!posting && <div class={clip ? "divine-sources row" : "divine-sources"}>
          {phone && <button type="button" class={clip ? "" : "primary"} disabled={preparing} onClick={() => recorder.current.click()}>{clip ? "Record again" : "Record a video"}</button>}
          <button type="button" class={!clip && !phone ? "primary" : ""} disabled={preparing} onClick={() => chooser.current.click()}>{clip ? "Choose another" : "Choose a video"}</button>
          <input ref={recorder} type="file" accept="video/*" capture="environment" hidden onChange={e => { take(e.currentTarget.files?.[0]); e.currentTarget.value = "" }} />
          <input ref={chooser} type="file" accept="video/mp4,video/quicktime,video/webm" hidden onChange={e => { take(e.currentTarget.files?.[0]); e.currentTarget.value = "" }} />
        </div>}
        {clip && <div class="divine-fields">
          <input class="kind-field" type="text" placeholder="Title (optional)" aria-label="Title" value={title} readOnly={posting} onInput={e => setTitle(e.currentTarget.value)} />
          <textarea class="kind-field" rows={3} placeholder="Caption (optional) — #tags work" aria-label="Caption" value={caption} readOnly={posting} onInput={e => setCaption(e.currentTarget.value)} />
        </div>}
        {status && <p class="muted small divine-status" role="status"><span class="spinner" aria-hidden="true" />{status}</p>}
        {err && <p class="error">{err}</p>}
        {warn && <p class="divine-warn" role="status">{warn}</p>}
        {result && <PostResult result={result} />}
      </div>
    </main>
  )
}

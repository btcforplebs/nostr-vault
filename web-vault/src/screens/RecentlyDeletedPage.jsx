// Settings › Recently Deleted (iPhone RecentlyDeletedSettingsView): posts deleted from this browser in the last 30
// days, each with Un-delete (posted again as a new post) and Delete Forever (the copy goes; the post stays deleted).
import { useEffect, useState } from "preact/hooks"
import { NoteText } from "../components/NoteText.jsx"
import { MediaImage } from "../components/MediaImage.jsx"
import { imageItem } from "../net/note-media.js"
import { imagesOf } from "../net/vault-lists.js"
import { ago } from "../components/time.js"
import { READ_ONLY } from "../signer/readonly.js"
import { deletedPosts, undelete, forgetDeleted, UNDELETE_NOTE, KEEP_DAYS } from "../net/recently-deleted.js"
import { SkeletonRows } from "../components/FeedExtras.jsx"

export function RecentlyDeletedPage({ ctx }) {
  const [posts, setPosts] = useState(null)
  const [msg, setMsg] = useState("")
  const reload = () => deletedPosts(ctx.session.pubkey).then(setPosts).catch(e => { setPosts([]); setMsg(String(e?.message ?? e)) })
  useEffect(() => { reload() }, [ctx.session.pubkey])
  if (!posts) return <SkeletonRows count={2} label="Loading deleted posts…" />
  return (
    <>
      {msg && <p class="settings-note small">{msg}</p>}
      {posts.length ? posts.map(p => <DeletedRow key={p.id} ctx={ctx} post={p} onDone={m => { setMsg(m); reload() }} />)
        : <p class="empty">No deleted posts.</p>}
      <p class="settings-note muted small">Posts you delete in this browser stay here for {KEEP_DAYS} days. {UNDELETE_NOTE}</p>
    </>
  )
}

function DeletedRow({ ctx, post, onDone }) {
  const readOnly = !!ctx.signer?.readOnly
  const [busy, setBusy] = useState("")
  const [asking, setAsking] = useState(false)
  const [err, setErr] = useState("")
  const pictures = imagesOf(post)
  const again = async () => {
    setBusy("undelete"); setErr("")
    try { await undelete(ctx, post); onDone("Posted again.") }
    catch (e) { setErr(`Couldn't post it again: it wasn't signed, or no relay took it (${e?.message ?? e}). The copy is kept here.`) }
    finally { setBusy("") }
  }
  const forget = async () => { setBusy("forget"); await forgetDeleted(ctx, post).catch(() => {}); setBusy(""); onDone("") }
  return (
    <article class="note deleted-post">
      {/* Four lines of text and a strip of thumbnails, as the phone lists them (RecentlyDeletedSettingsView). */}
      <div class="deleted-text"><NoteText content={pictures.reduce((t, u) => t.split(u).join(""), post.content).trim()} images={false} /></div>
      {pictures.length > 0 && <div class="vault-thumbs">{pictures.slice(0, 6).map(u => <MediaImage key={u} item={imageItem(u, post.tags)} author={post.pubkey} loading="lazy" />)}</div>}
      <div class="muted small">Deleted {ago(post.deletedAt)} ago</div>
      {readOnly ? <p class="muted small">{READ_ONLY}</p> : asking
        ? <div class="row"><span class="small">This removes the saved copy. You won't be able to un-delete this post.</span><button class="danger small" disabled={!!busy} onClick={forget} aria-busy={busy === "forget" || undefined}>Delete Forever</button><button class="small" disabled={!!busy} onClick={() => setAsking(false)}>Cancel</button></div>
        : <div class="row"><button class="primary small" disabled={!!busy} onClick={again} aria-busy={busy === "undelete" || undefined}>{busy === "undelete" ? "Posting…" : "Un-delete"}</button><button class="danger small" disabled={!!busy} onClick={() => setAsking(true)}>Delete Forever</button></div>}
      {err && <p class="error small">{err}</p>}
    </article>
  )
}

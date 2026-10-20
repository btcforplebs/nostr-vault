// Settings › Recently Deleted (iPhone RecentlyDeletedSettingsView): posts deleted from this browser in the last 30
// days, each with Un-delete (posted again as a new post) and Delete Forever (the copy goes; the post stays deleted).
import { useEffect, useState } from "preact/hooks"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { READ_ONLY } from "../signer/readonly.js"
import { deletedPosts, undelete, forgetDeleted, UNDELETE_NOTE, KEEP_DAYS } from "../net/recently-deleted.js"

export function RecentlyDeletedPage({ ctx }) {
  const [posts, setPosts] = useState(null)
  const [msg, setMsg] = useState("")
  const reload = () => deletedPosts(ctx.session.pubkey).then(setPosts).catch(e => { setPosts([]); setMsg(String(e?.message ?? e)) })
  useEffect(() => { reload() }, [ctx.session.pubkey])
  if (!posts) return <p class="empty">Loading…</p>
  return (
    <>
      <p class="settings-note muted small">Posts you delete here are kept for {KEEP_DAYS} days in this browser. {UNDELETE_NOTE}</p>
      {msg && <p class="settings-note small">{msg}</p>}
      {posts.length ? posts.map(p => <DeletedRow key={p.id} ctx={ctx} post={p} onDone={m => { setMsg(m); reload() }} />)
        : <p class="empty">Nothing deleted in the last {KEEP_DAYS} days.</p>}
    </>
  )
}

function DeletedRow({ ctx, post, onDone }) {
  const readOnly = !!ctx.signer?.readOnly
  const [busy, setBusy] = useState("")
  const [asking, setAsking] = useState(false)
  const [err, setErr] = useState("")
  const again = async () => {
    setBusy("undelete"); setErr("")
    try { await undelete(ctx, post); onDone("Posted again.") }
    catch (e) { setErr(`Couldn't post it again (${e?.message ?? e}). The copy is kept here.`) }
    finally { setBusy("") }
  }
  const forget = async () => { setBusy("forget"); await forgetDeleted(ctx, post).catch(() => {}); setBusy(""); onDone("Deleted forever.") }
  return (
    <article class="note deleted-post">
      <NoteText content={post.content} images />
      <div class="muted small">Deleted {ago(post.deletedAt)} ago · posted {new Date(post.created_at * 1000).toLocaleDateString()}</div>
      {readOnly ? <p class="muted small">{READ_ONLY}</p> : asking
        ? <div class="row"><span class="small">Delete the copy for good? The post stays deleted.</span><button class="danger small" disabled={!!busy} onClick={forget}>Delete Forever</button><button class="small" disabled={!!busy} onClick={() => setAsking(false)}>Cancel</button></div>
        : <div class="row"><button class="primary small" disabled={!!busy} onClick={again}>{busy === "undelete" ? "Posting…" : "Un-delete"}</button><button class="danger small" disabled={!!busy} onClick={() => setAsking(true)}>Delete Forever</button></div>}
      {err && <p class="error small">{err}</p>}
    </article>
  )
}

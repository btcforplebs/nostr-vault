// Post a note: signed by the user's signer, stored in the in-page Haven first, then sent to the relays
// publishRelays picks (write list + the iPhone app's broadcast set). "#/compose?reply=<id>" and "?quote=<id>"
// (a note card's Reply and Quote) post a reply with NIP-10 tags, or a quote with a q tag and the nevent.
import { useEffect, useState } from "preact/hooks"
import { publishNote } from "../net/sync.js"
import { composeTarget, findNote, quoteOf, replyTags } from "../net/actions.js"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"

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

export function ComposeScreen({ ctx }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  // Read on every render: going from a reply to the Post button keeps this screen mounted and only changes the hash.
  const target = composeTarget()
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

  const post = async () => {
    setBusy(true); setErr(""); setResult(null)
    try {
      const body = text.trim()
      const { content, tags } = !parent ? { content: body, tags: [] }
        : target.mode === "reply" ? { content: body, tags: replyTags(parent) } : quoteOf(parent, body)
      setResult(await publishNote(ctx.vault, ctx.signer, ctx.session.pubkey, content, ctx.account.relays.write, tags))
      setText("")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  const title = !target ? "New note" : target.mode === "reply" ? "Reply" : "Quote"
  return (
    <main class="screen">
      <header class="screen-head"><h2>{title}</h2></header>
      {waiting && <p class="status-line">Finding the note…</p>}
      {target && note?.id === target.id && !parent && <p class="error status-line">That note couldn't be found, so there's nothing to {target.mode} to.</p>}
      {parent && <ComposeTarget mode={target.mode} note={parent} />}
      <textarea class="compose" rows={6} value={text} onInput={e => setText(e.currentTarget.value)}
        placeholder={target?.mode === "reply" ? "Write your reply" : target ? "Add your comment" : "What's happening?"} aria-label={title} />
      <button class="primary" disabled={busy || !text.trim() || (target && !parent)} onClick={post}>{busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Posting…") : target?.mode === "reply" ? "Reply" : "Post"}</button>
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}

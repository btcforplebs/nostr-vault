// Post a note: signed by the user's signer, stored in the in-page Haven first, then sent to the relays
// publishRelays picks (write list + the iPhone app's broadcast set).
import { useState } from "preact/hooks"
import { publishNote } from "../net/sync.js"

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

export function ComposeScreen({ ctx }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")

  const post = async () => {
    setBusy(true); setErr(""); setResult(null)
    try {
      setResult(await publishNote(ctx.vault, ctx.signer, ctx.session.pubkey, text.trim(), ctx.account.relays.write))
      setText("")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  return (
    <main class="screen">
      <header class="screen-head"><h2>New note</h2></header>
      <textarea class="compose" rows={6} value={text} onInput={e => setText(e.currentTarget.value)} placeholder="What's happening?" />
      <button class="primary" disabled={busy || !text.trim()} onClick={post}>{busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Posting…") : "Post"}</button>
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}

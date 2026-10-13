// Post a note: signed by the user's signer, stored in the in-page Haven first, then sent to their write relays.
import { useState } from "preact/hooks"
import { publishNote } from "../net/sync.js"

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
      {result && (
        <div class="result">
          <div>✓ Saved to your relay in this browser</div>
          {result.relays.map(r => <div key={r.url} class={r.ok ? "" : "error"}>{r.ok ? "✓" : "✗"} {r.url.replace("wss://", "")}{r.ok ? "" : `: ${r.message}`}</div>)}
          <a href="#/profile">See it on your profile</a>
        </div>
      )}
    </main>
  )
}

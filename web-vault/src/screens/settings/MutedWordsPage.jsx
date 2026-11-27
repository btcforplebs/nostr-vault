// Settings › Muted Words: the `word` entries of the user's kind 10000 (net/muted-words.js), in Public and Private
// sections like Blocked, with an add field and ✕ to remove. A new word is private unless "Mute publicly" is ticked
// (Logen 11-27). When the list's private part couldn't be opened, its words aren't shown and a private add is refused
// (setMutedWord throws), the same as a private block.
import { useState } from "preact/hooks"
import { useBlocks } from "../../components/useBlocks.js"
import { MUTED_WORD_MAX, mutedWordKey, mutedWordProblem, mutedWordSections, setMutedWord } from "../../net/muted-words.js"

export function MutedWordsPage({ ctx }) {
  const blocks = useBlocks(ctx)
  const { publicWords, privateWords } = mutedWordSections(blocks)
  const [text, setText] = useState("")
  const [pub, setPub] = useState(false)
  const [busy, setBusy] = useState("")
  const [err, setErr] = useState("")
  const [note, setNote] = useState("")
  const canPrivate = !!ctx.signer?.crypto && !blocks.privateNote
  const isPrivate = !pub
  const typed = mutedWordKey(text)
  const problem = typed ? mutedWordProblem(text, [...publicWords, ...privateWords]) : ""
  const run = async (key, fn) => {
    setBusy(key); setErr(""); setNote("")
    try { await fn(); return true } catch (e) { setErr(String(e?.message ?? e)); return false } finally { setBusy("") }
  }
  const add = async e => {
    e.preventDefault()
    if (!typed || problem || busy) return
    if (await run("add", () => setMutedWord(ctx, text, { mute: true, isPrivate }))) { setText(""); setPub(false) }
  }
  // A public word unmuted while the private part can't be opened: it comes out of the public part, but the same word
  // may also be in the private part, which is republished as it was, so say so rather than claim it's gone.
  const remove = async w => {
    const unchecked = blocks.privateNote
    if (await run(w, () => setMutedWord(ctx, w, { mute: false })) && unchecked)
      setNote(`Unmuted “${w}” in the public part. Your private part couldn't be opened (${unchecked}), so it may still be muted there.`)
  }
  const waiting = ctx.signer?.method === "nip46" ? "Waiting for your signer…" : null
  return (
    <>
      <p class="settings-note muted small">Notes, replies and messages with a muted word are hidden, here and in other apps that read your mute list. Words match in any case.</p>
      <section class="settings-group">
        <div class="section-label">Mute a Word</div>
        <form class="block-someone muted-word-add" onSubmit={add}>
          <input value={text} onInput={e => setText(e.currentTarget.value)} placeholder="Word or phrase" aria-label="Word or phrase to mute"
            maxLength={MUTED_WORD_MAX * 2} autocapitalize="off" autocorrect="off" spellcheck={false} disabled={busy === "add"} />
          <button type="submit" class="small danger-fill" disabled={!typed || !!problem || !!busy || (isPrivate && !canPrivate)} aria-busy={busy === "add" || undefined}>
            {busy === "add" ? waiting ?? "Muting…" : "Mute"}
          </button>
        </form>
        <label class="block-privately">
          <input type="checkbox" checked={pub} onChange={e => setPub(e.currentTarget.checked)} />
          <span>Mute publicly</span>
        </label>
        <p class="settings-note muted small">{pub
          ? "Anyone can see this word in your mute list."
          : canPrivate ? "Only you will see this word. It is encrypted in your mute list."
          : `Words can't be muted privately right now: ${blocks.privateNote || "your signer can't encrypt"}. Tick Mute publicly to add one anyway.`}</p>
        {problem && <p class="error small" role="status">{problem}</p>}
        {err && <p class="error small" role="alert">{err}</p>}
        {note && <p class="settings-note small" role="status">{note}</p>}
      </section>
      <WordSection title="Public" words={publicWords} busy={busy} onRemove={remove}
        empty="No public muted words." note="Anyone can see these in your mute list." />
      <WordSection title="Private" words={privateWords} busy={busy} onRemove={remove}
        empty={blocks.privateNote ? `Private words aren't shown: ${blocks.privateNote}.` : "No private muted words."}
        note="Only you can see these. They are encrypted in your mute list." />
    </>
  )
}

function WordSection({ title, words, busy, onRemove, empty, note }) {
  return (
    <section class="settings-group">
      <div class="section-label">{title}</div>
      {words.length ? (
        <ul class="muted-words">
          {words.map(w => (
            <li key={w} class="muted-word-row">
              <span class="muted-word">{w}</span>
              <button type="button" class="small" aria-label={`Unmute ${w}`} disabled={!!busy} aria-busy={busy === w || undefined} onClick={() => onRemove(w)}>
                {busy === w ? "…" : "✕"}
              </button>
            </li>
          ))}
        </ul>
      ) : <p class="empty blocked-empty">{empty}</p>}
      <p class="settings-note muted small">{note}</p>
    </section>
  )
}

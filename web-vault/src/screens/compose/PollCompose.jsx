// New Poll: a NIP-88 poll (kind 1068), as the iPhone writes one (Views/PollComposeView.swift): a question, two to ten
// options, whether voters pick one or any, and when voting closes. It names your public write relays for its votes and
// goes out the way a note does. What isn't posted yet is kept as a draft.
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { uniq } from "../../net/pool.js"
import { Dialog } from "../../components/Moderation.jsx"
import { PostResult } from "./PostResult.jsx"
import { ComposeKinds } from "./ComposeKinds.jsx"
import { idbDrafts } from "./drafts.js"
import { CLOSING, MAX_OPTIONS, MIN_OPTIONS, POLL_KIND, buildPoll, closingHint, emptyPoll, hasPoll, localInput, pollComplete, pollDraftOf, pollHint, pollRelaysFor } from "./poll.js"

const DRAFT_KEY = "poll"

export function PollCompose({ ctx }) {
  const [d, setD] = useState(emptyPoll)
  const set = patch => setD(cur => ({ ...cur, ...patch }))
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  const [leaving, setLeaving] = useState(false)
  const [, tick] = useState(0) // a custom closing time can pass while the form is open
  useEffect(() => { const t = setInterval(() => tick(n => n + 1), 30e3); return () => clearInterval(t) }, [])

  const drafts = useRef(null)
  drafts.current ??= idbDrafts(ctx.session.pubkey)
  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    let live = true
    drafts.current.get(DRAFT_KEY).catch(() => null).then(saved => {
      if (!live) return
      if (saved) {
        const options = (saved.options ?? []).slice(0, MAX_OPTIONS)
        while (options.length < MIN_OPTIONS) options.push("")
        setD({ ...emptyPoll(), ...saved, options })
      }
      setLoaded(true)
    })
    return () => { live = false }
  }, [])
  const saving = useRef(Promise.resolve())
  useEffect(() => {
    if (!loaded) return
    saving.current = saving.current.then(() => (hasPoll(d) ? drafts.current.put(DRAFT_KEY, pollDraftOf(d)) : drafts.current.delete(DRAFT_KEY))).catch(() => {})
  }, [d, loaded])

  // Options: Enter moves to the next one; Add option focuses the new one as soon as it's drawn (before the next key).
  const list = useRef(null)
  const focusNext = useRef(null)
  const focusOption = i => list.current?.querySelectorAll("input")[i]?.focus()
  useLayoutEffect(() => { if (focusNext.current != null) { focusOption(focusNext.current); focusNext.current = null } }, [d.options.length])
  const setOption = (i, v) => setD(cur => ({ ...cur, options: cur.options.map((o, j) => (j === i ? v : o)) }))
  const addOption = () => { if (d.options.length < MAX_OPTIONS) { focusNext.current = d.options.length; set({ options: [...d.options, ""] }) } }
  const removeOption = i => set({ options: d.options.filter((_, j) => j !== i) })

  const canPost = !busy && pollComplete(d)
  const hint = pollHint(d)
  const closing = closingHint(d)

  const post = async e => {
    e?.preventDefault()
    if (!canPost) return
    setErr(""); setResult(null); setBusy(true)
    try {
      const write = ctx.account.relays.write
      const relays = pollRelaysFor(write)
      const { content, tags } = buildPoll(d, relays)
      setResult(await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, POLL_KIND, content, uniq([...write, ...relays]), tags))
      setD(emptyPoll())
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const cancel = () => (hasPoll(d) ? setLeaving(true) : history.back())
  const discard = async () => {
    await saving.current
    await drafts.current.delete(DRAFT_KEY).catch(() => {})
    setLoaded(false) // so the cleared form isn't saved back over it
    setD(emptyPoll()); setLeaving(false)
    history.back()
  }

  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Posting…") : "Post"
  return (
    <main class="screen compose-sheet compose-poll">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2>New Poll</h2>
        <button type="submit" form="poll-form" class="compose-post" disabled={!canPost} aria-busy={busy || undefined}>{label}</button>
      </header>
      <ComposeKinds type="poll" />
      <form id="poll-form" class="kind-form" onSubmit={post}>
        <textarea class="kind-field poll-question" rows={2} placeholder="Ask a question" aria-label="Question" value={d.question} readOnly={busy}
          onInput={e => set({ question: e.currentTarget.value })}
          onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey) { e.preventDefault(); focusOption(0) } }} />

        <fieldset class="kind-group">
          <legend>Options</legend>
          <ol class="poll-options" ref={list}>
            {d.options.map((o, i) => (
              <li key={i} class="poll-option">
                <input type="text" class="kind-field" placeholder={`Option ${i + 1}`} aria-label={`Option ${i + 1}`} value={o} readOnly={busy} maxLength={200}
                  onInput={e => setOption(i, e.currentTarget.value)}
                  onKeyDown={e => {
                    if (e.key !== "Enter" || e.metaKey || e.ctrlKey) return
                    e.preventDefault()
                    if (i + 1 < d.options.length) focusOption(i + 1)
                    else addOption()
                  }} />
                {d.options.length > MIN_OPTIONS && <button type="button" class="poll-option-remove" aria-label={`Remove option ${i + 1}`} disabled={busy} onClick={() => removeOption(i)}>
                  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor" /><path d="M7.5 12h9" stroke="var(--s1)" stroke-width="2.4" stroke-linecap="round" /></svg>
                </button>}
              </li>
            ))}
          </ol>
          {d.options.length < MAX_OPTIONS && <button type="button" class="poll-add" disabled={busy} onClick={addOption}>
            <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor" /><path d="M12 7.5v9M7.5 12h9" stroke="var(--s1)" stroke-width="2.4" stroke-linecap="round" /></svg>
            Add option
          </button>}
          <p class="muted small kind-note" role="status">{hint ?? `At least two, up to ${MAX_OPTIONS}.`}</p>
        </fieldset>

        <div class="kind-row">
          <span class="kind-row-label" id="poll-pick-label">Voters can pick</span>
          <div class="seg-pill" role="radiogroup" aria-labelledby="poll-pick-label">
            <button type="button" role="radio" aria-checked={!d.multiple} class={d.multiple ? "" : "on"} onClick={() => set({ multiple: false })}>One</button>
            <button type="button" role="radio" aria-checked={d.multiple} class={d.multiple ? "on" : ""} onClick={() => set({ multiple: true })}>Any</button>
          </div>
        </div>

        <div class="kind-row">
          <label class="kind-row-label" for="poll-closes">Voting closes</label>
          <select id="poll-closes" class="kind-select" value={d.closes} disabled={busy}
            onChange={e => { const closes = e.currentTarget.value; set(closes === "custom" && d.closes !== "custom" ? { closes, customEnd: localInput(Date.now() + 86400e3) } : { closes }) }}>
            {CLOSING.map(([k, text]) => <option key={k} value={k}>{text}</option>)}
          </select>
        </div>
        {d.closes === "custom" && <div class="kind-row">
          <label class="kind-row-label" for="poll-end">Closes</label>
          <input id="poll-end" type="datetime-local" class="kind-select" value={d.customEnd} min={localInput(Date.now())} disabled={busy}
            onInput={e => set({ customEnd: e.currentTarget.value })} />
        </div>}
        <p class={closing ? "small kind-note poll-closing-hint" : "muted small kind-note"}>{closing ?? "Results show to everyone who has voted, and to all once voting closes."}</p>
        {loaded && hasPoll(d) && !result && <p class="muted small kind-note">Draft saved</p>}
      </form>
      {leaving && (
        <Dialog label="Save this poll as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this poll as a draft?</h3>
          <p class="muted small">Drafts stay in this browser.</p>
          <div class="mod-row compose-leave">
            <button type="button" class="primary" onClick={() => { setLeaving(false); history.back() }}>Save Draft</button>
            <button type="button" class="danger" onClick={discard}>Discard</button>
            <button type="button" onClick={() => setLeaving(false)}>Keep Editing</button>
          </div>
        </Dialog>
      )}
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}

// The article reader's Like / Comment / Zap bar (the iPhone's ArticleReaderView actionBar). Like is the notes' heart
// (shown at once, tapback, "Liked" pill: ReactionButton) with the article's like count beside it, your own like in it
// straight away. Zap is the notes' bolt, a tap opening the amounts with your default filled in (ArticleReaderView's
// zap sheet), and the Zapping pill.
// Comment opens a box under the bar that sends a NIP-22 comment, after the same send delay and Undo as Compose.
import { useEffect, useRef, useState } from "preact/hooks"
import { ReactionButton } from "../components/ReactionButton.jsx"
import { ZapButton } from "../components/ZapButton.jsx"
import { showToast } from "../components/Toast.jsx"
import { actionState, loadSent, myReaction, onActionState, publishAction } from "../net/actions.js"
import { sendDelaySeconds, startCountdown } from "../net/send-delay.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { commentTemplate, likeCount } from "./engagement.js"

const COMMENT_ICON = "M21 12a8 8 0 0 1-11.6 7.1L4 20.5l1.4-5A8 8 0 1 1 21 12z"
const compact = n => (n >= 1000 ? `${(n / 1000).toFixed(n < 10000 ? 1 : 0).replace(/\.0$/, "")}K` : String(n))

/** `likers`/`comments`: the tally's (null while loading). `onComment(event)`: a comment that went out, to show now. */
export function ArticleActionBar({ ctx, article, likers, comments, onComment }) {
  const [s, setS] = useState(() => actionState(article.id))
  const [writing, setWriting] = useState(false)
  useEffect(() => {
    setS(actionState(article.id))
    const off = onActionState(id => { if (id === article.id) setS(actionState(id)) })
    loadSent(ctx, article.id)
    return off
  }, [article.id])
  const off = ctx.signer?.readOnly ? READ_ONLY_SHORT : ""
  const likes = likers ? likeCount(likers, ctx.session.pubkey, myReaction(article.id)) : 0
  return (
    <>
      <div class="note-actions reader-action-bar" role="group" aria-label="Article actions">
        <span class="reader-action-count">
          <ReactionButton ctx={ctx} note={article} state={s.like} off={off} />
          {likes > 0 && <span class="reader-count" aria-label={`${likes} likes`}>{compact(likes)}</span>}
        </span>
        <span class="reader-action-count">
          <button type="button" class={`note-action comment${writing ? " sent" : ""}${off ? " off" : ""}`} aria-expanded={writing}
            aria-label={off ? `Comment. ${off}` : "Comment"} title={off || "Comment"} onClick={off ? undefined : () => setWriting(!writing)}>
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d={COMMENT_ICON} /></svg>
          </button>
          {comments > 0 && <span class="reader-count" aria-label={`${comments} comments`}>{compact(comments)}</span>}
        </span>
        <ZapButton note={article} pickFirst />
      </div>
      {writing && <CommentBox ctx={ctx} article={article} onSent={ev => { setWriting(false); onComment?.(ev) }} onCancel={() => setWriting(false)} />}
    </>
  )
}

/** Write a comment; Post waits out the send delay (Undo keeps the text), then signs and sends a NIP-22 comment. */
export function CommentBox({ ctx, article, onSent, onCancel }) {
  const [text, setText] = useState("")
  const [left, setLeft] = useState(0) // seconds of the countdown, 0 when not counting
  const [state, setState] = useState("") // "" | "sending" | an error
  const timer = useRef(null), box = useRef(null)
  useEffect(() => { box.current?.focus(); return () => timer.current?.cancel() }, [])
  const send = async () => {
    setLeft(0); setState("sending")
    try {
      const { event } = await publishAction(ctx, commentTemplate(article, text, ctx.account.relays.write[0] ?? ""))
      showToast({ key: "comment", message: "Commented", icon: "heart" })
      onSent(event)
    } catch (e) {
      setState(String(e?.message ?? e))
      showToast({ key: "comment", message: "Comment failed: no relay took it", tone: "error", icon: "warn" })
    }
  }
  const post = () => {
    if (!text.trim() || state === "sending" || left) return
    setState("")
    timer.current = startCountdown({ seconds: sendDelaySeconds(), onTick: setLeft, onDone: send })
  }
  const undo = () => { if (timer.current?.cancel()) setLeft(0) }
  const counting = left > 0
  return (
    <form class="reader-comment-box" onSubmit={e => { e.preventDefault(); post() }}>
      <textarea ref={box} value={text} rows={3} placeholder="Add a comment…" aria-label="Your comment" disabled={counting || state === "sending"}
        onInput={e => setText(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) post() }} />
      {state && state !== "sending" && <p class="muted small" role="alert">Didn't go out: {state}</p>}
      <div class="reader-comment-row">
        {counting
          ? <><span class="muted small">Commenting in {Math.max(1, Math.ceil(left))}s</span><button type="button" class="small" onClick={undo}>Undo</button></>
          : <><button type="button" class="small" onClick={onCancel} disabled={state === "sending"}>Cancel</button>
            <button type="submit" class="small primary" disabled={!text.trim() || state === "sending"}>{state === "sending" ? "Sending…" : "Post"}</button></>}
      </div>
    </form>
  )
}

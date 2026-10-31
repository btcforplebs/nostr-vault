// The iPhone's send delay (PendingPostManager): a post, reply or quote waits a few seconds before going out, with a
// countdown pill and Undo. Here nothing is signed until the countdown ends, so Undo leaves nothing signed or sent.

/** Settings › Send Delay's choices on the iPhone, in seconds. 0 = Off: no pill, no undo. */
export const SEND_DELAY_CHOICES = [0, 5, 10]
export const SEND_DELAY_DEFAULT = 5
export const SEND_DELAY_KEY = "post.sendDelaySeconds" // the iPhone's UserDefaults key

/** The user's delay, read fresh for each send; anything that isn't one of the choices is the default. */
export function sendDelaySeconds(storage = globalThis.localStorage) {
  const raw = storage?.getItem?.(SEND_DELAY_KEY)
  const n = raw == null || String(raw).trim() === "" ? NaN : Number(raw)
  return SEND_DELAY_CHOICES.includes(n) ? n : SEND_DELAY_DEFAULT
}

/** Settings › Send Delay: keeps `seconds` (one of the choices) where sendDelaySeconds reads it. */
export function setSendDelaySeconds(seconds, storage = globalThis.localStorage) {
  if (!SEND_DELAY_CHOICES.includes(seconds)) return
  try { storage?.setItem?.(SEND_DELAY_KEY, String(seconds)) } catch {}
}

/** The picker's footer, the iPhone's FeedSettingsView words. */
export const sendDelayNote = seconds => seconds === 0
  ? "Posts go out as soon as you tap. There's no undo."
  : `Posts wait ${seconds} seconds before going out, so you can undo or edit them.`

/** PendingPostManager.ActionType's words for the three the composer sends. */
export const SEND_ACTIONS = {
  newPost: { label: "Posting", done: "Posted" },
  reply: { label: "Replying", done: "Replied" },
  quote: { label: "Quoting", done: "Quoted" },
}
export const sendAction = target => (target?.mode === "reply" ? "reply" : target?.mode === "quote" ? "quote" : "newPost")

/** "Posting in 5s": whole seconds rounded up, never below 1 (PostActionPill). */
export const countdownText = (action, remaining) => `${SEND_ACTIONS[action].label} in ${Math.max(1, Math.ceil(remaining))}s`

const realClock = { now: () => Date.now(), every: (fn, ms) => setInterval(fn, ms), stop: id => clearInterval(id) }

/**
 * Counts `seconds` down, calling onTick(remaining) about every 100 ms, then onDone() once. cancel() before the end
 * means onDone never runs. With 0 seconds onDone runs straight away (Off: no countdown).
 * -> { cancel(): true if it stopped a countdown still running }
 */
export function startCountdown({ seconds, onTick = () => {}, onDone, clock = realClock }) {
  let finished = false
  if (!(seconds > 0)) { finished = true; onDone(); return { cancel: () => false } }
  const end = clock.now() + seconds * 1000
  const id = clock.every(() => {
    if (finished) return
    const left = Math.max(0, (end - clock.now()) / 1000)
    if (left > 0) return onTick(left)
    finished = true
    clock.stop(id)
    onDone()
  }, 100)
  return { cancel: () => { if (finished) return false; finished = true; clock.stop(id); return true } }
}

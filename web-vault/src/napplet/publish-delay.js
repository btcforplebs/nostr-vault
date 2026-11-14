// The send delay for napplets (plan §2: "send-delay / Undo moves into the shell's outbox publish policy, so every
// napplet gets it"). A post, reply, quote, comment or repost a napplet asks the shell to sign waits the user's Send
// Delay (Settings, net/send-delay.js) with the countdown pill and Undo, as the classic composer and repost button do.
// Nothing is signed until the countdown ends, so Undo leaves nothing signed or sent. Pure: the pill is shell-deps.js.
export const DELAYED_KINDS = new Set([1, 6, 16, 1111])

/** Which pill a template gets (send-delay.js SEND_ACTIONS): repost, quote, reply or newPost. */
export function delayActionOf(t) {
  if (t?.kind === 6 || t?.kind === 16) return "repost"
  const tags = t?.tags ?? []
  if (tags.some(x => x[0] === "q")) return "quote"
  if (t?.kind === 1111 || tags.some(x => x[0] === "e" && (x[3] === "root" || x[3] === "reply"))) return "reply"
  return "newPost"
}

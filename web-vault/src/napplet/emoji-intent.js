// Compose -> the Emoji napplet, by intent (plan P2). Compose isn't a napplet, so it joins the shell's bus as a
// participant of its own: it asks for archetype "emoji", action "pick"; the bus opens the handler (the Emoji napplet,
// mounted by ComposeEmoji.jsx) and delivers; picks come back on the INC topic "nv.emoji.picked". Pure: node tests
// drive it with a fake napplet.
export const EMOJI_TOPIC = "nv.emoji.picked"
export const EMOJI_INTENT = { archetype: "emoji", action: "pick" }
const SHORTCODE = /^[A-Za-z0-9_-]{1,64}$/

/** A pick as the napplet sent it -> { text, tag? } to put in the note, or null. A shortcode needs an https picture. */
export function pickedEmoji(payload) {
  if (!payload || typeof payload !== "object") return null
  if (typeof payload.emoji === "string") {
    const e = payload.emoji.trim()
    return e && e.length <= 16 && !/[\s<>]/.test(e) ? { text: e } : null
  }
  if (!SHORTCODE.test(payload.shortcode ?? "")) return null
  let u
  try { u = new URL(payload.url) } catch { return null }
  if (u.protocol !== "https:") return null
  return { text: `:${payload.shortcode}:`, tag: ["emoji", payload.shortcode, u.href] }
}

/**
 * bus: bus.js. open: () => Promise<napplet> (mounts the Emoji napplet and resolves once it can take a delivery).
 * onPick({ text, tag? }). -> { ask: () => Promise<result>, close }
 */
export function composeEmoji({ bus, open, onPick }) {
  const me = { dTag: "compose", send: m => { if (m?.type === "inc.event" && m.topic === EMOJI_TOPIC) { const p = pickedEmoji(m.payload); if (p) onPick(p) } } }
  bus.subscribe(me, EMOJI_TOPIC)
  const unregister = bus.register({ id: "nv-emoji", title: "Emoji", archetype: EMOJI_INTENT.archetype, actions: [EMOJI_INTENT.action], conventions: [], open })
  return {
    ask: () => bus.invoke(me, { ...EMOJI_INTENT }),
    close: () => { bus.forget(me); unregister() },
  }
}

/** The custom emoji tags a note keeps: one per shortcode still in its text (NIP-30). `emojis`: { shortcode: url }. */
export const emojiTags = (text, emojis = {}) =>
  Object.entries(emojis).filter(([code, url]) => SHORTCODE.test(code) && typeof url === "string" && String(text).includes(`:${code}:`)).map(([code, url]) => ["emoji", code, url])

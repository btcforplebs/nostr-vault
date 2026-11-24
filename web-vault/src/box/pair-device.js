// Box › My Devices › Add a device: what the pairing screen shows for each state the box reports (api-devices.js
// GET pair), as plain data. Pure, so test/box-pair-device.test.mjs can read every state; PairDeviceSection.jsx draws
// it. The words and the refusal lines come from the shared pairing code (net/mesh-pairing.js, mesh-pairing-words.js),
// so the box reads as the phone does (docs/MESH_PAIRING_CONTRACT.md §5, §7).
import { refusalText, shortAddress } from "../net/mesh-pairing.js"
import { WORDS } from "../net/mesh-pairing-words.js"

const ROLE = { mac: "Mac", phone: "phone", homeVault: "mobile vault", browser: "browser vault" }

/** The 4 check words for the box's word indexes, or null when they are not 4 indexes into the list. */
export function wordsOf(indexes) {
  if (!Array.isArray(indexes) || indexes.length !== 4 || indexes.some(i => !Number.isInteger(i) || i < 0 || i >= WORDS.length)) return null
  return indexes.map(i => WORDS[i])
}

/** Whole seconds left until `expiresAt` (unix s), never below 0. */
export const secondsLeft = (expiresAt, nowMs = Date.now()) => Math.max(0, Math.floor(expiresAt - nowMs / 1000))

/** What a refusal word the box reports means to the person: the shared line, or nothing for none. */
export function refusalLine(refusal, { otherRole = "" } = {}) {
  if (!refusal) return null
  if (refusal === "switchTo") return "That device belongs to another of your accounts. Sign in to the box as that account first."
  return refusalText(refusal, { role: otherRole }) ?? null
}

/**
 * The screen for a pairing status: `{ step, title, text, code?, words?, device?, confirmText?, role?, secondsLeft?,
 * canCancel, canStart, canConfirm?, error? }`. `step`: idle | waiting | hello | linked | failed | busy.
 */
export function pairView(status, nowMs = Date.now()) {
  const s = status ?? { state: "idle" }
  const refusal = refusalLine(s.refusal)
  const base = { canCancel: false, canStart: false, error: s.error || null }
  switch (s.state) {
    case "waiting":
      return { ...base, step: "waiting", title: "Scan this code with your phone",
        text: "On your phone: Profile › Mesh › My Devices › Add a device, then scan. Only show it to your own device.",
        code: s.code, secondsLeft: secondsLeft(s.expiresAt, nowMs), canCancel: true, refusal }
    case "hello": {
      const d = s.device ?? {}
      return { ...base, step: "hello", title: `${d.name?.trim() || "A device"} wants to pair`,
        text: `Check that your phone shows the same four words and ${shortAddress(s.box?.npub ?? "")}. Then tap They match on both.`,
        words: wordsOf(s.words), device: d, role: d.role, roleWord: ROLE[d.role] ?? "device",
        // No confirm without the words: there is nothing to check them against (Tron #2505).
        canConfirm: wordsOf(s.words) !== null,
        confirmText: s.confirmText, secondsLeft: secondsLeft(s.expiresAt, nowMs), canCancel: true, refusal }
    }
    case "linked": {
      const d = s.device ?? {}
      if (s.error || !(s.acked > 0)) return { ...base, step: "failed", title: "The phone did not get the answer",
        text: s.error || "No relay took the answer, so the phone will not link. Remove the device below and pair again.", device: d, canStart: true }
      return { ...base, step: "linked", title: `Linked ${d.name?.trim() || "the device"}`,
        text: "Tap They match on the phone too, then Add. The box keeps a copy of your vault from it.", device: d, canStart: true }
    }
    case "expired":
      return { ...base, step: "failed", title: "This code has expired. Show a new one.", text: s.error || "Nothing was added.", canStart: true }
    case "aborted":
      return { ...base, step: "failed", title: "Another device tried to use this code.", text: "Start again, and only show your code to your own device.", canStart: true }
    case "busy":
      return { ...base, step: "busy", title: "Another account is pairing a device", text: "Try again when it is done." }
    default:
      return { ...base, step: "idle", title: "Add a device", text: "Pair a phone, Mac or browser with this box. It then copies your vault from it over the mesh.", canStart: true }
  }
}

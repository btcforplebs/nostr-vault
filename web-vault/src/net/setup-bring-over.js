// First sign-in's import choice (plan §5a, lane E, as Logen moved it on 2026-11-05): Import from relays (today's
// setup), Import from a backup, or Copy from my other vault. This holds the rules for when the copy's link has worked,
// when it has failed and setup quietly goes on as today, the backup restore, and the words. The two scans themselves
// are lane C's pair-flow.js, used as it is (this browser scans the other device's code, or shows its own when it has no
// camera). Apart from Logen's small print under Copy, these screens never say mesh, FIPS, address or role.
import { displayName } from "./mesh-pairing.js"
import { importNotes } from "./backup.js"
import { parseBackup, restoreBackup } from "./settings.js"

/** How long the other device has to answer after this browser scanned it (or showed its code): the plan's 3 minutes. */
export const LINK_LIMIT = 180

export const QUESTION = "Bring in your notes"
export const RELAYS = "Import from relays"
export const RELAYS_DETAIL = "Fetch your notes and the people you follow from your relays."
export const BACKUP = "Import from a backup"
export const BACKUP_DETAIL = "A Nostr Vault backup file (.zip) from this browser, your iPhone or your Mac."
// Logen's words, 2026-11-05.
export const COPY = "Copy from my other vault"
export const COPY_DETAIL = "Your Mac or another device signed in as you. Scan two codes and it copies over the mesh."
export const FALLBACK = "Couldn't reach your other device; getting your notes from your relays instead."
export const linkedLine = name => `Linked with ${displayName(name)}. Getting your notes now.`

const FAILED = new Set(["expired", "aborted", "refused", "failed", "already"])

/** Where the setup goes from a pair-flow view: "wait", "linked", or "fallback" (no answer in 3 minutes, an abort, an
 *  expired or refused code). `since` is when this browser started waiting on the other device (its scan or its code);
 *  null while it is still looking for a code, which has no limit (the person may be fetching the other device). */
export function setupOutcome(view, since, now) {
  const step = view?.step
  if (step === "linked") return "linked"
  if (FAILED.has(step)) return step === "already" ? "linked" : "fallback"
  if (step === "confirm") return "wait" // the person is reading the confirm: never pulled from under them
  if (since != null && now - since > LINK_LIMIT) return "fallback"
  return "wait"
}

/** When the other device's 3 minutes start: the moment this browser scanned it or put its own code up. */
export const waitingSince = (view, prev, now) => (prev == null && (view?.step === "showBack" || view?.step === "showing") ? now : prev)

/** A pair-flow notice in these screens' words: the one refusal that names Mesh settings (a device already added as
 *  something else) is said without it. */
export const OTHER_KIND = "That device is already added here in another way. Import from relays, and link it later from Your devices."
export const setupNotice = text => (text && /mesh/i.test(text) ? OTHER_KIND : text ?? null)

const isZip = b => b.length >= 4 && b[0] === 0x50 && b[1] === 0x4b && b[2] === 3 && b[3] === 4
const plural = (n, one) => `${n.toLocaleString()} ${one}${n === 1 ? "" : "s"}`

/** Restores a backup file into the vault, as Settings › Backup does (components/BackupCard.jsx): the phone's .zip, or
 *  the older web .jsonl. Only this account's own signed events go in. -> the line for the steps screen. Throws a
 *  plain sentence when the file holds nothing to restore. */
export async function restoreSetupBackup({ vault, pubkey, bytes, onStatus = () => {}, zipImport = importNotes }) {
  if (isZip(bytes)) {
    const { counts, failed } = await zipImport({ vault, pubkey, bytes, onProgress: () => onStatus("Restoring your backup…") })
    const stored = Object.values(counts).reduce((n, c) => n + (typeof c === "number" ? c : c.stored), 0)
    if (!Object.keys(counts).length) throw new Error(failed?.length ? failed.join(" ") : "That .zip has no notes in it. Choose a Nostr Vault backup.")
    return `Restored ${plural(stored, "event")} from your backup. Getting the rest from your relays.`
  }
  const { events } = parseBackup(new TextDecoder().decode(bytes), pubkey)
  if (!events.length) throw new Error("That file has nothing of yours to restore. Choose a Nostr Vault backup.")
  const r = await restoreBackup(vault, events, { onProgress: p => onStatus(`Restoring ${p.done} of ${p.of}…`) })
  return `Restored ${plural(r.stored + r.duplicate, "event")} from your backup. Getting the rest from your relays.`
}

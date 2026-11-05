// First-run "Already using Nostr Vault on another device?" (plan §5a, lane E), the web's part: the rules for when the
// link has worked, when it has failed and setup quietly goes on as today, and the words. The two scans themselves are
// lane C's pair-flow.js, used as it is (this browser scans the other device's code, or shows its own when it has no
// camera). The words on these screens never say mesh, FIPS, address or role (Logen, 2026-11-04).
import { displayName } from "./mesh-pairing.js"

/** How long the other device has to answer after this browser scanned it (or showed its code): the plan's 3 minutes. */
export const LINK_LIMIT = 180

export const QUESTION = "Already using Nostr Vault on another device?"
export const YES = "Yes, bring it over"
export const YES_DETAIL = "Link this browser to it and copy your vault across."
export const NO = "No, start fresh"
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
export const OTHER_KIND = "That device is already added here in another way. Start fresh, and link it later from Your devices."
export const setupNotice = text => (text && /mesh/i.test(text) ? OTHER_KIND : text ?? null)

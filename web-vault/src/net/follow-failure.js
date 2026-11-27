// The reason a Follow / Unfollow tap shows when its kind 3 can't go out. Same wording as the iPhone app's follow banner
// (Tory's FollowPublishFailure, nv-apple 2026-11-27 10:19Z) and Android, so a user sees one reason on every platform.
// Every text says what stopped it and that nothing changed; "follow" reads "unfollow" for an unfollow tap.

/**
 * -> the banner text for `code`:
 *  - "relays": the lookup didn't hear from enough of the user's own write relays (follows.js editKnown);
 *    `answered`/`asked` are those counts. Every one answered (the single-relay edge) reads "not enough relays".
 *  - "noAnswer" / "oneAnswer": 0 or 1 of the user's own relays answered (2 are needed). Checked in this order, as iOS
 *    and Android: noOwnRelays, oneRelay, noAnswer, oneAnswer, then "relays" (2 or more answered, still no majority).
 *  - "oneRelay": the user's relay list names one relay and neither it nor purplepag.es answered (followListKnown).
 *  - "signer": the signer threw or returned nothing. "signerKey": it signed with another key.
 *  - "refused": no network relay took it. "vault": a relay took it but this browser's vault refused it.
 *  - "shrink": the result would drop most follows. "empty": it would publish an empty list.
 *  - "noOwnRelays", "notFound", "staleLocal", "signerChanged": `detail` is the guard's own sentence.
 */
export function followFailure(code, { follow = true, answered = 0, asked = 0, detail = "" } = {}) {
  const head = `Couldn't ${follow ? "follow" : "unfollow"}`
  switch (code) {
    case "relays":
      return answered < asked
        ? `${head}: only ${answered} of your ${asked} relays answered, so your newest follow list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again.`
        : `${head}: not enough relays answered, so your newest follow list can't be checked. Nothing changed. Try again in a moment.`
    case "oneRelay": return `${head}: your relay list has only one relay, and your newest follow list needs two of your relays to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again.`
    case "noAnswer": return `${head}: no relay answered, so your newest follow list can't be checked. Nothing changed. Check your connection, then try again.`
    case "oneAnswer": return `${head}: only 1 relay answered, and it takes 2 to check your newest follow list. Nothing changed. Try again in a moment.`
    case "signer": return `${head}: your signer didn't sign it. Nothing changed. Check your signer, then try again.`
    case "signerKey": return `${head}: your signer signed with a different key. Nothing changed. Check which account your signer is on.`
    case "refused": return `${head}: every relay refused it. Nothing changed. Check your relays in Settings › Relays.`
    case "shrink": return `${head}: the new list would have less than half the people of your last one, so it was stopped to protect your follows. Nothing changed.`
    case "empty": return `${head}: it would publish an empty follow list, so it was stopped. Nothing changed.`
    case "vault": return `${head}: a relay took it, but this browser's vault refused it${detail ? ` (${detail})` : ""}. Try again.`
    default: return detail ? `${head}. ${detail}` : `${head}. Nothing changed. Try again.`
  }
}

/** An Error carrying `code` (tests and callers can tell the exits apart without matching text). */
export const followError = (code, opts) => Object.assign(new Error(followFailure(code, opts)), { code, fixed: true })

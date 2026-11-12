// Box › Public on the web (Logen 2026-11-12): the advanced last step for a Linux vault, as the Mac's switch. Off, the
// box is reached by your own devices over the mesh and listed nowhere by its web address. On, its domain (NV_RELAY_URL,
// GET status relay_url) goes in your relay list (kind 10002, unmarked: read and write) and its /inbox in your DM inbox
// list (kind 10050), first. The box holds no account key, so this page signs and publishes them (list-edit.js
// publishList: safe-save, only on a tap). The fipsmesh entry under Media Servers › Your Vaults is a separate opt-in.
// Pure: tags in, tags out.
import { relayKey } from "../net/own-relays.js"
import { isPublicRelay } from "../net/never-connect.js"

/** The box's web address as a relay: wss://host, or null when it has none or nobody else could reach it. */
export function boxRelay(relayUrl) {
  const raw = String(relayUrl ?? "").trim().replace(/^https?:\/\//i, "").replace(/\/+$/, "")
  if (!raw || raw.includes("://")) return null
  const url = relayKey(`wss://${raw}`)
  return url && isPublicRelay(url) ? url : null
}

/** Its DM inbox: wss://host/inbox. */
export const boxInbox = relay => relay ? `${relay}/inbox` : null

/** Whether `url` is in the list's `name` tags ("r" for 10002, "relay" for 10050), however it is spelled. */
export function listed(tags, name, url) {
  const k = relayKey(url)
  return !!k && (tags ?? []).some(t => t[0] === name && relayKey(t[1]) === k)
}

/** The list with `url` in (first, unmarked) or out (every spelling), the other tags untouched. */
export function withRelay(tags, name, url, on) {
  const k = relayKey(url)
  const rest = (tags ?? []).filter(t => !(t[0] === name && relayKey(t[1]) === k))
  return on ? [[name, url], ...rest] : rest
}

/**
 * List (`next` true) or unlist the box: your 10002 first, then your 10050, each only when it would change (never an
 * empty list signed for nothing). `state`: { relays, inbox } from latestList. `publish`: list-edit.js publishList.
 * -> which kinds were published; throws what publishList throws (nothing signed for that list).
 */
export async function setListed(ctx, relay, next, state, publish) {
  const done = []
  const relaysTags = state.relays.event?.tags ?? []
  if (listed(relaysTags, "r", relay) !== next) {
    await publish(ctx, 10002, withRelay(relaysTags, "r", relay, next), { previous: state.relays.event })
    done.push(10002)
  }
  const inbox = boxInbox(relay), inboxTags = state.inbox.event?.tags ?? []
  if (listed(inboxTags, "relay", inbox) !== next) {
    await publish(ctx, 10050, withRelay(inboxTags, "relay", inbox, next), { previous: state.inbox.event })
    done.push(10050)
  }
  return done
}

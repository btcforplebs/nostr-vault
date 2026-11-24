// Box › Public on the web (Logen 2026-11-12): the advanced last step for a Linux vault, as the Mac's switch. Off, the
// box is reached by your own devices over the mesh and listed nowhere by its web address. On, its domain (NV_RELAY_URL,
// GET status relay_url) goes in your relay list (kind 10002, unmarked: read and write) and its /inbox in your DM inbox
// list (kind 10050). The box holds no account key, so this page signs and publishes them (list-edit.js publishList:
// safe-save, only on a tap). The fipsmesh entry under Media Servers › Your Vaults is a separate opt-in.
//
// Where the entry goes and when a change is refused follow the Desktop Vaults rules every app shares
// (desktop-vault-lists.js, plan §2.5: after the other Vaults' entries, before your own relays, never newest-first; a
// list left without a usable relay is refused with nothing signed). Here the box is the one Vault this page knows.
// Pure: tags in, tags out.
import { relayKey } from "../net/own-relays.js"
import { isPublicRelay } from "../net/never-connect.js"
import { base, isListed, refusal, turningOff, turningOn } from "./desktop-vault-lists.js"

/** The box's web address as a relay: wss://host, or null when it has none or nobody else could reach it. */
export function boxRelay(relayUrl) {
  const raw = String(relayUrl ?? "").trim().replace(/^https?:\/\//i, "").replace(/\/+$/, "")
  if (!raw || raw.includes("://")) return null
  const url = relayKey(`wss://${raw}`)
  return url && isPublicRelay(url) ? url : null
}

/** Its DM inbox: wss://host/inbox. */
export const boxInbox = relay => relay ? `${relay}/inbox` : null

/** The box as a Desktop Vault for the shared list rules: kind box, HTTPS only, first in order. */
export const boxVault = relay => ({ id: `https:${base(relay)}`, name: "", kind: "box", httpsURL: `https://${base(relay)}`, order: 0 })

/** Whether `url` is in the list's `name` tags ("r" for 10002, "relay" for 10050), however it is spelled. */
export function listed(tags, name, url) {
  const list = name === "r" ? 10002 : 10050
  return isListed(boxVault(url.replace(/\/inbox$/, "")), "web", list, tags ?? [])
}

/** The list with the box in or out by the shared rules: `{ tags }`, or `{ refused }` when the list would be left
 *  without a usable relay. `url` is the relay for 10002 or its /inbox for 10050. */
export function withRelay(tags, name, url, on) {
  const list = name === "r" ? 10002 : 10050
  const vault = boxVault(url.replace(/\/inbox$/, ""))
  return on ? turningOn(vault, "web", list, tags ?? [], [vault]) : turningOff(vault, "web", list, tags ?? [])
}

/**
 * List (`next` true) or unlist the box: your 10002 first, then your 10050, each only when it would change (never an
 * empty list signed for nothing). `state`: { relays, inbox } from latestList. `publish`: list-edit.js publishList.
 * -> which kinds were published; throws what publishList throws (nothing signed for that list).
 */
export async function setListed(ctx, relay, next, state, publish) {
  const relaysTags = state.relays.event?.tags ?? [], inbox = boxInbox(relay), inboxTags = state.inbox.event?.tags ?? []
  const steps = [
    { kind: 10002, name: "r", url: relay, tags: relaysTags, previous: state.relays.event, what: "relay list" },
    { kind: 10050, name: "relay", url: inbox, tags: inboxTags, previous: state.inbox.event, what: "DM inbox" },
  ].filter(s => listed(s.tags, s.name, s.url) !== next).map(s => ({ ...s, change: withRelay(s.tags, s.name, s.url, next) }))
  // Checked for both lists before either is signed, so a refusal never leaves one moved and the other behind
  // (Tron #1991): a list with no relay left means nobody can find your relays or reach your DMs.
  const empty = steps.find(s => s.change.refused)
  if (empty) throw new Error(`Not changed: this box is the only relay in your ${empty.what}, so unlisting it would leave the list empty. ${refusal(empty.change.refused)}`)
  const done = []
  for (const s of steps) {
    await publish(ctx, s.kind, s.change.tags, { previous: s.previous })
    done.push(s.kind)
  }
  return done
}

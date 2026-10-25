// What a brand-new account publishes when it finishes Create an account (screens/CreateAccount.jsx), as the iPhone's
// SetupWizardView.publishNewAccount and republishDMRelayLists do: a relay list (kind 10002), where to send it messages
// (kind 10050), its profile (kind 0, only with a name or photo) and its first follows (kind 3, the people it picked).
// Nothing is built or sent before the last step: the key was made in this run, so it cannot have any of these events
// yet, and a kind 3 here can't wipe an older list (net/follows.js guards lists that may exist elsewhere).
import { decode } from "nostr-tools/nip19"
import { DEFAULT_RELAYS, BROADCAST_RELAYS, pool, publishRelays, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"
import { firstTaken } from "./actions.js"
import packsData from "./starter-packs.js"

const HEX = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)
const wss = url => { try { const u = new URL(url); return u.protocol === "wss:" && !["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].includes(u.hostname) } catch { return false } }

/** The relays a new account reads and writes: the app's defaults and its broadcast relays, wss only, once each
 *  (RelayConfiguration.newAccountRelayListTags). */
export const NEW_ACCOUNT_RELAYS = uniq([...DEFAULT_RELAYS, ...BROADCAST_RELAYS].map(u => u.trim().replace(/\/+$/, ""))).filter(wss)

/** The starter packs (the iPhone's starter_packs.json), each account with its hex pubkey; bad npubs are dropped
 *  (StarterPacksData.validated). `on`: picked at first, and listed first. The Bitcoin pack starts unpicked, at the end: the feed leads with people. */
export function starterPacks(data = packsData) {
  return (data?.packs ?? []).map(p => ({
    id: p.id, name: p.name, description: p.description, on: p.id !== "bitcoin",
    accounts: (p.accounts ?? []).flatMap(a => {
      try { const d = decode(a.npub); return d.type === "npub" && HEX.test(d.data) ? [{ ...a, pubkey: d.data }] : [] } catch { return [] }
    }),
  })).filter(p => p.accounts.length).sort((a, b) => b.on - a.on) // the picked packs first
}

/** The kind 0 content: name and display_name from the name, picture when one was uploaded; null when there is nothing. */
export function profileContent(name, picture) {
  const n = (name ?? "").trim()
  const p = {}
  if (n) { p.name = n; p.display_name = n }
  if (picture) p.picture = picture
  return Object.keys(p).length ? JSON.stringify(p) : null
}

/** The unsigned events, in the order they're published. `follows`: hex pubkeys. */
export function newAccountTemplates({ name, picture, follows, relays = NEW_ACCOUNT_RELAYS, at = now() }) {
  const out = [
    { kind: 10002, created_at: at, content: "", tags: relays.map(r => ["r", r]) },
    { kind: 10050, created_at: at, content: "", tags: DEFAULT_RELAYS.filter(wss).map(r => ["relay", r]) },
  ]
  const content = profileContent(name, picture)
  if (content) out.push({ kind: 0, created_at: at, content, tags: [] })
  const people = uniq((follows ?? []).filter(pk => HEX.test(pk)))
  if (people.length) out.push({ kind: 3, created_at: at, content: "", tags: people.map(pk => ["p", pk]) })
  return out
}

/** Sign each template with `signer` (checked as every post is) -> the events. */
export async function signAll(signer, pubkey, templates) {
  const out = []
  for (const t of templates) out.push(checkSigned(await signer.signEvent(t), t, pubkey))
  return out
}

/** Send the events to the network relays. Done once one relay took each (or every relay refused it), not at the
 *  slowest relay's answer, which held Start Exploring for 5 s; the other sends carry on in the background while the
 *  page is open. The page's own relay gets them as the app starts (main.jsx writes them into Haven's outbox; the web
 *  Haven has no blastr relays, so it doesn't send them on). -> [{ kind, taken, of, settled: Promise<how many took it> }] */
export async function publishNewAccount(events, { publish = (urls, ev) => pool.publish(urls, ev), relays = NEW_ACCOUNT_RELAYS } = {}) {
  const { network } = publishRelays(relays)
  return Promise.all(events.map(async ev => {
    const sends = publish(network, ev)
    const settled = Promise.allSettled(sends).then(results => results.filter(r => r.status === "fulfilled").length)
    return { kind: ev.kind, taken: (await firstTaken(sends)) >= 0, of: network.length, settled }
  }))
}

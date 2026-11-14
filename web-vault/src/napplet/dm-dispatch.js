// NAP-DM for napplets (plan P7, napplet/naps NAP-DM draft): the Messages napplet reads and sends the user's direct
// messages through the shell's own DM stack (net/dms.js). Keys, decryption, NIP-42 AUTH and NIP-17 sealing and gift
// wrapping all stay here; a napplet only ever sees decrypted text it was allowed to see, and never an event, a wrap or
// a key. Pure apart from `deps`, so node tests drive it with fakes.
//   dm.status          -> { available, ownerPubkey, implementations, capabilities }
//   dm.conversations   -> newest first, blocked people out, { id: peer pubkey, participants, unread, updatedAt } plus
//                         our extensions `request` (a stranger's: the classic Requests list) and `last` (preview)
//   dm.messages        -> one conversation, oldest first, a page from the newest end; reading it marks it read
//   dm.send            -> one recipient (NIP-17 direct; no groups yet), through sendMessage
//   dm.subscribe/unsubscribe, and dm.message pushed for each new message after the subscription began
// Logen's decision 2: DMs are vault-private. An outside napplet needs the private-data grant to read anything, and is
// asked before each send, shown who it goes to and what it says. Ours (first-party) is the Messages screen itself.
import { seesPrivate } from "./policy.js"
import { conversations, threadShown } from "../net/dms.js"
import { splitConversations } from "../net/dm-trust.js"

const HEX = /^[0-9a-f]{64}$/
export const PAGE = 50, MAX_PAGE = 200, MAX_TEXT = 20000, MAX_DM_SUBS = 4

export const statusOf = m => (m.failed ? "failed" : m.pending ? "sent" : null)
/** A message as NAP-DM has it. */
export const dmMessage = (m, me) => ({
  id: m.id, conversationId: m.peer, senderPubkey: m.from, createdAt: m.at, content: String(m.content ?? ""),
  status: m.failed ? "failed" : m.from === me ? "sent" : "received",
})
const page = (n, fallback = PAGE) => Math.min(Number.isInteger(n) && n > 0 ? n : fallback, MAX_PAGE)
const offset = c => { const n = Number(c); return Number.isInteger(n) && n >= 0 ? n : 0 }

/**
 * deps: { me, messages() -> Map, blocked() -> Set, trusted() -> Set, unread(messages) -> Map peer -> n,
 * profile(pk) -> { name, picture } | null, onChange(cb) -> off, send(peer, text) -> Promise<message>,
 * markRead(list), ask({ napplet, what, detail }) -> bool, randomId() }
 */
export function dmHandler({ grant, who, deps, push }) {
  const subs = new Map() // subscriptionId -> { conversationId, seen: Set, off }
  const priv = seesPrivate(grant)
  const out = (m, body) => ({ type: `${m.type}.result`, id: m.id, ...body })
  const refuse = (m, error) => out(m, { error })

  function conversationsPage(m) {
    const all = deps.messages(), blocked = deps.blocked()
    const list = conversations(all, blocked)
    const { requests } = splitConversations(list, all, deps.me, deps.trusted())
    const isRequest = new Set(requests.map(c => c.peer))
    const unread = deps.unread(all)
    const at = offset(m.cursor), n = page(m.limit)
    const rows = list.slice(at, at + n).map(c => {
      const p = deps.profile(c.peer)
      return {
        id: c.peer, kind: "direct", participants: [{ pubkey: c.peer, ...(p?.name ? { label: String(p.name).slice(0, 80) } : {}), ...(/^https:\/\//i.test(p?.picture ?? "") ? { avatar: p.picture } : {}) }],
        unread: unread.get(c.peer) ?? 0, updatedAt: c.last.at,
        request: isRequest.has(c.peer), last: { content: String(c.last.content ?? "").slice(0, 160), senderPubkey: c.last.from, createdAt: c.last.at },
      }
    })
    return out(m, { conversations: rows, ...(at + n < list.length ? { cursor: String(at + n) } : {}) })
  }

  function messagesPage(m) {
    if (!HEX.test(m.conversationId ?? "")) return refuse(m, "unknown conversation")
    const list = threadShown(deps.messages(), m.conversationId, { blocked: deps.blocked(), me: deps.me })
    const from = offset(m.cursor), n = page(m.limit)
    const end = list.length - from, start = Math.max(0, end - n)
    const slice = list.slice(start, end)
    if (!from) deps.markRead(list)
    return out(m, { messages: slice.map(x => dmMessage(x, deps.me)), ...(start > 0 ? { cursor: String(from + n) } : {}) })
  }

  async function send(m) {
    const to = Array.isArray(m.recipients) ? [...new Set(m.recipients)] : []
    if (to.length !== 1 || !HEX.test(to[0])) return refuse(m, "one recipient (a hex pubkey); groups aren't supported yet")
    if (m.conversationId !== undefined && m.conversationId !== to[0]) return refuse(m, "conversationId must be the recipient")
    const text = typeof m.content === "string" ? m.content.trim() : ""
    if (!text || text.length > MAX_TEXT) return refuse(m, "a message needs text, at most 20000 characters")
    if (deps.blocked().has(to[0])) return refuse(m, "you blocked them")
    if (!grant.firstParty && !(await deps.ask({ napplet: who, what: "dm-send", detail: { to: to[0], name: deps.profile(to[0])?.name ?? "", content: text } })))
      return out(m, { ok: false, message: { id: `refused:${deps.randomId()}`, conversationId: to[0], senderPubkey: deps.me, createdAt: Math.floor(Date.now() / 1000), content: text, status: "failed" }, error: "the user said no" })
    try {
      const sent = await deps.send(to[0], text)
      return out(m, { ok: true, message: dmMessage(sent, deps.me) })
    } catch (e) {
      return out(m, { ok: false, message: { id: e?.failedId ?? `failed:${deps.randomId()}`, conversationId: to[0], senderPubkey: deps.me, createdAt: Math.floor(Date.now() / 1000), content: text, status: "failed" }, error: String(e?.message ?? e) })
    }
  }

  function subscribe(m) {
    if (subs.size >= MAX_DM_SUBS) return refuse(m, `at most ${MAX_DM_SUBS} subscriptions`)
    if (m.conversationId !== undefined && !HEX.test(m.conversationId)) return refuse(m, "unknown conversation")
    const subscriptionId = deps.randomId()
    const seen = new Set(deps.messages().keys())
    const off = deps.onChange(() => {
      const blocked = deps.blocked()
      for (const [id, msg] of deps.messages()) {
        if (seen.has(id)) continue
        seen.add(id)
        if (msg.pending || (m.conversationId && msg.peer !== m.conversationId) || (blocked.has(msg.peer) && msg.from !== deps.me)) continue
        push({ type: "dm.message", subscriptionId, message: dmMessage(msg, deps.me) })
      }
    })
    subs.set(subscriptionId, { off })
    return out(m, { subscriptionId })
  }

  const handle = async m => {
    if (typeof m?.type !== "string" || typeof m.id !== "string") return undefined
    switch (m.type) {
      case "dm.status":
        return out(m, { available: priv, ...(priv ? { ownerPubkey: deps.me } : {}), implementations: priv ? ["nip17", "nip04-read"] : [], capabilities: priv ? ["conversations", "messages", "send", "subscribe"] : [] })
      case "dm.conversations": return priv ? conversationsPage(m) : refuse(m, "private: no private-data grant")
      case "dm.messages": return priv ? messagesPage(m) : refuse(m, "private: no private-data grant")
      case "dm.send": return priv ? send(m) : refuse(m, "private: no private-data grant")
      case "dm.subscribe": return priv ? subscribe(m) : refuse(m, "private: no private-data grant")
      case "dm.unsubscribe": { const s = subs.get(m.subscriptionId); s?.off(); subs.delete(m.subscriptionId); return out(m, { ok: !!s }) }
      default: return refuse(m, "unsupported")
    }
  }
  const close = () => { for (const s of subs.values()) try { s.off() } catch {} subs.clear() }
  return { handle, close }
}

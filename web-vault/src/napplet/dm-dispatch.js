// NAP-DM for napplets (plan P7, napplet/naps NAP-DM draft): the Messages napplet reads and sends the user's direct
// messages through the shell's own DM stack (net/dms.js). Keys, decryption, NIP-42 AUTH and NIP-17 sealing and gift
// wrapping all stay here; a napplet only ever sees decrypted text it was allowed to see, and never an event, a wrap or
// a key. Pure apart from `deps`, so node tests drive it with fakes.
//   dm.status          -> { available, ownerPubkey, implementations, capabilities }
//   dm.conversations   -> newest first, blocked people out, { id: peer pubkey, participants, unread, updatedAt } plus
//                         our extensions `request` (a stranger's: the classic Requests list), `last` (preview) and
//                         `follows` (you follow them: their photos load without a tap, as on the classic thread).
//                         Our query extensions: `query` (the classic on-device search, net/dm-search.js: names and
//                         message text, nothing asked of a relay; a row's `hit` is the newest matching message) and
//                         `ids` (these people's rows even with no message yet: a brand-new conversation's name).
//   dm.messages        -> one conversation, oldest first, a page from the newest end; reading it marks it read
//   dm.send            -> one recipient (NIP-17 direct; no groups, as on the classic page), through sendMessage. Our
//                         extension `photo` (a Blob): the shell redraws it without its metadata, uploads it to your
//                         media servers and sends its link after the text, the classic thread's own path (dm-photo.js).
//   dm.subscribe/unsubscribe, and dm.message pushed for each new message after the subscription began
// DMs are vault-private: only our own (first-party) napplet, the Messages screen itself, reads or sends them. An outside
// napplet gets nothing, whatever it was granted (Logen, 2026-11-14). The ask before a send stays as a second wall.
import { seesPrivate } from "./policy.js"
import { conversations, threadShown } from "../net/dms.js"
import { splitConversations } from "../net/dm-trust.js"
import { searchChats } from "../net/dm-search.js"

const HEX = /^[0-9a-f]{64}$/
export const PAGE = 50, MAX_PAGE = 200, MAX_TEXT = 20000, MAX_DM_SUBS = 4, MAX_QUERY = 200, MAX_IDS = 20
export const MAX_PHOTO = 50 * 1024 * 1024 // a picked photo before it's redrawn; what goes up is far smaller

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
 * profile(pk) -> { name, picture } | null, searchName(pk) -> text, follows(pk) -> bool, lookup(pks) (fetch names),
 * onChange(cb) -> off, send(peer, text, photo?) -> Promise<message>, markRead(list), ask({ napplet, what, detail }) -> bool,
 * randomId() }
 */
export function dmHandler({ grant, who, deps, push }) {
  const subs = new Map() // subscriptionId -> { conversationId, seen: Set, off }
  const priv = seesPrivate(grant)
  const out = (m, body) => ({ type: `${m.type}.result`, id: m.id, ...body })
  const refuse = (m, error) => out(m, { error })

  const participant = pk => {
    const p = deps.profile(pk)
    return { pubkey: pk, ...(p?.name ? { label: String(p.name).slice(0, 80) } : {}), ...(/^https:\/\//i.test(p?.picture ?? "") ? { avatar: p.picture } : {}) }
  }
  const line = x => ({ content: String(x.content ?? "").slice(0, 160), senderPubkey: x.from, createdAt: x.at })

  function conversationsPage(m) {
    if (m.query !== undefined && (typeof m.query !== "string" || m.query.length > MAX_QUERY)) return refuse(m, `query: text, at most ${MAX_QUERY} characters`)
    if (m.ids !== undefined && (!Array.isArray(m.ids) || m.ids.length > MAX_IDS || !m.ids.every(x => HEX.test(x ?? "")))) return refuse(m, `ids: at most ${MAX_IDS} hex pubkeys`)
    const all = deps.messages(), blocked = deps.blocked()
    const list = conversations(all, blocked)
    const { requests } = splitConversations(list, all, deps.me, deps.trusted())
    const isRequest = new Set(requests.map(c => c.peer))
    const unread = deps.unread(all)
    const row = c => ({
      id: c.peer, kind: "direct", participants: [participant(c.peer)],
      unread: unread.get(c.peer) ?? 0, updatedAt: c.last?.at ?? 0,
      request: isRequest.has(c.peer), follows: !!deps.follows(c.peer), last: c.last ? line(c.last) : null,
      ...(c.hit ? { hit: line(c.hit) } : {}),
    })
    // These people, with or without messages (a new conversation's name and face); a blocked one isn't offered.
    if (m.ids) {
      const ids = [...new Set(m.ids)].filter(pk => !blocked.has(pk))
      const unnamed = ids.filter(pk => !deps.profile(pk)?.name)
      if (unnamed.length) deps.lookup(unnamed)
      const by = new Map(list.map(c => [c.peer, c]))
      return out(m, { conversations: ids.map(pk => row(by.get(pk) ?? { peer: pk, last: null })) })
    }
    const shown = m.query ? searchChats(list, all, m.query, deps.searchName) : list
    const at = offset(m.cursor), n = page(m.limit)
    return out(m, { conversations: shown.slice(at, at + n).map(row), ...(at + n < shown.length ? { cursor: String(at + n) } : {}) })
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
    const photo = m.photo ?? null
    if (photo !== null && !(photo instanceof Blob && photo.size > 0 && photo.size <= MAX_PHOTO && (!photo.type || /^image\//.test(photo.type)))) return refuse(m, "photo: one image, at most 50 MB")
    if ((!text && !photo) || text.length > MAX_TEXT) return refuse(m, "a message needs text or a photo, text at most 20000 characters")
    if (deps.blocked().has(to[0])) return refuse(m, "you blocked them")
    const shownText = photo ? (text ? `${text}\n(photo)` : "(photo)") : text // as the classic thread shows one in flight
    if (!grant.firstParty && !(await deps.ask({ napplet: who, what: "dm-send", detail: { to: to[0], name: deps.profile(to[0])?.name ?? "", content: shownText } })))
      return out(m, { ok: false, message: { id: `refused:${deps.randomId()}`, conversationId: to[0], senderPubkey: deps.me, createdAt: Math.floor(Date.now() / 1000), content: shownText, status: "failed" }, error: "the user said no" })
    try {
      const sent = await deps.send(to[0], text, photo)
      return out(m, { ok: true, message: dmMessage(sent, deps.me) })
    } catch (e) {
      return out(m, { ok: false, message: { id: e?.failedId ?? `failed:${deps.randomId()}`, conversationId: to[0], senderPubkey: deps.me, createdAt: Math.floor(Date.now() / 1000), content: shownText, status: "failed" }, error: String(e?.message ?? e) })
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
      case "dm.conversations": return priv ? conversationsPage(m) : refuse(m, "private: only Nostr Vault's own napplets")
      case "dm.messages": return priv ? messagesPage(m) : refuse(m, "private: only Nostr Vault's own napplets")
      case "dm.send": return priv ? send(m) : refuse(m, "private: only Nostr Vault's own napplets")
      case "dm.subscribe": return priv ? subscribe(m) : refuse(m, "private: only Nostr Vault's own napplets")
      case "dm.unsubscribe": { const s = subs.get(m.subscriptionId); s?.off(); subs.delete(m.subscriptionId); return out(m, { ok: !!s }) }
      default: return refuse(m, "unsupported")
    }
  }
  const close = () => { for (const s of subs.values()) try { s.off() } catch {} subs.clear() }
  return { handle, close }
}

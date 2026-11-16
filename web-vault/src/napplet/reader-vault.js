// The Vault in the Reader (plan NV_WEB_ONE_PLAN.md step 8a): the shell reads it with the Vault screen's own rules
// (screens/VaultScreen.jsx useVault: Haven's outbox and inbox, the relays, kind 3 followers, checked zap receipts, each
// mode's "new" dot, older pages from Haven, kept between visits) and hands the Reader the mode on screen: your notes,
// articles and highlights as the signed events it draws as cards, the other lines as plain strings. A click hands back
// a row's id; the shell opens what it kept. Media stays the Media napplet's page (the shell routes there).
//   napplet:vault/state {}                -> { data } (vaultAnswer)
//   napplet:vault/mode { mode } / vault/filter { id } / vault/more {} / vault/open { id } / vault/dashboard {}
//   napplet:vault/find { text, now? }     -> the Vault's search (step 8b, VaultSearch.jsx useVaultSearch: this browser's
//                                            relay only); its results come in vault/state as `search`, opened by id
// A change comes as inc nv.vault.changed. The Reader's only.
import { READER_DTAG as READER } from "./first-party-list.js"
import { MODES, FILTERS, CLEARABLE, ALL_TITLE, previewOf, cutPreview } from "../net/vault-lists.js"
import { SECTIONS } from "../net/vault-search.js"

export const VAULT_TOPIC = "nv.vault.changed"
export const EVENT_MODES = new Set(["notes", "articles", "highlights"])
const https = v => (/^https:\/\//i.test(v ?? "") ? String(v).slice(0, 2048) : "")
const nameOf = p => String(p?.display_name || p?.name || "").slice(0, 80)
const cut = s => cutPreview(s) // never inside a nostr: reference, so the Reader can name the person
const ago = (at, now) => { const s = Math.max(0, now - at); return s < 3600 ? `${Math.max(1, Math.floor(s / 60))}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d` }

/** "Nothing here" for a mode and filter, in the screen's words (VaultScreen.jsx List). */
export function emptyText(mode, filter, followersCount = 0) {
  switch (mode) {
    case "activity": return filter === "outside" ? "Nothing from outside your web tags you. Replies and mentions from people outside it would land here." : filter === "mentions" ? "No replies, mentions or quotes yet." : "Nothing has come in yet. Replies, likes, zaps, reposts and new followers land here."
    case "notes": return filter === "tagged" ? "No notes tag you yet." : "No notes yet."
    case "articles": return filter === "recipes" ? "No recipes found. Recipes are articles tagged zapcooking or nostrcooking." : "Long-form posts you write or are tagged in land here."
    case "highlights": return "No highlights yet."
    case "likes": return filter === "given" ? "You haven't liked anything from here yet." : "No likes on your notes yet."
    case "zaps": return filter === "given" ? "No zaps you paid were found on your relays." : "No zaps on your notes yet."
    case "followers": return filter === "outside" ? "No followers from outside your web." : followersCount ? "No followers in your web yet. The filter lists the ones outside it." : "No followers found on your relays yet."
    default: return ""
  }
}

/** Rows in one search section, as the screen's SECTION_CAP (VaultSearch.jsx). */
export const SEARCH_CAP = 200
const TAG = /^[\p{L}\p{N}_]{1,64}$/u
const HEX = /^[0-9a-f]{64}$/
const hostOf = url => { try { return new URL(url).hostname } catch { return "" } }

/**
 * The Vault search (useVaultSearch's { text, found, busy }) -> { data, routes }: people as strings (a picture only from
 * someone you trust, `trusted`), notes, articles and media as the signed events, hashtags and links as strings. A person
 * opens their profile, a hashtag its feed, a link's note its thread, each by an id handed out here. `h`: { profileOf, npubOf }.
 */
export function vaultSearchAnswer(s, trusted, h, routes = new Map()) {
  const text = String(s?.text ?? "")
  const f = s?.found
  const data = { text, busy: !!s?.busy, short: text.trim().length === 1, query: f ? String(f.query) : "", cut: !!f?.cut, sections: null }
  if (!f) return { data, routes }
  data.sections = SECTIONS.map(sec => {
    const all = f[sec.id] ?? []
    let kind = "events", rows
    if (sec.id === "people") {
      kind = "people"
      rows = all.filter(pk => HEX.test(pk)).slice(0, SEARCH_CAP).map(pk => {
        routes.set(pk, `#/profile/${pk}`)
        const p = h.profileOf(pk), npub = h.npubOf(pk), nip05 = typeof p?.nip05 === "string" ? p.nip05.replace(/^_@/, "") : ""
        return { id: pk, name: nameOf(p) || `${npub.slice(0, 16)}…`, sub: String(nip05 || `${npub.slice(0, 12)}…${npub.slice(-6)}`).slice(0, 120), about: typeof p?.about === "string" ? cut(p.about.trim()) : "", picture: trusted(pk) ? https(p?.picture) : "" }
      })
    } else if (sec.id === "hashtags") {
      kind = "tags"
      rows = all.filter(t => TAG.test(t)).slice(0, SEARCH_CAP).map(t => { routes.set(`tag:${t}`, `#/feed?tag=${encodeURIComponent(t.toLowerCase())}`); return { id: `tag:${t}`, tag: t } })
    } else if (sec.id === "links") {
      kind = "links"
      rows = all.filter(l => /^https?:\/\//i.test(l?.url ?? "")).slice(0, SEARCH_CAP).map(l => {
        const note = HEX.test(l.noteId ?? "") ? `note:${l.noteId}` : ""
        if (note) routes.set(note, `#/thread/${l.noteId}`)
        return { url: String(l.url).slice(0, 2048), title: String(l.title ?? "").slice(0, 200), host: hostOf(l.url), note }
      })
    } else rows = all.slice(0, SEARCH_CAP)
    return { id: sec.id, title: sec.title, kind, count: all.length, rows }
  }).filter(x => x.count)
  return { data, routes }
}

/**
 * useVault's result -> { data, routes }. `h`: { profileOf, verbOf, whoOf, hrefOf (notify-watch lineHref), formatSats, now }.
 * Rows drawn so far only (useVault's `shown`). A stranger's picture is left out (`trusted`: you or a follow).
 */
export function vaultAnswer(v, h) {
  const routes = new Map()
  const face = pk => { const p = h.profileOf(pk); return { name: nameOf(p), picture: v.trusted(pk) ? https(p?.picture) : "" } }
  const rows = v.items.slice(0, v.shown)
  let kind = "lines", out
  if (EVENT_MODES.has(v.mode)) { kind = "events"; out = rows }
  else if (v.mode === "activity") {
    out = rows.map(r => {
      const href = h.hrefOf(r); if (href) routes.set(r.id, href)
      const words = ["reply", "mention", "quote", "article", "highlight"].includes(r.kind)
      return { id: r.id, who: h.whoOf(r.actors, pk => nameOf(h.profileOf(pk))), verb: h.verbOf(r), at: r.created_at, unread: r.created_at > v.unreadSince,
        faces: r.actors.slice(0, 6).map(face), text: words ? String(r.preview ?? "").slice(0, 2000) : "", about: !words && r.preview ? cut(String(r.preview)) : "",
        thumbs: v.trusted(r.imagesBy) ? (r.images ?? []).map(https).filter(Boolean).slice(0, 4) : [], open: !!href }
    })
  } else if (v.mode === "likes" || v.mode === "zaps") {
    kind = "engage"
    out = rows.map(r => {
      if (r.noteId) routes.set(r.id, `#/thread/${r.noteId}`)
      const mine = r.who[0] === v.me, note = r.noteId ? v.notes.get(r.noteId) : null
      const who = mine ? "You" : r.who.length === 1 ? nameOf(h.profileOf(r.who[0])) || "Someone" : h.whoOf(r.who, pk => nameOf(h.profileOf(pk)))
      const what = (r.type === "reaction" ? `liked ${r.emoji !== "❤️" ? r.emoji ?? "" : ""}`.trim() : "⚡ zapped") + (mine && r.to ? ` ${nameOf(h.profileOf(r.to)) || "someone"}` : "") + (r.type === "zap" && r.sats ? ` ${h.formatSats(r.sats)} sats` : "")
      return { id: r.id, who, what, at: r.created_at, faces: [face(r.who[0])], about: r.noteId ? (note ? { name: nameOf(h.profileOf(note.pubkey)) || "Someone", text: cut(previewOf(note)) || "(media)" } : { name: "", text: "a note" }) : null, open: !!r.noteId }
    })
  } else if (v.mode === "followers") {
    kind = "people"
    out = rows.map(f => { routes.set(f.pubkey, `#/profile/${f.pubkey}`); return { id: f.pubkey, ...face(f.pubkey), name: nameOf(h.profileOf(f.pubkey)) || `${f.pubkey.slice(0, 8)}…`, sub: `followed you ${ago(f.at, h.now)} ago` } })
  } else out = []
  const filters = FILTERS[v.mode] ?? []
  const search = v.search && (v.search.text || v.search.found) ? vaultSearchAnswer(v.search, v.trusted, h, routes).data : null
  return {
    routes,
    data: {
      mode: v.mode, filter: v.filter, kind, rows: out, total: v.items.length,
      modes: MODES.map(m => ({ id: m.id, title: m.title, fresh: v.fresh.has(m.id) })),
      filters: filters.map(x => ({ id: x.id, title: x.title, on: x.id === v.filter })), clearable: CLEARABLE.has(v.mode) && !!v.filter, allTitle: ALL_TITLE[v.mode] ?? "All",
      status: String(v.status ?? ""), loaded: !!v.loaded, ready: !!v.ready, busy: !!v.paging,
      more: v.shown < v.items.length || !!(v.older?.own || v.older?.inbound),
      count: v.mode === "followers" ? v.items.length : null, outsideFollowers: v.mode === "followers" && v.filter === "outside",
      empty: emptyText(v.mode, v.filter, v.followers?.length ?? 0),
      search,
    },
  }
}

/** `pipe`: { answer() -> vaultAnswer | null, ctl: { pick, choose, onMore(atEnd) , shownAll() } }. -> off() */
export function vaultIntents({ bus, pipe, openHash, openDashboard }) {
  let routes = new Map()
  const reader = (action, run) => bus.register({ id: `shell-vault-${action}`, title: "Vault", archetype: "vault", actions: [action], conventions: [], deliver: (p, from) =>
    (from?.dTag !== READER ? { ok: false, error: "the Reader's only" } : run(p ?? {})) })
  const offs = [
    reader("state", () => {
      const a = pipe.answer()
      if (!a) return { ok: true, data: null }
      for (const [k, v] of a.routes) routes.set(k, v)
      return { ok: true, data: a.data }
    }),
    reader("mode", p => {
      if (!MODES.some(m => m.id === p.mode)) return { ok: false, error: "not a Vault page" }
      openHash(`#/vault/${p.mode}`)
      return { ok: true }
    }),
    reader("filter", p => {
      const ctl = pipe.ctl
      if (!ctl || !(FILTERS[ctl.mode()] ?? []).some(x => x.id === p.id)) return { ok: false, error: "not a filter of this page" }
      ctl.choose(p.id)
      return { ok: true }
    }),
    reader("more", () => { pipe.ctl?.more(); return { ok: true } }),
    reader("open", p => {
      const to = typeof p.id === "string" && routes.has(p.id) ? routes.get(p.id) : null
      if (!to) return { ok: false, error: "not a row this page shows" }
      openHash(to)
      return { ok: true }
    }),
    reader("dashboard", () => { openDashboard(); return { ok: true } }),
    reader("find", p => {
      if (!pipe.ctl?.find) return { ok: false, error: "the Vault isn't open" }
      if (typeof p.text !== "string") return { ok: false, error: "text is a string" }
      pipe.ctl.find(p.text.slice(0, 500), !!p.now)
      return { ok: true }
    }),
  ]
  return () => offs.forEach(off => off())
}

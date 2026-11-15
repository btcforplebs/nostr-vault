// Search in the Reader (plan NV_WEB_ONE_PLAN.md step 7): the shell searches with the Search screen's own rules
// (screens/SearchScreen.jsx useSearch: Haven and every search relay at once, ranked, blocked people out, Who and When,
// the outside fold) and works out the start (SearchStart.jsx useSearchStart: Live now, For you, Trending, Active), and
// hands the Reader what it draws: people as plain strings, notes as the signed events. The Reader sends what is typed.
//   napplet:search/query { text, filter? }  -> searches (the Reader waits 300 ms after the last key; Return: search/submit)
//   napplet:search/state {}                 -> { data } (searchAnswer)
//   napplet:search/submit {}                -> Return: "#tag" opens its feed, a pasted profile opens it, else searches now
//   napplet:search/clear {} / search/forget {} -> empties the field / clears Recent
//   napplet:search/open { kind: "person", id } | { kind: "tag", tag } -> a person handed out, or a tag's feed
//   napplet:search/live { id }              -> plays a stream handed out (the shell's player)
// A change comes as inc nv.search.changed. The Reader's only.
import { READER_DTAG as READER } from "./first-party-list.js"
import { filterCaption, WHO, WHEN } from "../net/search.js"

export const SEARCH_TOPIC = "nv.search.changed"
const HEX = /^[0-9a-f]{64}$/
const TAG = /^[\p{L}\p{N}_]{1,64}$/u
const https = v => (/^https:\/\//i.test(v ?? "") ? String(v).slice(0, 2048) : "")
const hostOf = url => { try { return new URL(url).hostname } catch { return "" } }

/** A person row as the screen's PersonRow draws it. */
export function personRow(pk, profileOf, npubOf) {
  const p = profileOf(pk), npub = npubOf(pk)
  return { id: pk, name: String(p?.name || p?.display_name || `${npub.slice(0, 16)}…`).slice(0, 80), sub: String(p?.nip05?.replace(/^_@/, "") || `${npub.slice(0, 12)}…${npub.slice(-6)}`).slice(0, 120), picture: https(p?.picture) }
}

/** A filter the Reader sent, kept only if it names a real Who and When. */
export const filterOf = f => (f && WHO.some(w => w.id === f.who) && WHEN.some(w => w.id === f.when) ? { who: f.who, when: f.when } : null)

/**
 * `search`: useSearch's result; `start`: useSearchStart's; `liveRowsOf(streams)` -> { rows, more } (live-now.js rowsOf).
 * -> { data, people: Set of pubkeys handed out, streams: Map id -> stream }
 */
export function searchAnswer({ search, start, recent }, { profileOf, npubOf, liveRowsOf }) {
  const people = new Set(), streams = new Map()
  const P = pk => { people.add(pk); return personRow(pk, profileOf, npubOf) }
  const s = search.shown
  const results = s && {
    people: s.people.map(P), notes: s.notes, hashtags: s.hashtags.filter(t => TAG.test(t)), outsidePeople: s.outsidePeople.map(P), outsideNotes: s.outsideNotes,
    links: s.links.filter(l => /^https?:\/\//i.test(l.url ?? "")).map(l => ({ url: l.url, title: String(l.title ?? "").slice(0, 200), host: hostOf(l.url) })),
  }
  const found = search.found
  const { rows, more } = liveRowsOf(start?.liveStreams ?? [])
  const named = pk => { const p = profileOf(pk); return !!(p?.name || p?.display_name) }
  return {
    people, streams: new Map(rows.map(r => [r.address, r])),
    data: {
      text: search.text, filter: search.filter, caption: filterCaption(search.filter), direct: !!found?.direct, finished: !!search.finished,
      filteredOut: !!found && !found.direct && !!(found.people.length || found.notes.length),
      sources: (search.sources ?? []).map(x => ({ id: String(x.id), label: String(x.label), state: String(x.state), count: Number(x.count) || 0, reason: String(x.reason ?? "") })),
      results,
      start: start && {
        recent: (recent ?? []).slice(0, 20).map(String),
        live: rows.map(r => { const p = profileOf(r.host) ?? {}; return { id: r.address, name: String(p.name || p.display_name || `${r.host.slice(0, 8)}…`), title: String(r.title || ""), picture: https(p.picture) } }), liveMore: more,
        forYou: { people: start.forYou.people.map(x => ({ ...P(x.pubkey), vouches: x.vouches })), topics: start.forYou.topics.filter(t => TAG.test(t)), notes: start.forYou.notes },
        trending: start.trending.filter(t => TAG.test(t)), active: start.active.filter(named).map(P),
      },
    },
  }
}

/** `pipe`: { answer() -> searchAnswer's result | null, ctl: { setText, setFilter, submit(onProfile), clear, forget } }. -> off() */
export function searchIntents({ bus, pipe, openHash, play }) {
  let handed = { people: new Set(), streams: new Map() }
  const reader = (action, run) => bus.register({ id: `shell-search-${action}`, title: "Search", archetype: "search", actions: [action], conventions: [], deliver: (p, from) =>
    (from?.dTag !== READER ? { ok: false, error: "the Reader's only" } : run(p ?? {})) })
  const ctl = () => pipe.ctl
  const offs = [
    reader("query", p => {
      if (!ctl()) return { ok: false, error: "Search isn't open" }
      if (typeof p.text === "string") ctl().setText(p.text.slice(0, 500))
      const f = filterOf(p.filter); if (f) ctl().setFilter(f)
      return { ok: true }
    }),
    reader("state", () => {
      const a = pipe.answer()
      if (!a) return { ok: true, data: null }
      handed = { people: new Set([...handed.people, ...a.people]), streams: a.streams }
      return { ok: true, data: a.data }
    }),
    reader("submit", () => { ctl()?.submit(pk => openHash(`#/profile/${pk}`)); return { ok: true } }),
    reader("clear", () => { ctl()?.clear(); return { ok: true } }),
    reader("forget", () => { ctl()?.forget(); return { ok: true } }),
    reader("open", p => {
      if (p.kind === "person" && HEX.test(p.id ?? "") && handed.people.has(p.id)) { openHash(`#/profile/${p.id}`); return { ok: true } }
      if (p.kind === "tag" && typeof p.tag === "string" && TAG.test(p.tag)) { openHash(`#/feed?tag=${encodeURIComponent(p.tag)}`); return { ok: true } }
      return { ok: false, error: "not something this search shows" }
    }),
    reader("live", p => {
      const s = handed.streams.get(p.id)
      if (!s) return { ok: false, error: "not a stream this search shows" }
      play(s)
      return { ok: true }
    }),
  ]
  return () => offs.forEach(off => off())
}

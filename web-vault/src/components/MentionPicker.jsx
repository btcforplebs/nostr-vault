// @mentions in Compose, as the iPhone composer does them (ComposeView+Mentions): typing "@" suggests people, follows
// first; picking one puts a readable "@Name" token in the box and remembers whose it is. At posting, each token still in
// the text becomes nostr:npub… and that person gets a p tag.
import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { fetchProfiles, getProfile, onProfiles, putProfile } from "../net/profiles.js"
import { searchNostr } from "../net/search.js"

const MAX = 8

/** The "@query" being typed at the caret: "@" at the start or after whitespace, no whitespace since. -> { start, end, query } */
export function mentionAt(text, caret) {
  const before = text.slice(0, caret)
  const m = /(^|\s)@([^\s@]{0,40})$/u.exec(before)
  return m ? { start: caret - m[2].length - 1, end: caret, query: m[2] } : null
}

const nameOf = (pk, p = getProfile(pk)) => p?.name || ""

/** "@Name" for a person, unique in `map` ({ token: pubkey }): a second person with the same name gets "·<8 hex>". */
export function uniqueToken(name, pubkey, map) {
  const clean = String(name ?? "").replace(/\s*\n\s*/g, " ").trim()
  const base = `@${clean || pubkey.slice(0, 8)}`
  if (!map[base] || map[base] === pubkey) return base
  let candidate = `${base}·${pubkey.slice(0, 8)}`
  for (let n = 2; map[candidate] && map[candidate] !== pubkey; n++) candidate = `${base}·${pubkey.slice(0, 8)}-${n}`
  return candidate
}

const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

/**
 * One pass over the text for every token, longest first at each spot, so "@Al" never matches inside "@Al·bbbbbbbb" or
 * "@Alice". A token counts only as a whole word: after the start or a space (as mentionAt opens the picker, so
 * "bob@Al" stays text), and not followed by a letter, digit, "_", a "·" suffix or a "-2" suffix.
 * -> { content: text with tokens as nostr:npub…, pubkeys: whose tokens were replaced, in order }
 */
export function resolveMentions(text, map) {
  const tokens = Object.keys(map).sort((a, b) => b.length - a.length)
  if (!tokens.length) return { content: text, pubkeys: [] }
  const re = new RegExp(`(?<!\\S)(?:${tokens.map(escape).join("|")})(?![\\p{L}\\p{N}_·]|-\\d)`, "gu")
  const pubkeys = []
  const content = text.replace(re, token => {
    const pk = map[token]
    if (!pubkeys.includes(pk)) pubkeys.push(pk)
    return `nostr:${npubEncode(pk)}`
  })
  return { content, pubkeys }
}

/** The text with each token still in it turned into nostr:npub…. */
export const toNostr = (text, map) => resolveMentions(text, map).content

/** The people whose token resolveMentions replaced: they get p tags, so the tags always match the npubs. */
export const mentionedPubkeys = (text, map) => resolveMentions(text, map).pubkeys

/** People matching `query`, follows first, then names that start with it, then shorter names (iPhone's ranking). */
export function rankPeople(query, pubkeys, follows) {
  const q = query.toLowerCase(), followed = new Set(follows)
  const hits = [...new Set(pubkeys)].map(pk => ({ pk, name: nameOf(pk) })).filter(({ pk, name }) =>
    name ? name.toLowerCase().includes(q) || getProfile(pk)?.nip05?.toLowerCase().includes(q) : !q)
  const rank = h => [followed.has(h.pk) ? 0 : 1, h.name.toLowerCase().startsWith(q) ? 0 : 1, h.name.length]
  return hits.sort((a, b) => { const ra = rank(a), rb = rank(b); return ra[0] - rb[0] || ra[1] - rb[1] || ra[2] - rb[2] }).slice(0, MAX).map(h => h.pk)
}

/** The suggestion strip under the box. Follows' names come from Haven (then their relays); for 2+ characters, a
 *  NIP-50 search adds people who aren't followed. From the box: ↑/↓ move, Enter or Tab picks, Escape closes. */
export function MentionPicker({ ctx, query, onPick, onClose, input }) {
  const follows = ctx.account.follows
  const [found, setFound] = useState([]) // pubkeys from search
  const [active, setActive] = useState(0)
  const [, bump] = useState(0)
  useEffect(() => onProfiles(() => bump(n => n + 1)), [])
  useEffect(() => { fetchProfiles(ctx.vault, follows, ctx.account.relays.read).catch(() => {}) }, [follows])
  useEffect(() => {
    setFound([])
    if (query.length < 2 || globalThis.navigator?.onLine === false) return
    let live = true
    const t = setTimeout(() => searchNostr(query, { limit: 10 }).then(({ people }) => {
      if (!live) return
      people.forEach(putProfile)
      setFound(people.map(e => e.pubkey))
    }).catch(() => {}), 350)
    return () => { live = false; clearTimeout(t) }
  }, [query])

  const people = rankPeople(query, [...follows, ...found], follows)
  const at = Math.min(active, Math.max(0, people.length - 1))
  useEffect(() => setActive(0), [query])
  useEffect(() => {
    const el = input?.current
    if (!el || !people.length) return
    const key = e => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); setActive((at + (e.key === "ArrowDown" ? 1 : people.length - 1)) % people.length) }
      else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); onPick(people[at]) }
      else if (e.key === "Escape") { e.preventDefault(); onClose() }
    }
    el.addEventListener("keydown", key)
    return () => el.removeEventListener("keydown", key)
  }, [input, people.join(), at, onPick, onClose])

  if (!people.length) return null
  return (
    <div class="mention-picker" id="mention-picker" role="listbox" aria-label="People to mention">
      {people.map((pk, i) => {
        const p = getProfile(pk)
        return (
          <button key={pk} type="button" role="option" id={`mention-${pk}`} aria-selected={i === at} class={i === at ? "mention-option on" : "mention-option"}
            // mousedown, not click: the box keeps focus (and its caret) while the pick goes in.
            onMouseDown={e => { e.preventDefault(); onPick(pk) }} onClick={e => { if (e.detail === 0) onPick(pk) }}>
            <Avatar pubkey={pk} size={28} />
            <span class="mention-option-text">
              <span class="mention-option-name">{p?.name || npubEncode(pk).slice(0, 12) + "…"}</span>
              {p?.nip05 && <span class="mention-option-nip05">{p.nip05}</span>}
            </span>
          </button>
        )
      })}
    </div>
  )
}

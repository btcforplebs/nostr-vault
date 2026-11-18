// The one rule for who may put words in front of an account (Logen 2026-11-18, "this is across the board"): every
// feed, mention, notification, Vault list, thread, chat and napplet asks this gate, and none checks the web, the block
// list or the mute list on its own. iPhone/Mac twin: HavenApp/Models/WebGate.swift; Android: data/model/WebGate.kt.
// The written rule is RESEARCH/NV_ONE_WOT_GATE.md section 2b.
//
// The rule, first match wins:
// 1. blocked: the signer or anyone else the row shows is blocked, or the mute list hides the note (word, hashtag,
//    thread). Your own accounts are never blocked as people; mutes on words, hashtags and threads still apply to them.
// 2. inside: the signer is one of your accounts, a key the surface always shows, the whitelist, or your own web.
// 3. inside again when the surface's reach is "everyone" (a Global feed with the shield on Everyone).
// 4. hop3: reach is "webAndHop3" and the signer is one hop past your web.
// 5. outside: everyone else.
//
// It fails closed: with none of the follows' lists back, the web is your follows and nothing is one hop out
// (webLayers). The web is never "everyone any follow follows" (popular.js trustSet): that wide set is what let people
// three hops out through. Pure, so node tests and napplets load it.
import { replyRefs, repostInner } from "./thread.js"

export const VERDICTS = Object.freeze({ inside: "inside", hop3: "hop3", outside: "outside", blocked: "blocked" })
/** How far a surface reaches. Only a feed has a setting; every other surface is "web". */
export const REACHES = Object.freeze(["web", "webAndHop3", "everyone"])

/** How many of your follows must follow someone for them to be in your web (the phone's Min Followers default,
 *  TrustMap.closeVouches; wot.js EXTENDED_MIN). */
export const MIN_FOLLOWERS = 10
/** A new account's web, widened like the relay's newAccountWeb (AccountWeb.newAccountWebCap). */
export const NEW_ACCOUNT_WEB_CAP = 1000

const HEX64 = /^[0-9a-f]{64}$/
const lower = keys => { const out = new Set(); for (const k of keys ?? []) if (k) out.add(String(k).toLowerCase()); return out }
const followedBy = ev => (ev?.tags ?? []).filter(t => t?.[0] === "p" && HEX64.test(String(t[1] ?? "").toLowerCase())).map(t => t[1].toLowerCase())

/**
 * The account's web and the hop past it, from its follows' contact lists (wot.js followLists: Map follow -> kind 3).
 * web: follows, own accounts, and anyone at least `minFollowers` of the follows follow. hop3: followed by at least one
 * follow but fewer than the bar. Fails closed: no lists back is the follows alone, nothing one hop out.
 * A new account (fewer follows than the bar) gets the NEW_ACCOUNT_WEB_CAP most-followed as its web, the rest as hop3.
 * -> { web: Set, hop3: Set }
 */
export function webLayers({ follows = [], lists = new Map(), own = [], minFollowers = MIN_FOLLOWERS } = {}) {
  const followSet = lower(follows)
  const web = new Set([...followSet, ...lower(own)])
  if (!lists?.size) return { web, hop3: new Set() }
  const counts = new Map()
  for (const f of followSet) {
    for (const pk of new Set(followedBy(lists.get(f)))) if (!web.has(pk)) counts.set(pk, (counts.get(pk) ?? 0) + 1)
  }
  const bar = Math.max(minFollowers, 1)
  const hop3 = new Set()
  if (followSet.size < bar) {
    const ranked = [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([pk]) => pk)
    ranked.forEach((pk, i) => (i < NEW_ACCOUNT_WEB_CAP ? web : hop3).add(pk))
    return { web, hop3 }
  }
  for (const [pk, n] of counts) (n >= bar ? web : hop3).add(pk)
  return { web, hop3 }
}

/**
 * One account's web, built once and read for every note. `blocked`: the block list as blocks.js keeps it (a Set of
 * people carrying `words`, `hashtags` and `threads`, muteSet). Keys are lowercased.
 */
export function gateWeb({ own = [], whitelist = [], web = [], hop3 = [], blocked = null } = {}) {
  const w = lower(web)
  const h = lower(hop3)
  for (const pk of w) h.delete(pk)
  return {
    own: lower(own), whitelist: lower(whitelist), web: w, hop3: h, blocked: lower(blocked),
    words: blocked?.words ?? [], hashtags: blocked?.hashtags ?? new Set(), threads: blocked?.threads ?? new Set(),
  }
}

/** The web as the gate reads it while nothing is known yet: you and your follows (fail closed). */
export const followsOnlyWeb = ({ me, follows = [], own = [], blocked = null, whitelist = [] } = {}) =>
  gateWeb({ own: [me, ...own], whitelist, web: follows, blocked })

// ---- What is judged ----

/**
 * A note as the gate judges it. signer: who signed it, so for a repost the reposter (iPhone `repostedBy ?? pubkey`).
 * related: everyone else the row puts in front of you, only checked for blocks: a repost's original author (its
 * verified copy, else its p tag), the parent's author when `authorOf(id)` knows it, the person a comment (1111)
 * answers. muted: the notes whose words, hashtags and thread the mute list reads (a repost's inner note, not its JSON).
 * refs: event ids checked against muted threads only (a repost's or reaction's `e` tags).
 */
export function noteSubject(ev, { authorOf = () => null } = {}) {
  if (!ev) return { signer: "", related: [], muted: [], refs: [] }
  const related = []
  const muted = []
  const refs = []
  if (ev.kind === 6 || ev.kind === 16) {
    const inner = repostInner(ev)
    if (inner) { related.push(inner.pubkey); muted.push(inner) } else related.push((ev.tags ?? []).find(t => t[0] === "p")?.[1])
    for (const t of ev.tags ?? []) if (t[0] === "e") refs.push(t[1])
  } else {
    muted.push(ev)
    if (ev.kind === 1111) related.push((ev.tags ?? []).find(t => t[0] === "p")?.[1])
    const parent = ev.kind === 1 ? replyRefs(ev).parent : null
    if (parent) related.push(authorOf(parent))
  }
  return { signer: String(ev.pubkey ?? ""), related: related.filter(Boolean), muted, refs }
}

/**
 * A zap, judged on its zap request's signer, and only when that request's signature checked out (notifications.js
 * zapRequest verifies it). The receipt's own signer is the lightning service, never a person. `request`: the checked
 * request, or null. -> a subject whose signer is "" when nobody can be named, which is never inside.
 */
export function zapSubject(receipt, request, { related = [] } = {}) {
  const comment = request ? { id: receipt?.id ?? "", content: request.content ?? "", tags: request.tags ?? [] } : null
  return { signer: request?.pubkey ?? "", related, muted: comment ? [comment] : [], refs: [] }
}

// ---- The rule ----

/** True when a note's own words, hashtags or thread are muted. Plain Sets and empty lists never mute. */
export function isMutedNote(ev, { words, hashtags, threads } = {}) {
  if (!ev) return false
  if (threads?.size) {
    if (threads.has(ev.id)) return true
    const { root, parent } = replyRefs(ev)
    if ((root && threads.has(root)) || (parent && threads.has(parent))) return true
  }
  if (hashtags?.size && (ev.tags ?? []).some(t => t[0] === "t" && hashtags.has(String(t[1] ?? "").toLowerCase().replace(/^#/, "")))) return true
  if (words?.length) {
    const text = String(ev.content ?? "").toLowerCase()
    if (text && words.some(w => text.includes(w))) return true
  }
  return false
}

/** Step 1 alone, for a surface that only hides (a quote card, a DM row). */
export function isBlockedSubject(subject, web) {
  if (web.blocked.size) {
    for (const key of [subject.signer, ...subject.related]) {
      const k = String(key ?? "").toLowerCase()
      if (k && !web.own.has(k) && web.blocked.has(k)) return true
    }
  }
  if (web.threads?.size && subject.refs.some(id => web.threads.has(String(id ?? "").toLowerCase()))) return true
  return subject.muted.some(ev => isMutedNote(ev, web))
}

/**
 * The verdict: "inside" | "hop3" | "outside" | "blocked". `reach`: "web" (every surface but a feed), "webAndHop3"
 * (a feed whose Reach setting says so) or "everyone" (a Global feed with the shield on Everyone). `always`: keys this
 * surface always shows (the note's author on its own thread, a stream's host in its chat).
 */
export function judge(subject, web, { reach = "web", always = [] } = {}) {
  if (isBlockedSubject(subject, web)) return VERDICTS.blocked
  const signer = String(subject.signer ?? "").toLowerCase()
  if (!signer) return VERDICTS.outside
  if (web.own.has(signer) || web.whitelist.has(signer) || web.web.has(signer) || [...always].some(k => String(k).toLowerCase() === signer)) return VERDICTS.inside
  if (reach === "everyone") return VERDICTS.inside
  if (reach === "webAndHop3" && web.hop3.has(signer)) return VERDICTS.hop3
  return VERDICTS.outside
}

/** judge for a note event. */
export const judgeNote = (ev, web, { authorOf, reach, always } = {}) => judge(noteSubject(ev, { authorOf }), web, { reach, always })

// ---- Hop 3, rationed ----

/** Most hop-3 rows one list shows: a fifth of its other rows, and never fewer than HOP3_FLOOR, so a feed made mostly
 *  of them (Underrated for an account with few follows) still shows a few (WebGate.capHop3). */
export const HOP3_FLOOR = 10
export const HOP3_SHARE = 5

/**
 * `items` with the hop-3 rows rationed, order kept: top-level posts only (a hop-3 reply goes), one per author, and at
 * most max(HOP3_FLOOR, other rows / HOP3_SHARE). Rows past the ration are left out, not folded: they were not refused,
 * only rationed. Other verdicts pass through untouched.
 */
export function capHop3(items, { verdict, author, isReply = () => false }) {
  const verdicts = items.map(verdict)
  const others = verdicts.filter(v => v !== VERDICTS.hop3).length
  const cap = Math.max(HOP3_FLOOR, Math.floor(others / HOP3_SHARE))
  const authors = new Set()
  let shown = 0
  return items.filter((item, i) => {
    if (verdicts[i] !== VERDICTS.hop3) return true
    const who = String(author(item) ?? "").toLowerCase()
    if (shown >= cap || isReply(item) || authors.has(who)) return false
    authors.add(who)
    shown++
    return true
  })
}

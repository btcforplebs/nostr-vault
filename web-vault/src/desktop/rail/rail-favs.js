// The left rail's pins (Logen, 2026-11-03), in the format docs/SPACE_LAYOUT.md sets for the web and the iPad: the
// sections, which can move but never go, and the user's favourites beside them (a person, a hashtag, a people list or
// a relay's feed), in the user's order. No styles, so tests can import it. They are kept in the layout's `pins`
// (space/space-layout.js), so they sync with Your space through the user's own vault (net/space-sync.js). The iPad's
// twin is HavenApp/Models/SpaceLayout.swift.
//
// A pin is an object with a `type` and that type's value field (docs table):
//   { type: "section", id }   { type: "list", a: "30000:<hex>:<d>" | "39089:<hex>:<d>" }   { type: "person", p: <hex> }
//   { type: "hashtag", t }    { type: "relay", url }    { type: "feed", id: "music" } (a feed type, 2026-11-05)
// plus an optional `name` (the label when it was pinned). A pin is kept exactly as read, its value normalised: fields,
// types and section ids this app doesn't know stay where they are and are not drawn.

/** Every section id the format names, in the default order (docs "Default pins"). */
export const SECTION_IDS = ["feed", "search", "profile", "wot", "vault", "messages", "notifications", "relay", "settings"]
/** The sections the web's rail draws as rows. Settings is the rail's foot; Notifications and the Dashboard (relay) are
 *  reached from the Vault, so those three stay in the layout without a row here. */
export const RAIL_SECTIONS = ["feed", "search", "profile", "wot", "vault", "messages"]
export const VALUE_FIELD = { section: "id", list: "a", person: "p", hashtag: "t", relay: "url", feed: "id" }
/** Feed pin ids are the iPhone's FeedMode, lower case; the web calls its Hashtag feed "hashtag". */
export const feedPinToWeb = id => (id === "hashtags" ? "hashtag" : id)
export const webFeedToPin = id => (id === "hashtag" ? "hashtags" : id)
/** Most favourites (pins other than sections) the rail keeps. */
export const MAX_FAVOURITES = 30

const HEX = /^[0-9a-f]{64}$/

/** A relay address as kept: ws(s)://, host lowercased, no trailing "/"; "" when it isn't one. */
export function normalizeRelay(url) {
  const s = String(url ?? "").trim()
  if (!/^wss?:\/\/[^\s/]+/i.test(s)) return ""
  try {
    const u = new URL(s)
    if (u.protocol !== "wss:" && u.protocol !== "ws:") return ""
    return `${u.protocol}//${u.host.toLowerCase()}${u.pathname.replace(/\/+$/, "")}${u.search}`
  } catch { return "" }
}

/** A pin value normalised for its type (docs table), or "" when it is not a valid one. */
export function normalizeValue(type, value) {
  const v = typeof value === "string" ? value.trim() : ""
  if (!v) return ""
  switch (type) {
    case "person": return HEX.test(v.toLowerCase()) ? v.toLowerCase() : ""
    case "hashtag": { const t = v.replace(/^#+/, "").toLowerCase(); return t && !/\s/.test(t) ? t : "" }
    case "list": {
      const i = v.indexOf(":"), j = v.indexOf(":", i + 1)
      if (i < 0 || j < 0) return ""
      const kind = v.slice(0, i), pk = v.slice(i + 1, j).toLowerCase(), d = v.slice(j + 1)
      return (kind === "30000" || kind === "39089") && HEX.test(pk) && d ? `${kind}:${pk}:${d}` : ""
    }
    case "relay": return normalizeRelay(v)
    case "feed": { const id = v.toLowerCase(); return /\s/.test(id) ? "" : id }
    default: return v
  }
}

const canonical = v => (Array.isArray(v) ? `[${v.map(canonical).join(",")}]`
  : v && typeof v === "object" ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}` : JSON.stringify(v))

/** type + value: two pins with the same key are the same pin. A type this app doesn't know is keyed by its whole entry. */
export const pinKey = p => (VALUE_FIELD[p.type] ? `${p.type}:${p[VALUE_FIELD[p.type]]}` : `${p.type}:${canonical(p)}`)
export const isSection = p => p.type === "section"
/** A favourite this app knows (it counts toward MAX_FAVOURITES). */
export const isFavourite = p => p.type !== "section" && !!VALUE_FIELD[p.type]

/** A new favourite pin, or null when the value is not a valid one. */
export function favourite(type, value, name) {
  if (type === "section" || !VALUE_FIELD[type]) return null
  const clean = normalizeValue(type, value)
  if (!clean) return null
  const n = typeof name === "string" ? name.trim() : ""
  return { type, [VALUE_FIELD[type]]: clean, ...(n ? { name: n.slice(0, 80) } : {}) }
}

/** The default pins: every section, in order. */
export const defaultPins = () => SECTION_IDS.map(id => ({ type: "section", id }))

/**
 * Any saved `pins` -> clean pins (docs "Normalising"): entries that aren't objects, have no type, or a missing or
 * empty value drop out, as do repeats and favourites past the 30th; values are normalised; unknown types and sections
 * stay in place; a section this app has that is missing goes back after the section before it by default.
 */
export function normalizePins(saved, sections = SECTION_IDS) {
  const pins = [], seen = new Set()
  let favs = 0
  for (const raw of Array.isArray(saved) ? saved : []) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw) || typeof raw.type !== "string" || !raw.type) continue
    const field = VALUE_FIELD[raw.type]
    let p = raw
    if (field) {
      const clean = normalizeValue(raw.type, raw[field])
      if (!clean) continue
      p = { ...raw, [field]: clean }
    }
    const k = pinKey(p)
    if (seen.has(k)) continue
    if (isFavourite(p)) { if (favs >= MAX_FAVOURITES) continue; favs++ }
    seen.add(k)
    pins.push(p)
  }
  sections.forEach((id, i) => {
    if (pins.some(p => p.type === "section" && p.id === id)) return
    const before = sections.slice(0, i).reverse().find(b => pins.some(p => p.type === "section" && p.id === b))
    const at = before ? pins.findIndex(p => p.type === "section" && p.id === before) + 1 : 0
    pins.splice(at, 0, { type: "section", id })
  })
  return pins
}

/** Where a pin goes. The Feed reads ?tag=, ?list= and ?relay= (net/feeds.js linkChoice). null: not drawn here. */
export function pinHref(p) {
  switch (p.type) {
    case "section": return RAIL_SECTIONS.includes(p.id) ? `#/${p.id}` : null
    case "person": return `#/profile/${p.p}`
    case "hashtag": return `#/feed?tag=${encodeURIComponent(p.t)}`
    case "list": return `#/feed?list=${encodeURIComponent(p.a)}`
    case "relay": return `#/feed?relay=${encodeURIComponent(p.url)}`
    case "feed": return `#/feed?feed=${encodeURIComponent(feedPinToWeb(p.id))}`
    default: return null
  }
}

/** A relay's short name for the rail: its host without a leading "relay.", e.g. "damus.io", "nos.lol". */
export const relayName = url => { try { return new URL(url).host.replace(/^relay\./, "") } catch { return url } }

/** The pins the rail draws, in order. */
export const shownPins = pins => pins.filter(p => pinHref(p) != null)

/** Pin a favourite at the end. Already there, not a favourite, or 30 already: unchanged. */
export function pin(pins, fav) {
  if (!fav || !isFavourite(fav) || pins.some(p => pinKey(p) === pinKey(fav)) || pins.filter(isFavourite).length >= MAX_FAVOURITES) return pins
  return [...pins, fav]
}
/** Take a favourite off. Sections never go. */
export const unpin = (pins, key) => (key.startsWith("section:") ? pins : pins.filter(p => pinKey(p) !== key))
export const isPinned = (pins, fav) => !!fav && pins.some(p => pinKey(p) === pinKey(fav))

/** Move one up (-1) or down (+1) among the drawn ones; ones not drawn keep their places. */
export function movePin(pins, key, delta) {
  const drawn = shownPins(pins).map(pinKey)
  const i = drawn.indexOf(key), j = i + delta
  if (i < 0 || j < 0 || j >= drawn.length) return pins
  const a = pins.findIndex(p => pinKey(p) === key), b = pins.findIndex(p => pinKey(p) === drawn[j])
  const out = [...pins]
  ;[out[a], out[b]] = [out[b], out[a]]
  return out
}

/** Drop a dragged one just before `beforeKey` (null: at the end). */
export function movePinBefore(pins, key, beforeKey) {
  if (key === beforeKey) return pins
  const moving = pins.find(p => pinKey(p) === key)
  if (!moving) return pins
  const rest = pins.filter(p => p !== moving)
  const i = beforeKey == null ? rest.length : rest.findIndex(p => pinKey(p) === beforeKey)
  if (i < 0) return pins
  const out = [...rest.slice(0, i), moving, ...rest.slice(i)]
  return out.every((p, k) => p === pins[k]) ? pins : out
}

/** Whether two pin lists are the same pins in the same order. */
export const samePins = (a, b) => a.length === b.length && a.every((p, i) => pinKey(p) === pinKey(b[i]))

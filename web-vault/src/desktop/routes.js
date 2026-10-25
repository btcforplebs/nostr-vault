// Desktop routing (OUTBOX design NV_WEB_VAULT_DESKTOP_DESIGN.md §1): the open note and the open conversation live in
// the address as ?note=<id> and ?dm=<pubkey> on the list screen they were opened from, so Back steps through what you
// read and a link can be shared. The phone's own routes (#/thread/<id>, #/dm/<pubkey>) keep working both ways: on a
// wide window they are rewritten to the list screen, on a phone the list address is rewritten back to them.

/** Window widths (§1). Under `single` is the phone layout, unchanged. */
export const WIDTHS = { single: 760, rail: 1024, full: 1280 }

/** "phone" | "single" (rail + one column) | "rail" (rail + list + note) | "full" (sidebar + list + note). */
export function deskModeFor(width) {
  if (width >= WIDTHS.full) return "full"
  if (width >= WIDTHS.rail) return "rail"
  if (width >= WIDTHS.single) return "single"
  return "phone"
}

/** Screens with a list column and a note column. WoT and the Dashboard (relay) take the full width. */
export const SPLIT = new Set(["feed", "search", "profile", "vault", "messages", "notifications", "settings", "accounts", "wallet"])
export const FULL = new Set(["wot", "relay"])

const HEX = /^[0-9a-f]{64}$/

/** "#/vault/notes?note=x" -> { route: "vault", arg: "notes", path: "vault/notes", params } */
export function parseHash(hash = "") {
  const h = hash.replace(/^#\/?/, "")
  const i = h.indexOf("?")
  const path = i < 0 ? h : h.slice(0, i)
  const [route = "", arg = ""] = path.split("/")
  return { route, arg, path, params: new URLSearchParams(i < 0 ? "" : h.slice(i + 1)) }
}

/** The same address with `key` set to `value`, or removed when `value` is null. */
export function withParam(hash, key, value) {
  const { path, params } = parseHash(hash)
  if (value == null) params.delete(key)
  else params.set(key, value)
  const q = params.toString()
  return `#/${path}${q ? `?${q}` : ""}`
}

/** Is this address a list screen (one a note can be opened beside)? */
export const isListHash = hash => SPLIT.has(parseHash(hash).route)

/** On a wide window: the address to show instead of `hash`, or null to keep it. `lastList` is the list screen the
 *  user was on; a thread link opens beside it (cold, with none: beside the Feed). */
export function deskRedirect(hash, lastList) {
  const { route, arg } = parseHash(hash)
  if (route === "thread" && HEX.test(arg)) return withParam(lastList && isListHash(lastList) ? lastList : "#/feed", "note", arg)
  // Opened from Requests: it stays the list beside the conversation.
  if (route === "dm" && HEX.test(arg)) return withParam(parseHash(lastList ?? "").path === "messages/requests" ? lastList : "#/messages", "dm", arg)
  return null
}

/** On a phone: the phone's own address for a desktop one that has a note or conversation open, or null. */
export function phoneRedirect(hash) {
  const { params } = parseHash(hash)
  const note = params.get("note"), dm = params.get("dm")
  if (note && HEX.test(note)) return `#/thread/${note}`
  if (dm && HEX.test(dm)) return `#/dm/${dm}`
  return null
}

/** The sidebar row a screen lights. Someone else's profile was reached from Search (or a card), so Search lights. */
export function sideOf(route, otherProfile = false) {
  if (otherProfile) return "search"
  if (route === "messages" || route === "dm") return "messages"
  if (route === "settings" || route === "accounts" || route === "wallet") return "settings"
  if (route === "relay" || route === "notifications") return "vault"
  if (route === "compose" || route === "thread") return null
  return route
}

// Settings › Who Can Reach You (iPhone RelayAccessSettingsView): Minimum Followers and Refresh Trust List, kept in this
// browser. Minimum Followers is the bar the one gate's web is built with (web-gate.js webLayers minFollowers): how many
// of your follows must follow someone before they are in your web. Refresh Trust List is how often the follows'
// contact lists are asked for again (wot.js followLists refreshMs). The iPhone's Follow Distance isn't here yet.
import { MIN_FOLLOWERS } from "./web-gate.js"

const KEY = "nv:trust-settings"
/** The iPhone's stepper range (RelayAccessSettingsView: 0...100). */
export const MIN_FOLLOWERS_RANGE = Object.freeze([0, 100])
/** The iPhone's Refresh Trust List choices, in its words and order (HavenConfig.wotRefreshInterval). */
export const REFRESH_CHOICES = Object.freeze([
  { id: "1h", label: "Every hour", ms: 3600_000 },
  { id: "12h", label: "Every 12 hours", ms: 12 * 3600_000 },
  { id: "24h", label: "Every day", ms: 24 * 3600_000 },
  { id: "168h", label: "Every week", ms: 168 * 3600_000 },
])
/** The iPhone's default ("24h"). */
export const DEFAULT_REFRESH = "24h"

const listeners = new Set()
const clamp = n => Math.min(MIN_FOLLOWERS_RANGE[1], Math.max(MIN_FOLLOWERS_RANGE[0], Math.round(n)))

function read(storage) {
  try { const v = JSON.parse(storage?.getItem(KEY) ?? "{}"); return v && typeof v === "object" ? v : {} } catch { return {} }
}
function write(next, storage) {
  try { storage?.setItem(KEY, JSON.stringify(next)) } catch {}
  for (const cb of listeners) cb()
}

/** How many of your follows must follow someone for them to be in your web. Default MIN_FOLLOWERS. */
export function minFollowers(storage = globalThis.localStorage) {
  const n = read(storage).minFollowers
  return Number.isFinite(n) ? clamp(n) : MIN_FOLLOWERS
}
export function setMinFollowers(n, storage = globalThis.localStorage) {
  if (!Number.isFinite(n)) return minFollowers(storage)
  write({ ...read(storage), minFollowers: clamp(n) }, storage)
  return minFollowers(storage)
}

/** The Refresh Trust List choice's id. An unknown saved id reads as the default. */
export function refreshChoice(storage = globalThis.localStorage) {
  const id = read(storage).refresh
  return REFRESH_CHOICES.some(c => c.id === id) ? id : DEFAULT_REFRESH
}
export function setRefreshChoice(id, storage = globalThis.localStorage) {
  if (!REFRESH_CHOICES.some(c => c.id === id)) return refreshChoice(storage)
  write({ ...read(storage), refresh: id }, storage)
  return refreshChoice(storage)
}
/** The chosen refresh as milliseconds, for wot.js followLists. */
export const trustRefreshMs = (storage = globalThis.localStorage) => REFRESH_CHOICES.find(c => c.id === refreshChoice(storage)).ms

export const onTrustSettings = cb => { listeners.add(cb); return () => listeners.delete(cb) }

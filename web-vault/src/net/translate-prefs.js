// Settings › Appearance › Translation (iPhone AppearanceSettingsView): Translate Button on Posts (on by default) and
// Translate To ("" is the browser's own language), kept in this browser and read by components/TranslateButton.jsx.
const KEY = "nv:translate"
/** The iPhone's offered languages, roughly by how much of each is on Nostr (FeedLanguage.offered). */
export const OFFERED = Object.freeze(["en", "es", "pt", "de", "fr", "ja", "zh", "ko", "ru", "it", "nl", "tr", "pl", "uk", "fa", "ar", "id", "th", "vi", "hi", "sv", "cs"])
const CODE = /^[a-z]{2,3}$/

function read(storage) {
  try { const v = JSON.parse(storage?.getItem(KEY) ?? "{}"); return v && typeof v === "object" ? v : {} } catch { return {} }
}
function write(next, storage) { try { storage?.setItem(KEY, JSON.stringify(next)) } catch {} }

export const baseCode = tag => String(tag ?? "").split("-")[0].toLowerCase()
/** The browser's own language, as a base code ("en" for "en-GB"). */
export const browserLanguage = (nav = globalThis.navigator) => baseCode(nav?.language ?? "en") || "en"

export const translateOn = (storage = globalThis.localStorage) => read(storage).on !== false
export function setTranslateOn(on, storage = globalThis.localStorage) { write({ ...read(storage), on: !!on }, storage); return translateOn(storage) }

/** The chosen language code, or "" for the browser's language. */
export function translateTo(storage = globalThis.localStorage) {
  const c = read(storage).to
  return typeof c === "string" && CODE.test(c) ? c : ""
}
export function setTranslateTo(code, storage = globalThis.localStorage) {
  write({ ...read(storage), to: CODE.test(code ?? "") ? code : "" }, storage)
  return translateTo(storage)
}
/** The language posts are translated into. */
export const translateTarget = (storage = globalThis.localStorage, nav = globalThis.navigator) => translateTo(storage) || browserLanguage(nav)

/** The picker's languages: the browser's own first, then the rest of OFFERED, once each (FeedLanguage.pickerList). */
export function pickerList(nav = globalThis.navigator) {
  const preferred = (nav?.languages?.length ? nav.languages : [nav?.language ?? "en"]).map(baseCode).filter(c => CODE.test(c))
  return [...new Set([...preferred, ...OFFERED])]
}

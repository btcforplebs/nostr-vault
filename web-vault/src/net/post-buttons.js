// Settings › Post buttons (iPhone AppearanceSettingsView PostButtonsSection, FeedActions PostButtons): whether posts
// show the zap button. Off by default, as on the iPhone and the Mac; profile zaps are always there. Kept in this browser
// under the iPhone's key and value: "⚡️" on, "" off (showsZap also takes a bare ⚡).
const KEY = "postButtons"

export const showsZap = value => String(value ?? "").includes("⚡")

export function zapButtonOn(storage = globalThis.localStorage) {
  try { return showsZap(storage?.getItem?.(KEY)) } catch { return false }
}
export function setZapButton(on, storage = globalThis.localStorage) {
  try { storage?.setItem?.(KEY, on ? "⚡️" : "") } catch {}
}

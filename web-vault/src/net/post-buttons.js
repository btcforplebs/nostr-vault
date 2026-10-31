// Settings › Post buttons (iPhone AppearanceSettingsView PostButtonsSection, FeedActions PostButtons): whether posts
// show the zap button. On until turned off (unlike the iPhone and the Mac, like Android); profile zaps are always there.
// Kept in this browser under the iPhone's key and value: "⚡️" on, "" off, never set = on (showsZap also takes a bare ⚡).
const KEY = "postButtons"

export const showsZap = value => String(value ?? "").includes("⚡")

export function zapButtonOn(storage = globalThis.localStorage) {
  try {
    const value = storage?.getItem?.(KEY)
    return value == null ? true : showsZap(value)
  } catch { return true }
}
export function setZapButton(on, storage = globalThis.localStorage) {
  try { storage?.setItem?.(KEY, on ? "⚡️" : "") } catch {}
}

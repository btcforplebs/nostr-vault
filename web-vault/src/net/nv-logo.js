// Settings › Posts › Hide Nostr Vault logo on posts (iPhone AppearanceSettingsView, HavenConfig.hideNostrVaultBadge):
// hides the vault mark Badges.jsx draws beside the author's name on notes sent from Nostr Vault. Off until turned on,
// so the logo shows. Kept in this browser: "1" hidden, anything else or never set = shown.
const KEY = "hideNostrVaultBadge"

export function nvLogoHidden(storage = globalThis.localStorage) {
  try { return storage?.getItem?.(KEY) === "1" } catch { return false }
}
export function setNvLogoHidden(hidden, storage = globalThis.localStorage) {
  try { storage?.setItem?.(KEY, hidden ? "1" : "") } catch {}
}

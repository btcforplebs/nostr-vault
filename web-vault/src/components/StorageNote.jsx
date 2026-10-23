// This browser keeps a copy of the vault, and the browser may clear it. After sign-in we ask it to keep the copy.
// The phone's vault is the real one.

// The browser's answer to navigator.storage.persist(): true (kept), false (may clear it), or null (it can't be asked).
export async function askToKeep(storage = globalThis.navigator?.storage) {
  if (typeof storage?.persist !== "function") return null
  try { return (await storage.persist()) === true } catch { return false }
}

/** Where Safari's 7-day rule applies: "ios" (every iPhone and iPad browser is Safari's WebKit), "mac" (Safari), or "".
 *  Safari deletes what a site stored after 7 days without a visit; a Home Screen (or Dock) app counts its own visits,
 *  so opened from there the copy stays. `nav` and `standalone` are for tests. */
export function sevenDayErase(nav = globalThis.navigator, standalone = globalThis.matchMedia?.("(display-mode: standalone)").matches) {
  if (standalone || nav?.standalone === true) return ""
  const ua = String(nav?.userAgent ?? "")
  if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && nav?.maxTouchPoints > 1)) return "ios" // iPadOS says Macintosh
  if (/Macintosh/.test(ua) && /Version\/[\d.]+.*Safari/.test(ua) && !/Chrome|Chromium|Edg|Firefox|OPR/.test(ua)) return "mac"
  return ""
}

const KEEP_IT = {
  ios: "Safari deletes this site's data after 7 days without a visit. To keep it, add Nostr Vault to your Home Screen (Share › Add to Home Screen) and open it from there.",
  mac: "Safari deletes this site's data after 7 days without a visit. To keep it, add Nostr Vault to the Dock (File › Add to Dock) and open it from there.",
}

// `kept` is that answer; leave it out (undefined) when it isn't known yet, as on the sign-in screen.
export function StorageNote({ kept, safari = sevenDayErase() }) {
  return (
    <div class="storage-note">
      <p class="muted small">This browser keeps a copy of your notes, and the browser can clear it. Your phone's vault is the real one.</p>
      {KEEP_IT[safari] && <p class="storage-safari small">{KEEP_IT[safari]}</p>}
      {kept !== undefined && <p class={`storage-kept small ${kept ? "on" : ""}`}>{kept ? "Kept on this browser" : "This browser may clear it"}</p>}
    </div>
  )
}

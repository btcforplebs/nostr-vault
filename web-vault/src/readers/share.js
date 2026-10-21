// The web link a long-form post is shared by, as the iPhone's ShareLink: mynostrspace.com/thread/<nevent>, which
// opens on any device without an app. Share uses the system sheet where the browser has one, else copies the link.
import { neventEncode } from "nostr-tools/nip19"

export function threadLink(ev) {
  if (!/^[0-9a-f]{64}$/.test(ev?.id ?? "") || !/^[0-9a-f]{64}$/.test(ev?.pubkey ?? "")) return null
  return `https://mynostrspace.com/thread/${neventEncode({ id: ev.id, author: ev.pubkey, kind: ev.kind })}`
}

/** -> "shared" | "copied" | "cancelled" | "failed". `nav` is for tests. */
export async function shareLink(url, title, nav = globalThis.navigator) {
  if (typeof nav?.share === "function") {
    try { await nav.share({ url, title }); return "shared" } catch (e) { if (e?.name === "AbortError") return "cancelled" }
  }
  return copyLink(url, nav)
}

export async function copyLink(url, nav = globalThis.navigator) {
  try { await nav.clipboard.writeText(url); return "copied" } catch { return "failed" }
}

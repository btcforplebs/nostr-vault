// NIP-07: a browser extension (Alby, nos2x, ...) holds the key and signs.
import { checkedPubkey } from "../session.js"
import { shellNostr } from "../shell.js"

/** The extension's window.nostr, waiting briefly because some extensions inject after the page loads. In the site's
 *  frame (src/shell.js), the top page's when the extension didn't reach the frame. */
export async function findExtension(waitMs = 1500) {
  const ext = () => globalThis.nostr ?? shellNostr()
  for (let t = 0; !ext() && t < waitMs; t += 100) await new Promise(r => setTimeout(r, 100))
  return ext()
}

export async function extensionSignIn() {
  const ext = await findExtension()
  if (!ext) throw new Error("No Nostr extension found in this browser")
  const pubkey = checkedPubkey(await ext.getPublicKey())
  return { signer: extensionSigner(), session: { method: "nip07", pubkey } }
}

export function extensionSigner() {
  return {
    method: "nip07",
    crypto: extensionCrypto(),
    signEvent: async t => (await findExtension())?.signEvent(t) ?? Promise.reject(new Error("Nostr extension is gone")),
  }
}

/**
 * The extension's NIP-44 and NIP-04 (Messages, the private block list). Each call asks the extension, which may prompt the user.
 * `peer` is the other key of the conversation; for a self-copy it is the user's own pubkey.
 * -> { encrypt(peer, text), decrypt(peer, ciphertext), encrypt04(peer, text), decrypt04(peer, ciphertext) }, each
 *    throwing when the extension is gone or doesn't offer that call.
 */
export function extensionCrypto() {
  const call = async (scheme, fn, peer, text) => {
    const ext = await findExtension()
    if (!ext) throw new Error("Nostr extension is gone")
    if (typeof ext[scheme]?.[fn] !== "function") throw new Error(`your extension doesn't offer ${scheme.toUpperCase()} ${fn === "encrypt" ? "encryption" : "decryption"}`)
    return ext[scheme][fn](peer, text)
  }
  return {
    encrypt: (peer, text) => call("nip44", "encrypt", peer, text),
    decrypt: (peer, ciphertext) => call("nip44", "decrypt", peer, ciphertext),
    encrypt04: (peer, text) => call("nip04", "encrypt", peer, text),
    decrypt04: (peer, ciphertext) => call("nip04", "decrypt", peer, ciphertext),
  }
}

// Where to get a signer extension when this browser has none. Links from sidecar.top and Logen, checked 2026-10-25: Sidecar is on
// the Chrome Web Store (Brave installs from it too) and on Firefox Add-ons for desktop Firefox only; Nostash is one
// App Store app with the Safari extension for Mac, iPhone and iPad. Nostr Build Shack (nostr.build, by Big Nut Media) is an
// iPhone and iPad app that keeps Nostr keys in the iOS keychain and has a Safari extension that signs; Logen wants it first
// on iPhone and iPad (2026-10-25). It has no Mac build, so a Mac gets Nostash alone.
export const SIDECAR_CHROME = "https://chromewebstore.google.com/detail/sidecar-a-classy-nostr-si/moimlikilhheabdafocpmneehpblhiln"
export const SIDECAR_FIREFOX = "https://addons.mozilla.org/firefox/addon/sidecar-a-classy-nostr-signer/"
export const NOSTASH = "https://apps.apple.com/us/app/nostash/id6744309333"
export const NOSTR_BUILD_SHACK = "https://apps.apple.com/us/app/nostr-build-shack/id6752591477"
export const AMBER_ZAPSTORE = "https://zapstore.dev/apps/com.greenart7c3.nostrsigner"

const SIDECAR_WHAT = "Sidecar keeps your Nostr key in your browser's side panel and signs for sites like this one, so the key never comes into the page."
const NOSTASH_WHAT = "Nostash keeps your Nostr key in Safari and signs for sites like this one, so the key never comes into the page."
const SHACK_WHAT = "Nostr Build Shack keeps your Nostr key in your iPhone's keychain and its Safari extension signs for sites like this one, so the key never comes into the page."
const IOS_AFTER = name => `After installing, turn ${name} on in Settings › Apps › Safari › Extensions and allow it for this site.`

/**
 * The extension to suggest for this browser. ua: navigator.userAgent; brave: whether navigator.brave exists; touch:
 * navigator.maxTouchPoints, which tells an iPad (it says "Macintosh") from a Mac.
 * -> { browser, name, url, store, what, after, more } to link, or { browser, note, signer } where no extension can run. more: the
 *    other apps to offer after the first, each { name, url, store, what, after } (iPhone and iPad only). signer: the signer
 *    app the note names, { name, url, store } (Android only).
 */
export function extensionHelp(ua = "", { brave = false, touch = 0 } = {}) {
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && touch > 1)
  const android = /Android/.test(ua)
  const firefox = /Firefox\/|FxiOS\//.test(ua)
  const chromium = /Chrome\/|Chromium\/|CriOS\/|Edg[AiO]?\//.test(ua)
  if (ios) {
    if (/CriOS|FxiOS|EdgiOS|OPiOS/.test(ua)) return { browser: "this browser", note: "Extensions on iPhone and iPad run in Safari. Open this page in Safari to sign in with Nostr Build Shack or Nostash, or use a bunker link below." }
    return { browser: "Safari", name: "Nostr Build Shack", url: NOSTR_BUILD_SHACK, store: "App Store", what: SHACK_WHAT, after: IOS_AFTER("Nostr Build Shack"),
      more: [{ name: "Nostash", url: NOSTASH, store: "App Store", what: NOSTASH_WHAT, after: IOS_AFTER("Nostash") }] }
  }
  if (android) return { browser: "this browser", note: "Browsers on Android can't add a Nostr extension yet. Use a bunker link from a signer app like Amber below.",
    signer: { name: "Amber", url: AMBER_ZAPSTORE, store: "Zapstore" } }
  if (firefox) return { browser: "Firefox", name: "Sidecar", url: SIDECAR_FIREFOX, store: "Firefox Add-ons", what: SIDECAR_WHAT }
  if (chromium) return { browser: brave ? "Brave" : /Edg\//.test(ua) ? "Edge" : "Chrome", name: "Sidecar", url: SIDECAR_CHROME, store: "Chrome Web Store", what: SIDECAR_WHAT }
  if (/Safari\//.test(ua) && /Macintosh/.test(ua)) return { browser: "Safari", name: "Nostash", url: NOSTASH, store: "Mac App Store", what: NOSTASH_WHAT, after: "After installing, open Nostash once, then turn it on in Safari › Settings › Extensions and allow it for this site." }
  return { browser: "this browser", note: "We don't know a Nostr extension for this browser. Use a bunker link below, or Chrome, Brave, Firefox or Safari." }
}

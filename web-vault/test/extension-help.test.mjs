// Sign-in with no extension: which signer extension each browser is pointed to (signer/nip07.js extensionHelp).
import test from "node:test"
import assert from "node:assert/strict"
import { extensionHelp, SIDECAR_CHROME, SIDECAR_FIREFOX, NOSTASH, NOSTR_BUILD_SHACK } from "../src/signer/nip07.js"

const UA = {
  chromeMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  chromeWin: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
  firefoxMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0",
  firefoxLinux: "Mozilla/5.0 (X11; Linux x86_64; rv:144.0) Gecko/20100101 Firefox/144.0",
  safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
  safariIphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
  chromeIphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1",
  firefoxIphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/144.0 Mobile/15E148 Safari/605.1.15",
  chromeAndroid: "Mozilla/5.0 (Linux; Android 15; moto g) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
  firefoxAndroid: "Mozilla/5.0 (Android 15; Mobile; rv:144.0) Gecko/144.0 Firefox/144.0",
}

test("Chrome, Brave and Edge get Sidecar from the Chrome Web Store", () => {
  for (const ua of [UA.chromeMac, UA.chromeWin]) assert.deepEqual([extensionHelp(ua).browser, extensionHelp(ua).url], ["Chrome", SIDECAR_CHROME])
  assert.equal(extensionHelp(UA.chromeMac, { brave: true }).browser, "Brave")
  assert.equal(extensionHelp(UA.chromeMac, { brave: true }).url, SIDECAR_CHROME)
  assert.equal(extensionHelp(UA.edge).browser, "Edge")
  assert.equal(extensionHelp(UA.edge).name, "Sidecar")
})

test("desktop Firefox gets Sidecar from Firefox Add-ons", () => {
  for (const ua of [UA.firefoxMac, UA.firefoxLinux]) {
    const h = extensionHelp(ua)
    assert.equal(h.browser, "Firefox"); assert.equal(h.url, SIDECAR_FIREFOX); assert.equal(h.store, "Firefox Add-ons")
  }
})

test("Safari on a Mac gets Nostash; on iPhone and iPad, Nostr Build Shack first and then Nostash, each with how to turn it on", () => {
  const mac = extensionHelp(UA.safariMac)
  assert.equal(mac.name, "Nostash"); assert.equal(mac.url, NOSTASH); assert.equal(mac.store, "Mac App Store")
  assert.match(mac.after, /Safari › Settings › Extensions/)
  assert.equal(mac.more, undefined)
  // iPadOS Safari says "Macintosh"; touch points give it away.
  for (const phone of [extensionHelp(UA.safariIphone, { touch: 5 }), extensionHelp(UA.safariMac, { touch: 5 })]) {
    assert.deepEqual([phone, ...phone.more].map(a => [a.name, a.url, a.store]),
      [["Nostr Build Shack", NOSTR_BUILD_SHACK, "App Store"], ["Nostash", NOSTASH, "App Store"]])
    for (const a of [phone, ...phone.more]) assert.match(a.after, new RegExp(`turn ${a.name} on in Settings › Apps › Safari › Extensions`))
  }
})

test("browsers that can't run an extension get a note instead of a link", () => {
  for (const ua of [UA.chromeIphone, UA.firefoxIphone]) {
    const h = extensionHelp(ua)
    assert.equal(h.url, undefined); assert.match(h.note, /Open this page in Safari to sign in with Nostr Build Shack or Nostash/)
  }
  // Sidecar's Firefox listing is desktop only, and Android Chrome has no extensions.
  for (const ua of [UA.chromeAndroid, UA.firefoxAndroid]) {
    const h = extensionHelp(ua)
    assert.equal(h.url, undefined); assert.match(h.note, /Android/)
    assert.deepEqual(h.signer, { name: "Amber", url: "https://zapstore.dev/apps/com.greenart7c3.nostrsigner", store: "Zapstore" })
  }
  assert.match(extensionHelp("").note, /don't know a Nostr extension/)
})

test("every store link is one of the checked listings", () => {
  assert.equal(new URL(SIDECAR_CHROME).host, "chromewebstore.google.com")
  assert.equal(new URL(SIDECAR_FIREFOX).host, "addons.mozilla.org")
  assert.equal(new URL(NOSTASH).host, "apps.apple.com")
  assert.equal(new URL(NOSTR_BUILD_SHACK).host, "apps.apple.com")
  assert.match(NOSTR_BUILD_SHACK, /\/id6752591477$/)
})

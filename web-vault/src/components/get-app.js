// The native app a phone visitor can install instead of using the web app, picked from the browser's user agent:
// iPhone and iPad get the TestFlight beta, Android gets Zapstore. navigator.maxTouchPoints tells an iPad (its Safari
// says "Macintosh") from a Mac. Anything else (a computer, the site's phone frame on one) gets null: no button.
export const TESTFLIGHT = "https://testflight.apple.com/join/kN3zE1H1"
export const ZAPSTORE = "https://zapstore.dev/apps/com.nostrvault.app"

/** { label, url, line } for this device's download, or null when it has none. */
export function appDownload(ua = globalThis.navigator?.userAgent ?? "", touch = globalThis.navigator?.maxTouchPoints ?? 0) {
  if (/iPhone|iPod/.test(ua)) return { label: "Get the app for iPhone", url: TESTFLIGHT, line: "A free beta, installed with Apple's TestFlight app." }
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && touch > 1)) return { label: "Get the app for iPad", url: TESTFLIGHT, line: "A free beta, installed with Apple's TestFlight app." }
  if (/Android/.test(ua)) return { label: "Get the app for Android", url: ZAPSTORE, line: "Free on Zapstore, the app store for Nostr." }
  return null
}

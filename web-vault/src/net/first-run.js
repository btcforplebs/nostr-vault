// First run on the web, as the apps after Logen's plan (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md, Apple #1761,
// Android #1759): two choices on the front door (Create an account, Bring an account; New to Nostr Vault? after sign-in), a short tour for
// a new account, and the notification question asked once, after you're in, never over the tour. Pure, for tests.

// The front door's two choices, no question above them, as the apps word them (Apple WelcomeStepView, Android
// FrontDoor, Logen 2026-11-06): Create an account makes one; Bring an account signs in with yours.
export const CREATE_ACCOUNT = "Create an account"
export const BRING_ACCOUNT = "Bring an account"

/** The tour a new account sees once, after it's in. Short: it teaches while the first notes come in. */
export const TOUR = [
  { title: "Your vault", body: "Nostr Vault keeps your notes, messages and photos in this browser. Open the Vault Dashboard to see what's in it and keep it full." },
  { title: "Your feed", body: "Following shows the people you follow. Search finds more, and your web of trust keeps strangers' spam out of your replies." },
  { title: "Your keys", body: "Your secret key is locked with your password in this browser. Keep the copy you saved somewhere safe: it's the only way back in." },
]
const TOUR_KEY = "nv-tour-done" // per account, so sign-out (haven/vault.js accountKeys) forgets it
export const tourDone = (pk, storage = globalThis.localStorage) => { try { return storage?.getItem(`${TOUR_KEY}:${pk}`) === "1" } catch { return true } }
export const markTourDone = (pk, storage = globalThis.localStorage) => { try { storage?.setItem(`${TOUR_KEY}:${pk}`, "1") } catch {} }

// The notification question (Apple NotificationAsk): once per browser, after you're in, never over the tour or the
// first-run screens, after 2 s with nothing else up. The switch is set by the answer, never turned on before it.
export const NOTIFY_ASKED = "nv-notify-asked"
export const QUIET_MS = 2000
export const NOTIFY_QUESTION = "Get notified about replies, mentions and messages while Nostr Vault is open?"
export const notifyAsked = (storage = globalThis.localStorage) => { try { return storage?.getItem(NOTIFY_ASKED) === "1" } catch { return true } }
export const markNotifyAsked = (storage = globalThis.localStorage) => { try { storage?.setItem(NOTIFY_ASKED, "1") } catch {} }

/** "answered" (never ask), "wait" (not yet), or "ask". `permission`: the browser's ("default" = never answered). */
export function notifyAction({ permission, asked, inApp, busy, quietForMs }) {
  if (permission !== "default" || asked) return "answered"
  if (!inApp || busy || quietForMs < QUIET_MS) return "wait"
  return "ask"
}

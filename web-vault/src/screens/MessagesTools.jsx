// Messages' header tools (Logen, 2026-11-03): the Requests button at the top right (a tray with the count, in place of
// the Requests row under the list), and the search over names and message text, which runs on this device only
// (net/dm-search.js): the query is never sent anywhere.
import { npubEncode } from "nostr-tools/nip19"
import { getProfile } from "../net/profiles.js"

const TRAY = <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M22 12h-6l-2 3h-4l-2-3H2" /><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z" /></svg>
const LOOK = <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.8-4.8" /></svg>

/** The Requests tray: opens #/messages/requests. No count on it (Logen, 2026-11-04: "it's bothersome"); requests
 *  never notify and add to no badge anywhere. */
export function RequestsButton() {
  return (
    <a class="dm-requests-btn" href="#/messages/requests" title="Requests: people outside your Web of Trust" aria-label="Requests">
      {TRAY}
    </a>
  )
}

/** The search box. Escape clears it. */
export function MessagesSearch({ value, onInput, label = "Search messages" }) {
  return (
    <div class="dm-search" role="search">
      {LOOK}
      <input type="search" value={value} placeholder={`${label}…`} aria-label={label} autocapitalize="off" autocorrect="off" spellcheck={false}
        enterkeyhint="search" onInput={e => onInput(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Escape" && value) { e.preventDefault(); onInput("") } }} />
    </div>
  )
}

/** A person's name as the search reads it: the profile already loaded (never a lookup), else their npub. */
export const searchName = pk => {
  const p = getProfile(pk)
  return [p?.display_name, p?.name].filter(Boolean).join(" ") || npubEncode(pk)
}

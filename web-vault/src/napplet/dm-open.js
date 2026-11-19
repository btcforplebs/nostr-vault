// Opening a chat in the Messages napplet from an address (MessagesPane.jsx). Its own file so node tests load it alone.
import { dmPrefill } from "../net/dms.js"

/** The pubkey a #/dm/<pk> link opens (a full URL or a hash), else null. */
export const dmLinkOf = url => /#\/dm\/([0-9a-f]{64})(?:[?]|$)/.exec(String(url ?? ""))?.[1] ?? null
/** What the napplet is handed to open a chat: the pubkey, and a link's ?text= (Message seller, B9) to type in, never
 *  sent. The text is taken off the address once handed over, so a reload doesn't type it again. */
export function openPayload(pubkey, win = globalThis) {
  const { text, hash } = dmPrefill(win.location?.hash ?? "")
  if (text) win.history?.replaceState?.(win.history.state, "", hash)
  return text ? { pubkey, text: text.slice(0, 20000) } : { pubkey }
}

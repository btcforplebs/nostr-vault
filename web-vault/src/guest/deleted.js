// Whether a shared post's author deleted it (a kind 5 they signed), asked before the guest view draws it: a deleted
// post's photos must not come off the author's vault over the mesh once its https copy is gone. As the thread page
// checked before it handed browsers to the app (thread-page/fetch.js readDeleted, until #1060).
import { verifiedCopy } from "../net/thread.js"
import { pool } from "../net/pool.js"

const MAX_WAIT_MS = 4000
const defaultQuery = (relays, filter) => pool.querySync(relays, filter, { maxWait: MAX_WAIT_MS }).catch(() => [])
const verified = evs => (evs ?? []).map(verifiedCopy).filter(Boolean)

/** Whether `post`'s author signed a deletion of it, by id or, for an addressable post, by address (one dated at or
 *  after the post). Someone else's kind 5, or a forged one, doesn't count. */
export async function readDeleted(post, query = defaultQuery, relays = []) {
  const d = post.kind >= 30000 && post.kind < 40000 ? post.tags.find(t => t[0] === "d")?.[1] : null
  const address = typeof d === "string" ? `${post.kind}:${post.pubkey}:${d}` : null
  const filters = [{ kinds: [5], authors: [post.pubkey], "#e": [post.id] }, ...(address ? [{ kinds: [5], authors: [post.pubkey], "#a": [address] }] : [])]
  const found = verified((await Promise.all(filters.map(f => query(relays, f)))).flat())
  return found.some(ev => ev.kind === 5 && ev.pubkey === post.pubkey &&
    ev.tags.some(t => (t[0] === "e" && t[1] === post.id) || (address && t[0] === "a" && t[1] === address && ev.created_at >= post.created_at)))
}

/** The opened post `id`, from `relays`: true when its author deleted it, false otherwise (also when no relay has it:
 *  the thread screen then says so). */
export async function guestPostDeleted(id, relays, query = defaultQuery) {
  const post = verified(await query(relays, { ids: [id] })).find(ev => ev.id === id)
  return post ? readDeleted(post, query, relays) : false
}

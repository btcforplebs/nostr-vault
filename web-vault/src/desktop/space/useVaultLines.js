// The Vault list's lines for the Live Vault panel, read from this browser's vault the way the Vault tab and the
// title's count read them (net/notify-watch.js vaultLines). On opening it asks the user's relays once for what tags
// them, as the Vault tab does, since the title's watch only asks for what is newer than its mark. After that
// useNotifyWatch asks every POLL_MS and files what comes in, so the panel reads again when the unread count or the
// seen mark moves, and every POLL_MS in case a poll brought lines that changed neither. It also reads again as soon as
// Haven keeps something for the outbox or the inbox (net/vault-saved.js), at most every SAVED_GAP_MS, so a line doesn't
// wait for the poll (Logen, 2026-11-04). A like or repost of a note of yours Haven doesn't hold yet shows at once;
// that note is fetched from your relays so its text fills in.
import { useEffect, useRef, useState } from "preact/hooks"
import { readInbound, readOwn, readLists, fetchInbound, fetchFollowerLists, keepLists, mergeLists, OWN_NOTE_KINDS } from "../../net/vault-lists.js"
import { onSaved, throttle } from "../../net/vault-saved.js"
import { receiptTrust } from "../../net/zaps.js"
import { vaultLines, unreadLines, unreadFrom, readSince, onVaultUnread, POLL_MS } from "../../net/notify-watch.js"
import { readSeen, onSeen } from "../../net/vault-new.js"
import { fetchProfiles } from "../../net/profiles.js"
import { DEFAULT_RELAYS, pool, uniq } from "../../net/pool.js"
import { useBlocks } from "../../components/useBlocks.js"
import { useDmTrust } from "../../components/useDmTrust.js"
import { MAX_ROWS } from "./live-vault.js"

/** Reads after a save at most this often: an import keeps thousands of events. */
export const SAVED_GAP_MS = 2000
/** Lines whose note of yours Haven doesn't hold yet: the ids to fetch, those not asked before, at most `max`. */
export const missingNotes = (lines, asked, max = MAX_ROWS) =>
  uniq(lines.slice(0, MAX_ROWS).filter(r => ["like", "repost", "zap"].includes(r.kind) && r.openId && !r.preview && !r.images?.length).map(r => r.openId)).filter(id => !asked.has(id)).slice(0, max)

/** -> { lines (newest first) | null until first read, unread: Set of line ids newer than the last look,
 *  fetched: the first ask of the relays is done } */
export function useVaultLines(ctx) {
  const me = ctx.session.pubkey
  const { blocked } = useBlocks(ctx)
  const network = useDmTrust(ctx) // the Vault list's network: notes from outside it stay out, as in the list
  const live = useRef()
  live.current = { ctx, blocked, network }
  const [state, setState] = useState({ lines: null, unread: new Set(), fetched: false })
  const fetched = useRef(false)
  useEffect(() => {
    let stopped = false, named = new Set(), asked = new Set()
    const since = readSince(me)
    const read = async () => {
      const { ctx, blocked, network } = live.current
      const [inbound, own] = await Promise.all([readInbound(ctx.vault, me).catch(() => []), readOwn(ctx.vault, me, { kinds: OWN_NOTE_KINDS }).catch(() => [])])
      if (stopped) return
      const lines = vaultLines({ inbound, own, lists: readLists(me), me, blocked, trusted: network })
      const unread = new Set(unreadLines(lines, unreadFrom(readSeen(me)?.activity ?? 0, since)).map(r => r.id))
      setState({ lines, unread, fetched: fetched.current })
      // Names and faces for what the panel draws; each person asked for once a visit.
      const want = uniq(lines.slice(0, MAX_ROWS).flatMap(r => r.actors.slice(0, 2))).filter(pk => !named.has(pk))
      if (want.length) {
        want.forEach(pk => named.add(pk))
        const relays = uniq([...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS])
        fetchProfiles(ctx.vault, want, relays).catch(() => {})
      }
      // Your notes those lines are about, into Haven (its save brings the next read); each asked for once a visit.
      const ids = missingNotes(lines, asked)
      if (ids.length && navigator.onLine !== false) {
        ids.forEach(id => asked.add(id))
        const relays = uniq([...(ctx.account?.relays?.write ?? []), ...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS])
        pool.querySync(relays, { ids, authors: [me] }, { maxWait: 8000 })
          .then(evs => Promise.all(evs.filter(e => ids.includes(e.id) && e.pubkey === me).map(e => ctx.vault.outbox.event(e).catch(() => null))))
          .catch(() => {})
      }
    }
    const relays = uniq([...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS])
    read().catch(() => {}).then(async () => {
      if (fetched.current || navigator.onLine === false) { fetched.current = true; return read() }
      await Promise.allSettled([
        fetchInbound(ctx.vault, me, relays, { limit: 100, trust: receiptTrust(ctx) }),
        fetchFollowerLists(me, relays, { limit: 100, on: fresh => keepLists(me, mergeLists(readLists(me), fresh, me)) }),
      ])
      fetched.current = true
      if (!stopped) await read()
    }).catch(() => {})
    const again = () => { read().catch(() => {}) }
    const offUnread = onVaultUnread(again)
    const offSeen = onSeen(again)
    const timer = setInterval(again, POLL_MS)
    const soon = throttle(again, SAVED_GAP_MS)
    const offSaved = onSaved(route => { if (route === "/" || route === "/inbox") soon.call() })
    return () => { stopped = true; offUnread(); offSeen(); offSaved(); soon.stop(); clearInterval(timer) }
  }, [me, blocked, network.size])
  return state
}

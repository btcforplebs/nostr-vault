// The shell's real pieces, as dispatch.js wants them (`deps`), for the signed-in app's ctx ({ vault, session,
// signer, account }). Kept apart from dispatch.js so its tests run on fakes. Everything here already exists in the
// app: Haven's routes, the signer, the pool and its relay rules, the block list, Blossom upload, notices.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { firstTaken } from "../net/actions.js"
import { checkSigned } from "../net/sync.js"
import { getBlocks } from "../net/blocks.js"
import { uploadPhoto, mediaServers, DEFAULT_MEDIA_SERVERS } from "../net/upload.js"
import { parseBlossomUri, candidateServers, fetchVerified, readCapped, MAX_BYTES, serverOrigin, authorServers } from "../net/blossom-uri.js"
import { showNotice } from "../net/notify-show.js"
import { blockedUrl } from "./fetch-policy.js"
import { protectedKind, deletionTargets } from "./policy.js"
import { idbNappletStorage } from "./storage-idb.js"
import { catalogFilter, catalogEntries, fetchArtifact } from "./catalog.js"
import { listBlobs, mirrorBlob, deleteBlob } from "../net/blossom-gallery.js"
import { getMessages, onMessages, sendMessage, dropFailed } from "../net/dms.js"
import { markRead } from "../net/dm-read.js"
import { dmContent, preparePhoto } from "../net/dm-photo.js"
import { getProfile } from "../net/profiles.js"
import { findMine, newestMine } from "./shell-deps-find.js"
import { SEND_ACTIONS, countdownText, sendDelaySeconds, startCountdown } from "../net/send-delay.js"
import { showToast, hideToast } from "../components/Toast.jsx"
import { delayActionOf } from "./publish-delay.js"
import { globalTrust } from "../readers/trust.js"
import { wotGate, namedSets } from "./wot-gate.js"

const QUERY_WAIT_MS = 4000
const WOT_TTL_MS = 10 * 60_000

// The web, worked out once per account and kept for WOT_TTL_MS (it asks every follow's follow list), as the
// reader feeds' Global does (readers/trust.js globalTrust), plus the emoji sets the user's own 10030 names. Until the
// follows' follow lists are in, the gate is you and your follows only: narrower, never wider, so a napplet's first
// read doesn't wait seconds for the whole web. The gate reads the current web on every event, so it widens in place.
let wotCache = null // { key, at, gate: Promise<ev => bool> }
function nappletWot(ctx) {
  const me = ctx.session.pubkey, follows = [...(ctx.account.follows ?? [])]
  const key = `${me}:${follows.length}`
  if (wotCache?.key === key && Date.now() - wotCache.at < WOT_TTL_MS) return wotCache.gate
  const web = { trust: new Set([me, ...follows]), named: new Set() }
  globalTrust(me, follows).then(t => { if (t) web.trust = t }).catch(() => {})
  const gate = ctx.vault.outbox.query([{ kinds: [10030], authors: [me], limit: 1 }]).catch(() => []).then(lists => {
    const list = lists.filter(ev => ev?.pubkey === me).sort((x, y) => y.created_at - x.created_at)[0]
    web.named = namedSets(list)
    return ev => wotGate({ me, trust: web.trust, named: web.named })(ev)
  })
  wotCache = { key, at: Date.now(), gate }
  return gate
}

/** The theme a napplet draws with: the app's own colours, read from its CSS variables. */
export function appTheme(doc = document) {
  const css = getComputedStyle(doc.documentElement), v = n => css.getPropertyValue(n).trim()
  return { colors: { background: v("--bg") || "#000", text: v("--text") || "#fff", primary: v("--accent") || "#e67326" }, title: "Nostr Vault" }
}

async function fetchBytes(url, { servers = [], range } = {}) {
  if (typeof url === "string" && url.startsWith("blossom:")) {
    const b = parseBlossomUri(url)
    if (!b) throw codeError("invalid-request")
    const got = await fetchVerified(b, candidateServers(b, servers.filter(s => !blockedUrl(s))))
    if (!got) throw codeError("not-found")
    return { blob: new Blob([got.bytes], { type: got.mime }), mime: got.mime }
  }
  const no = blockedUrl(url)
  if (no) throw codeError(no)
  const headers = range ? { Range: `bytes=${range.start}-${range.end ?? ""}` } : undefined
  let res
  try { res = await fetch(url, { headers, credentials: "omit", referrerPolicy: "no-referrer", redirect: "error", signal: AbortSignal.timeout?.(30_000) }) } catch (e) { throw codeError(e?.name === "TimeoutError" ? "timeout" : "network-error", String(e?.message ?? e)) }
  if (res.status === 404) throw codeError("not-found")
  if (!res.ok) throw codeError("network-error", `HTTP ${res.status}`)
  const bytes = await readCapped(res, MAX_BYTES)
  if (!bytes) throw codeError("too-large")
  const mime = res.headers.get("content-type") || "application/octet-stream"
  return { blob: new Blob([bytes], { type: mime }), mime }
}

/**
 * deps for dispatch.js. `ask`: the consent sheet's question (NappletShell). `saveGrant(grant)`: keep a changed grant.
 * `bus`: the page's createBus().
 */
export function shellDeps(ctx, { ask, saveGrant, bus, storage = idbNappletStorage(ctx.session.pubkey), dm = null }) {
  const readRelays = () => uniq([...(ctx.account.relays?.read ?? []), ...DEFAULT_RELAYS])
  return {
    pubkey: ctx.session.pubkey,
    account: () => ctx.account,
    blocked: () => getBlocks().blocked,
    // A plain copy: nostr-tools caches "verified" under a symbol that a spread copy keeps (reader-intents.js actionNote).
    verify: ev => { try { return !!ev && verifyEvent(JSON.parse(JSON.stringify(ev))) } catch { return false } },
    // dispatch.js already ran signDecision; this is the last stop before the signer, so it says no again on its own.
    async sign(template) {
      if (protectedKind(template.kind)) throw new Error(`kind ${template.kind} is never signed for a napplet`)
      if (template.kind === 5 && deletionTargets(template).kinds.some(k => !Number.isInteger(k) || protectedKind(k))) throw new Error("a napplet can't delete an account list")
      return checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
    },
    async publish(event) {
      if (protectedKind(event?.kind)) return { ok: false, error: `kind ${event?.kind} is never sent for a napplet` }
      const { network, local } = publishRelays(ctx.account.relays?.write ?? [])
      const urls = [...network, ...local]
      const sends = pool.publish(urls, event)
      const first = await firstTaken(sends.slice(0, network.length))
      if (first < 0) return { ok: false, error: `No relay took it (0 of ${network.length})` }
      if (event.pubkey === ctx.session.pubkey) await ctx.vault.outbox.event(event).catch(() => {})
      return { ok: true, relays: { [urls[first]]: true } }
    },
    // Haven: the user's own events (/), the feed cache (/feed) and what others sent them (/inbox). `routes`:
    // "all", or "public" (the feed cache only) for an outside napplet.
    async vaultQuery(filters, { routes = "all" } = {}) {
      const list = routes === "public" ? [ctx.vault.feed] : [ctx.vault.outbox, ctx.vault.feed, ctx.vault.inbox]
      return (await Promise.all(list.map(r => r.query(filters).catch(() => [])))).flat()
    },
    // Network events that passed the WoT gate, into Haven's feed cache before a napplet sees them (as thread.js
    // syncThread does). /feed keeps the feed kinds and refuses the rest; those are still handed over, gated.
    async havenStore(events) {
      return (await Promise.all(events.map(ev => ctx.vault.feed.event(ev).then(r => (r?.ok ? ev : null)).catch(() => null)))).filter(Boolean)
    },
    wotGate: () => nappletWot(ctx),
    async netQuery(filters) {
      const relays = readRelays()
      return (await Promise.all(filters.map(f => pool.querySync(relays, f, { maxWait: QUERY_WAIT_MS }).catch(() => [])))).flat()
    },
    netSubscribe(filters, onEvent, onEose) {
      const relays = readRelays()
      let left = filters.length
      const subs = filters.map(f => pool.subscribeMany(relays, f, { onevent: onEvent, oneose: () => { if (--left === 0) onEose?.() } }))
      return () => subs.forEach(s => s.close())
    },
    theme: () => appTheme(),
    storage,
    resourceSchemes: () => ["data", "https", "blossom"],
    fetchBytes,
    async upload(blob, mime) {
      const file = new File([blob], "napplet-upload", { type: mime })
      const up = await uploadPhoto(file, { ctx, servers: await mediaServers(ctx) })
      return { url: up.url, sha256: up.sha256, size: up.size, mime: up.mime }
    },
    async notify({ title, body, from }) {
      const tag = `napplet-${crypto.randomUUID()}`
      await showNotice({ title: `${from}: ${title}`, body, tag })
      return tag
    },
    // NAP-BLOSSOM (blossom-dispatch.js): the classic Media page's own Blossom code, the auths signed here.
    blossom: {
      pubkey: ctx.session.pubkey,
      servers: () => mediaServers(ctx),
      list: (server, pubkey) => listBlobs([server], pubkey, { ctx }),
      mirror: (blob, server) => mirrorBlob(blob, [server], { ctx }),
      remove: (blob, server) => deleteBlob(blob, { ctx, servers: [server] }),
      describe: async url => {
        const res = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(5000) })
        if (!res.ok) return null
        return { size: Number(res.headers.get("Content-Length")) || undefined, type: res.headers.get("Content-Type") || undefined }
      },
      ask,
      now: () => Date.now(),
    },
    // NAP-DM (dm-dispatch.js) on the classic Messages code; `dm` from the pane: { blocked(), trusted(), unread() }.
    dm: dm && {
      me: ctx.session.pubkey,
      messages: () => getMessages().messages,
      blocked: dm.blocked, trusted: dm.trusted, unread: dm.unread,
      searchName: dm.searchName ?? (() => ""), follows: dm.follows ?? (() => false), lookup: dm.lookup ?? (() => {}),
      profile: pk => getProfile(pk),
      onChange: cb => onMessages(cb),
      // A photo takes the classic thread's own path (ConversationScreen.jsx): redrawn without its metadata
      // (preparePhoto), uploaded to your media servers, its link sent after the text; "(photo)" shows while it goes.
      async send(peer, text, photo = null) {
        const before = new Set([...getMessages().messages.values()].map(m => m.id))
        const preview = photo ? (text ? `${text}\n(photo)` : "(photo)") : null
        let sentText = text
        const opts = photo ? { preview, prepare: async () => (sentText = dmContent(text, (await uploadPhoto(await preparePhoto(photo), { ctx, servers: await mediaServers(ctx) })).url)) } : {}
        try { await sendMessage(ctx, peer, text, opts) } catch (e) {
          const failed = findMine(getMessages().messages, ctx.session.pubkey, peer, preview ?? text, true, before) ?? findMine(getMessages().messages, ctx.session.pubkey, peer, sentText, true, before)
          throw Object.assign(new Error(String(e?.fixed ? e.message : "The message wasn't sent.")), { failedId: failed?.id })
        }
        return findMine(getMessages().messages, ctx.session.pubkey, peer, sentText, false, before) ?? { id: `sent:${crypto.randomUUID()}`, from: ctx.session.pubkey, peer, content: sentText, at: Math.floor(Date.now() / 1000) }
      },
      // Try again / Remove: the classic thread's own buttons (ConversationScreen.jsx: m.resend(), dropFailed).
      async retry(id) {
        const old = getMessages().messages.get(id), before = new Set(getMessages().messages.keys())
        try { await old.resend() } catch (e) {
          const failed = newestMine(getMessages().messages, ctx.session.pubkey, old.peer, true, before)
          throw Object.assign(new Error(String(e?.fixed ? e.message : "The message wasn't sent.")), { failedId: failed?.id })
        }
        return newestMine(getMessages().messages, ctx.session.pubkey, old.peer, false, before) ?? { id: `sent:${crypto.randomUUID()}`, from: ctx.session.pubkey, peer: old.peer, content: old.content, at: Math.floor(Date.now() / 1000) }
      },
      discard: id => dropFailed(id),
      markRead: list => markRead(ctx.session.pubkey, list),
      ask,
      randomId: () => crypto.randomUUID(),
    },
    // Send Delay with Undo for what a napplet posts (publish-delay.js): the classic pill, in the shared toast.
    // -> true when the countdown ran out (sign and send), false on Undo.
    delay: template => new Promise(resolve => {
      const action = delayActionOf(template), key = `napplet-send:${crypto.randomUUID()}`
      let handle = null
      const pill = left => showToast({ key, icon: action === "repost" ? "repost" : "send", seconds: 0, message: countdownText(action, left), action: { label: "Undo", onClick: () => { if (handle?.cancel()) { hideToast(key); resolve(false) } } } })
      const seconds = sendDelaySeconds()
      handle = startCountdown({ seconds, onTick: pill, onDone: () => { hideToast(key); if (seconds > 0) showToast({ key, icon: "send", tone: "success", message: SEND_ACTIONS[action].done }); resolve(true) } })
      if (seconds > 0) pill(seconds)
    }),
    ask,
    saveGrant,
    bus,
    randomId: () => crypto.randomUUID(),
  }
}

const readRelaysOf = ctx => uniq([...(ctx.account.relays?.read ?? []), ...DEFAULT_RELAYS])

/** The Apps pane's catalog (P3): kind 35129 from the user's read relays, signatures checked, blocked publishers out. */
export async function readCatalog(ctx) {
  const evs = await pool.querySync(readRelaysOf(ctx), catalogFilter(), { maxWait: QUERY_WAIT_MS }).catch(() => [])
  return catalogEntries(evs, { verify: ev => { try { return verifyEvent(ev) } catch { return false } }, blocked: getBlocks().blocked })
}

/** An app's bytes from Blossom, hash-checked (catalog.js fetchArtifact): its servers, its publisher's, the usual ones. */
export const fetchAppArtifact = (ctx, event) => fetchArtifact(event, {
  fetchVerified, serverOrigin, usual: DEFAULT_MEDIA_SERVERS,
  authorServers: pk => authorServers(pk, readRelaysOf(ctx)),
})

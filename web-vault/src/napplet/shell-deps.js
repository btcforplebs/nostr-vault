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

const QUERY_WAIT_MS = 4000
const codeError = (code, message) => Object.assign(new Error(message ?? code), { code })

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
export function shellDeps(ctx, { ask, saveGrant, bus, storage = idbNappletStorage(ctx.session.pubkey) }) {
  const readRelays = () => uniq([...(ctx.account.relays?.read ?? []), ...DEFAULT_RELAYS])
  return {
    pubkey: ctx.session.pubkey,
    account: () => ctx.account,
    blocked: () => getBlocks().blocked,
    verify: ev => { try { return !!ev && verifyEvent(ev) } catch { return false } },
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
    // The vault: the user's own events (/), the feed cache (/feed) and what others sent them (/inbox).
    async vaultQuery(filters) {
      const routes = [ctx.vault.outbox, ctx.vault.feed, ctx.vault.inbox]
      return (await Promise.all(routes.map(r => r.query(filters).catch(() => [])))).flat()
    },
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

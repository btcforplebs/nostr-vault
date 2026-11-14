// The shell's answers to one napplet, per NAP domain. mountNapplet (host.js) calls handlers[domain](msg, napplet) only
// for domains the napplet was given; this file decides what each request may see or do (policy.js) and calls the
// shell's real pieces through `deps` (shell-deps.js wires them to Haven, the signer and the pool; tests pass fakes).
// Shell boundary (Logen's decisions 5 and 6): keys, Haven + FIPS and the network plumbing they need stay here;
// everything a napplet reads comes through these handlers, block-filtered, never from its own relay list.
// Reads (Logen 2026-11-14): Haven answers first; what the shell fetches from the network must pass the web of trust
// (wot-gate.js) and is put into Haven before a napplet sees it. Haven's public feed cache (/feed) keeps the feed
// kinds; anything it doesn't keep (likes, lists, zaps) still passes the same gate. Our own napplets too.
// Message shapes: @napplet/nap 0.40 types (outbox, relay, resource, storage, theme, intent, inc, notify, upload).
import { visibleEvents, seesPrivate, signDecision, resendDecision, deletionTargets, protectedKind } from "./policy.js"
import { nappletKey, nappletLine } from "./manifest.js"
import { blossomHandler } from "./blossom-dispatch.js"
import { dmHandler } from "./dm-dispatch.js"
import { DELAYED_KINDS } from "./publish-delay.js"

/** How long an upload may take before the answer is "uploading" (well inside the shim's 30 s wait). */
export const UPLOAD_ANSWER_MS = 20_000

/** "https://x/f.mp4#nv-bytes=0-8388607" -> { url: "https://x/f.mp4", range: { start: 0, end: 8388607 } }; any other
 *  link comes back as it is, with no range. Only http(s) links: a blossom: name is fetched whole and checked. */
export function rangeInUrl(url) {
  const m = typeof url === "string" ? /^(https?:\/\/[^#]*)#nv-bytes=(\d{1,15})-(\d{1,15})?$/i.exec(url) : null
  if (!m) return { url, range: undefined }
  const start = Number(m[2]), end = m[3] === undefined ? undefined : Number(m[3])
  if (end !== undefined && end < start) return { url, range: undefined }
  return { url: m[1], range: { start, end } }
}

export const MAX_EVENTS = 500
export const MAX_FILTERS = 10
export const STORAGE_KEY_MAX = 256
export const STORAGE_VALUE_MAX = 256 * 1024
export const STORAGE_KEYS_MAX = 500
export const MAX_SUBS = 16
/** How many network events an outside napplet may write into Haven's /feed per minute. Past it they are still
 *  handed over (gated), just not kept: a broad sub can't stream the whole web into the browser vault. */
export const OUTSIDE_STORE_PER_MIN = 300
export const MAX_URLS = 50

const list = f => (Array.isArray(f) ? f : f && typeof f === "object" ? [f] : [])
const dedupe = evs => { const seen = new Set(); return evs.filter(e => e?.id && !seen.has(e.id) && seen.add(e.id)) }
const newestFirst = evs => evs.sort((a, b) => b.created_at - a.created_at)
const err = e => String(e?.message || e)
const codeError = (code, message) => Object.assign(new Error(message ?? code), { code })

/** Filters as a napplet sent them -> at most MAX_FILTERS plain objects, each limit capped. Throws on garbage. */
export function cleanFilters(raw) {
  const fs = list(raw)
  if (!fs.length || fs.length > MAX_FILTERS || fs.some(f => !f || typeof f !== "object" || Array.isArray(f))) throw new Error("invalid filters")
  return fs.map(f => ({ ...f, limit: Math.min(Number.isInteger(f.limit) && f.limit > 0 ? f.limit : MAX_EVENTS, MAX_EVENTS) }))
}

/**
 * handlers for one mounted napplet. `ident`: { publisher, dTag, hash, title }. `grant`: policy.js grant (mutable:
 * a yes to notify is kept). `domains`: what it was given. `deps`: the shell (see shell-deps.js for each one).
 * -> { handlers, close } (close ends its subscriptions; host.js calls it on revoke).
 */
export function createHandlers({ ident, grant, domains, deps }) {
  const subs = new Map() // subId -> close()
  let dm = null // the dm domain's handler, made on first use (it pushes dm.message to this napplet)
  const uploads = new Map() // uploadId -> status
  const instanceScope = nappletKey(ident), sharedScope = nappletLine(ident)
  const who = { ...ident, grant }
  const ask = (what, detail) => deps.ask({ napplet: who, what, detail })

  // Reads: Haven first (all its routes for our own napplets, the public feed cache for outside ones), then the
  // network through the shell. Everything passes the WoT gate and the block list; network events that pass go into
  // Haven before they are handed over.
  const routes = () => (seesPrivate(grant) ? "all" : "public")
  const gateOf = async () => {
    const wot = await deps.wotGate().catch(() => ev => ev?.pubkey === deps.pubkey) // no web: only your own
    return ev => wot(ev) && visibleEvents([ev], grant, { blocked: deps.blocked() }).length > 0 // a block applies at once
  }
  let storeWindow = { start: -Infinity, used: 0 }
  const keepable = evs => {
    if (seesPrivate(grant)) return evs
    const t = (deps.now ?? Date.now)()
    if (t - storeWindow.start >= 60_000) storeWindow = { start: t, used: 0 }
    const take = evs.slice(0, Math.max(0, OUTSIDE_STORE_PER_MIN - storeWindow.used))
    storeWindow.used += take.length
    return take
  }
  const store = evs => { const keep = keepable(evs); return keep.length ? deps.havenStore(keep).catch(() => []) : Promise.resolve([]) }
  async function read(filters) {
    const fs = cleanFilters(filters)
    const limit = Math.max(...fs.map(f => f.limit))
    const pass = await gateOf()
    const fromHaven = (await deps.vaultQuery(fs, { routes: routes() }).catch(() => [])).filter(pass)
    const fromNet = fromHaven.length >= limit ? [] : (await deps.netQuery(fs).catch(() => [])).filter(pass)
    await store(dedupe(fromNet))
    return newestFirst(dedupe([...fromHaven, ...fromNet])).slice(0, limit)
  }
  const results = evs => evs.map(event => ({ event }))

  function subscribe(filters, napplet, onEvent, onEose) {
    if (subs.size >= MAX_SUBS) throw new Error(`at most ${MAX_SUBS} subscriptions`)
    const fs = cleanFilters(filters)
    let seen = new Set(), closed = false, stopNet = () => {}
    const mark = ev => {
      if (!ev?.id || seen.has(ev.id)) return false
      seen.add(ev.id)
      if (seen.size > 5000) seen = new Set([ev.id])
      return true
    }
    const start = async () => {
      const pass = await gateOf()
      for (const ev of await deps.vaultQuery(fs, { routes: routes() }).catch(() => [])) if (!closed && pass(ev) && mark(ev)) onEvent(ev)
      if (closed) return
      // Each network event in order: into Haven, then to the napplet.
      let queue = Promise.resolve()
      stopNet = deps.netSubscribe(fs, ev => {
        if (closed || !pass(ev) || !mark(ev)) return
        queue = queue.then(() => store([ev])).then(() => { if (!closed) onEvent(ev) })
      }, () => { queue = queue.then(() => { if (!closed) onEose?.() }) })
    }
    start()
    return () => { closed = true; stopNet() }
  }

  // A kind 5's `e` ids say nothing about what they delete, so the shell looks each one up (vault and network, never
  // shown to the napplet): every id must be found, be the user's, and not be an account list or a vanish request.
  // Otherwise "delete 1 post" could be the user's follow list.
  async function deletionRefusal(template) {
    const { ids } = deletionTargets(template)
    if (!ids.length) return null
    if (ids.length > MAX_EVENTS || ids.some(x => !/^[0-9a-f]{64}$/.test(x))) return "a deletion names ids it can't check"
    const fs = [{ ids, limit: ids.length }]
    const found = dedupe([...(await deps.vaultQuery(fs).catch(() => [])), ...(await deps.netQuery(fs).catch(() => []))])
    const byId = new Map(found.filter(ev => ev?.pubkey === deps.pubkey).map(ev => [ev.id, ev]))
    for (const x of ids) {
      const ev = byId.get(x)
      if (!ev) return "a deletion names an event of yours the shell can't find"
      if (protectedKind(ev.kind)) return `a napplet can't delete kind ${ev.kind}`
    }
    return null
  }

  async function signAndPublish(template, what) {
    const d = signDecision(grant, template)
    if (!d.ok) return { ok: false, error: d.error }
    const unsigned = { kind: template.kind, content: template.content, tags: template.tags ?? [], created_at: Math.floor(Date.now() / 1000) }
    if (unsigned.kind === 5) {
      const bad = await deletionRefusal(unsigned)
      if (bad) return { ok: false, error: bad }
    }
    if (d.ask && !(await ask(what, { kind: unsigned.kind, content: unsigned.content, tags: unsigned.tags }))) return { ok: false, error: "the user said no" }
    // The user's Send Delay with Undo (publish-delay.js): nothing is signed until it runs out.
    if (deps.delay && DELAYED_KINDS.has(unsigned.kind) && !(await deps.delay(unsigned))) return { ok: false, error: "undone" }
    unsigned.created_at = Math.floor(Date.now() / 1000)
    const event = await deps.sign(unsigned)
    const sent = await deps.publish(event)
    return { ok: !!sent.ok, event, eventId: event.id, relays: sent.relays ?? {}, ...(sent.ok ? {} : { error: sent.error ?? "no relay took it" }) }
  }

  const storageScope = m => (m.scope === "shared" ? sharedScope : instanceScope)

  const handlers = {
    shell: m => (m.type === "shell.ready" ? { type: "shell.init", capabilities: { domains: [...domains] }, services: [] } : undefined),

    identity: async m => {
      const id = m.id, acc = deps.account()
      switch (m.type) {
        case "identity.getPublicKey": return { type: `${m.type}.result`, id, pubkey: deps.pubkey }
        case "identity.getProfile": {
          let profile = null
          try { profile = acc.profileEvent ? JSON.parse(acc.profileEvent.content) : null } catch {}
          return { type: `${m.type}.result`, id, profile }
        }
        case "identity.getFollows": return { type: `${m.type}.result`, id, pubkeys: [...(acc.follows ?? [])] }
        case "identity.getRelays": {
          const relays = {}
          for (const u of acc.relays?.read ?? []) relays[u] = { read: true, write: false }
          for (const u of acc.relays?.write ?? []) relays[u] = { read: !!relays[u]?.read, write: true }
          return { type: `${m.type}.result`, id, relays }
        }
        case "identity.getMutes":
        case "identity.getBlocked":
          if (!seesPrivate(grant)) return { type: `${m.type}.result`, id, pubkeys: [], error: "private: only Nostr Vault's own napplets" }
          return { type: `${m.type}.result`, id, pubkeys: [...(deps.blocked() ?? [])] }
        default:
          return m.id ? { type: `${m.type}.result`, id, error: "unsupported" } : undefined
      }
    },

    theme: m => (m.type === "theme.get" ? { type: "theme.get.result", id: m.id, theme: deps.theme() } : undefined),

    storage: async m => {
      const scope = storageScope(m), id = m.id
      if (m.type === "storage.keys") return { type: "storage.keys.result", id, keys: await deps.storage.keys(scope) }
      if (typeof m.key !== "string" || !m.key || m.key.length > STORAGE_KEY_MAX) return { type: `${m.type}.result`, id, error: "invalid key", ...(m.type === "storage.get" ? { value: null } : {}) }
      if (m.type === "storage.get") return { type: "storage.get.result", id, value: (await deps.storage.get(scope, m.key)) ?? null }
      if (m.type === "storage.remove") { await deps.storage.remove(scope, m.key); return { type: "storage.remove.result", id } }
      if (m.type === "storage.set") {
        const value = String(m.value ?? "")
        if (value.length > STORAGE_VALUE_MAX) return { type: "storage.set.result", id, error: "quota-exceeded: value too large" }
        const keys = await deps.storage.keys(scope)
        if (!keys.includes(m.key) && keys.length >= STORAGE_KEYS_MAX) return { type: "storage.set.result", id, error: "quota-exceeded: too many keys" }
        await deps.storage.set(scope, m.key, value)
        return { type: "storage.set.result", id }
      }
    },

    outbox: async (m, napplet) => {
      const id = m.id
      switch (m.type) {
        case "outbox.query":
          try { return { type: "outbox.query.result", id, events: results(await read(m.filters)) } } catch (e) { return { type: "outbox.query.result", id, events: [], error: err(e) } }
        case "outbox.getEvent": {
          if (!/^[0-9a-f]{64}$/.test(m.eventId ?? "")) return { type: "outbox.getEvent.result", id, error: "invalid event id" }
          const [ev] = await read([{ ids: [m.eventId], limit: 1 }]).catch(() => [])
          return { type: "outbox.getEvent.result", id, ...(ev ? { result: { event: ev } } : { error: "not-found" }) }
        }
        case "outbox.subscribe": {
          if (typeof m.subId !== "string" || subs.has(m.subId)) return { type: "outbox.closed", subId: m.subId, reason: "invalid subId" }
          try {
            subs.set(m.subId, subscribe(m.filters, napplet, ev => napplet.send({ type: "outbox.event", subId: m.subId, result: { event: ev } })))
          } catch (e) { return { type: "outbox.closed", subId: m.subId, reason: err(e) } }
          return undefined
        }
        case "outbox.close": subs.get(m.subId)?.(); subs.delete(m.subId); return { type: "outbox.closed", subId: m.subId, reason: "closed" }
        case "outbox.publish":
          try { return { type: "outbox.publish.result", id, ...(await signAndPublish(m.event, "publish")) } } catch (e) { return { type: "outbox.publish.result", id, ok: false, error: err(e) } }
        case "outbox.resolveRelays": {
          const acc = deps.account()
          return { type: "outbox.resolveRelays.result", id, plan: { relays: [...(m.target?.direction === "read" ? acc.relays?.read ?? [] : acc.relays?.write ?? [])], source: "policy" } }
        }
      }
    },

    relay: async (m, napplet) => {
      const id = m.id
      switch (m.type) {
        case "relay.query":
          try { return { type: "relay.query.result", id, events: results(await read(m.filters)) } } catch (e) { return { type: "relay.query.result", id, events: [], error: err(e) } }
        case "relay.subscribe": {
          if (typeof m.subId !== "string" || subs.has(m.subId)) return { type: "relay.closed", subId: m.subId, reason: "invalid subId" }
          try {
            subs.set(m.subId, subscribe(m.filters, napplet,
              ev => napplet.send({ type: "relay.event", subId: m.subId, result: { event: ev } }),
              () => napplet.send({ type: "relay.eose", subId: m.subId })))
          } catch (e) { return { type: "relay.closed", subId: m.subId, reason: err(e) } }
          return undefined
        }
        case "relay.close": subs.get(m.subId)?.(); subs.delete(m.subId); return { type: "relay.closed", subId: m.subId, reason: "closed" }
        case "relay.publish": {
          // An event signed elsewhere (spreading already-signed notes): checked, then sent; the shell's key is not used.
          const ev = m.event
          if (!deps.verify(ev)) return { type: "relay.publish.result", id, ok: false, error: "invalid signature" }
          const rd = resendDecision(ev)
          if (!rd.ok) return { type: "relay.publish.result", id, ok: false, error: rd.error }
          const vis = visibleEvents([ev], grant)
          if (!vis.length) return { type: "relay.publish.result", id, ok: false, error: `kind ${ev.kind} is private; only Nostr Vault's own napplets handle it` }
          if (!grant.firstParty && !(await ask("relay-publish", { kind: ev.kind, content: ev.content, tags: ev.tags, author: ev.pubkey }))) return { type: "relay.publish.result", id, ok: false, error: "the user said no" }
          const sent = await deps.publish(ev)
          return { type: "relay.publish.result", id, ok: !!sent.ok, event: ev, eventId: ev.id, ...(sent.ok ? {} : { error: sent.error ?? "no relay took it" }) }
        }
        case "relay.publishEncrypted":
          // DMs are a napplet's job from P7 on (decision 5), on the shell's identity layer; not offered yet.
          return { type: "relay.publishEncrypted.result", id, ok: false, error: "unsupported" }
      }
    },

    resource: async m => {
      const id = m.id
      if (m.type === "resource.info") return { type: "resource.info.result", id, info: { schemes: deps.resourceSchemes().map(scheme => ({ scheme, enabled: true })), maxUrls: MAX_URLS } }
      if (m.type === "resource.cancel") return undefined
      const one = async (url, servers, range) => {
        if (typeof url !== "string" || url.length > 4096) throw codeError("invalid-request")
        const r = await deps.fetchBytes(url, { servers: Array.isArray(servers) ? servers.filter(s => typeof s === "string").slice(0, 8) : [], range, private: seesPrivate(grant) })
        return r
      }
      if (m.type === "resource.bytes") {
        try {
          // `range` ({ start, end? } bytes, inclusive end) is our extension: long video without the whole file first.
          // The shim (0.38) passes only url and servers on, so a napplet can also name the range in the link's
          // fragment ("#nv-bytes=START-END", rangeInUrl), which is never sent to a server.
          const inUrl = rangeInUrl(m.url)
          const range = m.range && Number.isInteger(m.range.start) && m.range.start >= 0 ? { start: m.range.start, end: Number.isInteger(m.range.end) ? m.range.end : undefined } : inUrl.range
          const { blob, mime } = await one(inUrl.url, m.servers, range)
          return { type: "resource.bytes.result", id, blob, mime }
        } catch (e) { return { type: "resource.bytes.error", id, error: e?.code ?? "network-error", message: err(e) } }
      }
      if (m.type === "resource.bytesMany") {
        const reqs = Array.isArray(m.requests) ? m.requests : []
        if (reqs.length > MAX_URLS) return { type: "resource.bytesMany.error", id, error: "too-large", message: `at most ${MAX_URLS} urls` }
        const items = await Promise.all(reqs.map(async r => {
          try { const { blob, mime } = await one(r?.url, r?.servers); return { url: r.url, ok: true, blob, mime } } catch (e) { return { url: r?.url, ok: false, error: e?.code ?? "network-error", message: err(e) } }
        }))
        return { type: "resource.bytesMany.result", id, items }
      }
    },

    // NAP-UPLOAD. An upload that finishes within UPLOAD_ANSWER_MS is answered with its result; a longer one (a big
    // video, a slow link, or the ask sheet left open) is answered "uploading" with its uploadId, and its end is pushed
    // as upload.status.changed (upload.status answers too). The shim gives up on any answer after 30 s, so a long
    // upload used to fail in the napplet while the shell went on and finished it.
    upload: async (m, napplet) => {
      const id = m.id
      if (m.type === "upload.info") return { type: "upload.info.result", id, info: { rails: [{ rail: "blossom", enabled: true, returns: ["url", "sha256"] }] } }
      if (m.type === "upload.status") return { type: "upload.status.result", id, ...(uploads.has(m.uploadId) ? { status: uploads.get(m.uploadId) } : { error: "not-found" }) }
      if (m.type !== "upload.upload") return undefined
      const req = m.request ?? {}
      const blob = req.data instanceof Blob ? req.data : req.data instanceof ArrayBuffer ? new Blob([req.data], { type: req.mimeType || "" }) : null
      if (!blob) return { type: "upload.upload.result", id, error: "data must be a Blob or ArrayBuffer" }
      const mime = req.mimeType || blob.type || "application/octet-stream"
      const uploadId = deps.randomId()
      const keep = r => { const st = { ...r, updatedAt: Date.now() }; uploads.set(uploadId, st); return st }
      const job = (async () => {
        if (!grant.firstParty && !(await ask("upload", { size: blob.size, mime, filename: typeof req.filename === "string" ? req.filename.slice(0, 120) : "" })))
          return { ok: false, uploadId, status: "cancelled", rail: "blossom", error: "the user said no" }
        try {
          const up = await deps.upload(blob, mime)
          return { ok: true, uploadId, status: "complete", rail: "blossom", url: up.url, sha256: up.sha256, size: up.size, mimeType: up.mime }
        } catch (e) { return { ok: false, uploadId, status: "failed", rail: "blossom", error: err(e) } }
      })()
      let timer = null
      const first = await Promise.race([job, new Promise(res => { timer = setTimeout(() => res(null), deps.uploadAnswerMs ?? UPLOAD_ANSWER_MS) })])
      clearTimeout(timer)
      if (first) { keep(first); return { type: "upload.upload.result", id, result: first } }
      const going = keep({ ok: true, uploadId, status: "uploading", rail: "blossom", bytesTotal: blob.size })
      job.then(done => napplet?.send({ type: "upload.status.changed", status: keep(done) }))
      return { type: "upload.upload.result", id, result: (({ updatedAt, ...r }) => r)(going) }
    },

    intent: (m, napplet) => {
      const id = m.id
      if (m.type === "intent.invoke") return deps.bus.invoke(napplet, m.request).then(result => ({ type: "intent.invoke.result", id, result }))
      if (m.type === "intent.available") return { type: "intent.available.result", id, availability: deps.bus.available(m.archetype) }
      if (m.type === "intent.handlers") return { type: "intent.handlers.result", id, handlers: deps.bus.handlers() }
    },

    inc: (m, napplet) => {
      if (m.type === "inc.emit") { deps.bus.emit(napplet, m.topic, m.payload); return undefined }
      if (m.type === "inc.subscribe") { const ok = deps.bus.subscribe(napplet, m.topic); return { type: "inc.subscribe.result", id: m.id, ...(ok ? {} : { error: "invalid topic" }) } }
      if (m.type === "inc.unsubscribe") { deps.bus.unsubscribe(napplet, m.topic); return undefined }
      if (m.type.startsWith("inc.channel.") && m.id) return { type: `${m.type}.result`, id: m.id, error: "unsupported" }
    },

    // The user's files on their media servers (blossom-dispatch.js): the shell signs every Blossom auth itself.
    blossom: deps.blossom ? blossomHandler({ grant, who, deps: deps.blossom }) : m => (m?.id ? { type: `${m.type}.result`, id: m.id, error: "unsupported" } : undefined),

    // Direct messages through the shell's own DM stack (dm-dispatch.js): keys, decryption and sealing stay here.
    dm: deps.dm ? (m, napplet) => (dm ??= dmHandler({ grant, who, deps: deps.dm, push: x => napplet.send(x) })).handle(m) : m => (m?.id ? { type: `${m.type}.result`, id: m.id, error: "unsupported" } : undefined),

    notify: async m => {
      const id = m.id
      const allowed = async () => {
        if (grant.notify) return true
        if (!(await ask("notify", {}))) return false
        grant.notify = true
        deps.saveGrant(grant)
        return true
      }
      if (m.type === "notify.permission.request") return { type: "notify.permission.result", id, granted: await allowed() }
      if (m.type === "notify.send") {
        if (!(await allowed())) return { type: "notify.send.result", id, error: "not allowed" }
        const notificationId = await deps.notify({ title: String(m.title ?? "").slice(0, 120), body: String(m.body ?? "").slice(0, 500), from: ident.title })
        return { type: "notify.send.result", id, notificationId }
      }
      return undefined // badge, dismiss, channel.register: nothing to show yet
    },
  }

  const close = () => { for (const stop of subs.values()) try { stop() } catch {} subs.clear(); dm?.close() }
  return { handlers, close }
}

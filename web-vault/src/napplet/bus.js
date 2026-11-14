// What napplets say to each other, through the shell: INC topics (emit to everyone subscribed but the sender) and
// INTENT (one napplet asks for an archetype's action; the shell finds a handler, opens it if needed, and delivers).
// One bus per shell page. Pure apart from what `open` does, so node tests drive it.
const TOPIC = /^[\w.:/-]{1,128}$/

/**
 * handlers: [{ id, title, archetype, actions: [..], conventions: [..], open: () => Promise<napplet> }]: napplets that
 * can take an intent (or `deliver: (payload, from) => result` for one the shell answers itself, with no napplet) (first-party ones are listed by the shell; a manifest's `i` tags in P3).
 */
export function createBus({ handlers = [] } = {}) {
  const topics = new Map() // topic -> Set(napplet)
  const registry = [...handlers]

  const emit = (from, topic, payload) => {
    if (typeof topic !== "string" || !TOPIC.test(topic)) return
    for (const n of topics.get(topic) ?? []) if (n !== from) n.send({ type: "inc.event", topic, sender: from.dTag, payload })
  }
  const subscribe = (n, topic) => {
    if (typeof topic !== "string" || !TOPIC.test(topic)) return false
    if (!topics.has(topic)) topics.set(topic, new Set())
    topics.get(topic).add(n)
    return true
  }
  const unsubscribe = (n, topic) => topics.get(topic)?.delete(n)
  const forget = n => { for (const s of topics.values()) s.delete(n) }

  const candidates = archetype => registry.filter(h => h.archetype === archetype)
  const availability = archetype => {
    const c = candidates(archetype)
    return { archetype, available: c.length > 0, hasDefault: c.length > 0, candidates: c.map((h, i) => ({ id: h.id, title: h.title, actions: h.actions, conventions: h.conventions, contracts: [], isDefault: i === 0 })) }
  }

  async function invoke(from, req) {
    if (!req || typeof req.archetype !== "string" || typeof req.action !== "string") return { ok: false, error: "invalid request" }
    const wanted = typeof req.handler === "string" ? req.handler : req.handler?.id
    const fit = candidates(req.archetype).filter(h => h.actions.includes(req.action) && (!req.convention || !h.conventions.length || h.conventions.includes(req.convention)))
    const h = (wanted && fit.find(x => x.id === wanted)) || fit[0]
    if (!h) return { ok: false, error: "no handler", archetype: req.archetype, action: req.action }
    try {
      // A shell-handled intent (link/open): no napplet to open, the shell does it itself.
      if (h.deliver) {
        const r = await h.deliver(req.payload, from)
        return r?.ok === false ? { ok: false, error: r.error ?? "refused", archetype: req.archetype, action: req.action } : { ok: true, archetype: req.archetype, action: req.action, convention: req.convention ?? "", handler: h.id }
      }
      const target = await h.open()
      target.send({ type: "intent.deliver", delivery: { sender: from.dTag, archetype: req.archetype, action: req.action, convention: req.convention ?? "", payload: req.payload } })
      return { ok: true, archetype: req.archetype, action: req.action, convention: req.convention ?? "", handler: h.id }
    } catch (e) {
      return { ok: false, error: String(e?.message || e), archetype: req.archetype, action: req.action }
    }
  }

  return {
    emit, subscribe, unsubscribe, forget, invoke,
    available: availability,
    handlers: () => [...new Set(registry.map(h => h.archetype))].map(availability),
    register: h => { registry.push(h); return () => registry.splice(registry.indexOf(h), 1) },
  }
}

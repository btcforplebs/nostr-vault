// Datagram fabric shaped like FipsNode: sendDatagram, and inbound datagrams as "datagram" events (how @fips/core
// delivers FSP port 256, which can't be registered as a service). Optional loss with a seeded PRNG.
export function nodeFabric(loss = 0, seed = 11) {
  let s = seed
  const rnd = () => ((s = (s * 1103515245 + 12345) >>> 0) / 2 ** 32)
  const nodes = new Map(), queue = []
  const node = key => {
    const listeners = new Set()
    nodes.set(key, listeners)
    return {
      on: (event, cb) => (event === "datagram" && listeners.add(cb), () => listeners.delete(cb)),
      sendDatagram: async ({ dst, srcPort, dstPort, payload }) => { if (rnd() >= loss) queue.push({ src: key, dst, srcPort, dstPort, payload: payload.slice() }) },
    }
  }
  // `tamper(d)` may rewrite a datagram in flight.
  const deliver = async (tamper = d => d) => {
    for (const d of queue.splice(0)) for (const cb of nodes.get(d.dst) ?? []) await cb(tamper(d))
  }
  return { node, deliver, queue }
}

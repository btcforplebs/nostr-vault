// Datagram fabric: queue per step, optional loss with a seeded PRNG.
export function fabric(loss = 0, seed = 7) {
  let s = seed
  const rnd = () => ((s = (s * 1103515245 + 12345) >>> 0) / 2 ** 32)
  const nodes = new Map(), queue = []
  const endpoint = key => {
    const handlers = new Map()
    nodes.set(key, handlers)
    return {
      registerService: (port, h) => (handlers.set(port, h), () => handlers.delete(port)),
      sendDatagram: async ({ dst, srcPort, dstPort, payload }) => { if (rnd() >= loss) queue.push({ src: key, dst, srcPort: srcPort ?? dstPort, dstPort, payload: payload.slice() }) },
    }
  }
  const deliver = async () => {
    for (const d of queue.splice(0)) await nodes.get(d.dst)?.get(d.dstPort)?.({ src: d.src, srcPort: d.srcPort, dstPort: d.dstPort, payload: d.payload })
  }
  return { endpoint, deliver }
}


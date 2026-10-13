// In-memory FIPS datagram fabric: two or more endpoints exchange datagrams through a queue that
// the caller drains with deliver(). Same shape as test/tcp-server.test.mjs, without loss.
export function fabric() {
  const nodes = new Map(), queue = []
  const endpoint = key => {
    const handlers = new Map()
    nodes.set(key, handlers)
    return {
      registerService: (port, h) => (handlers.set(port, h), () => handlers.delete(port)),
      sendDatagram: async ({ dst, srcPort, dstPort, payload }) => {
        queue.push({ src: key, dst, srcPort: srcPort ?? dstPort, dstPort, payload: payload.slice() })
      },
    }
  }
  const deliver = async () => {
    for (const d of queue.splice(0)) await nodes.get(d.dst)?.get(d.dstPort)?.({ src: d.src, srcPort: d.srcPort, dstPort: d.dstPort, payload: d.payload })
  }
  return { endpoint, deliver }
}

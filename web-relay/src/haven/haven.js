// Loads Haven (haven-go built for js/wasm) into the page and exposes its JS entry point:
//   start(cfg) -> Promise, conn(id, opts) -> { write, onData, onClose, close, buffered?, error? }, stop() -> Promise
// A refused conn doesn't throw: it comes back already closed, with `error` set. buffered() is the bytes
// written but not yet consumed by Haven.
// Contract: Ted's integration branch, haven-go wasm entry point (havenStart / havenConn / havenStop).
const READY_MS = 30_000

/** Boot the Go runtime once and wait for the entry point globals. */
export async function loadHaven(wasmUrl = new URL("./haven.wasm", document.baseURI)) {
  // Go's runtime shim; defines globalThis.Go. Copied from $(go env GOROOT) by tools/build-haven-wasm.sh.
  await import("./wasm_exec.js")
  const go = new globalThis.Go()
  const res = wasmResponse(wasmUrl)
  const { instance } = await WebAssembly.instantiateStreaming(res, go.importObject).catch(async e => {
    // instantiateStreaming needs Content-Type application/wasm; fall back for hosts that get it wrong.
    const r = await fetch(wasmUrl)
    if (!r.ok) throw new Error(`haven.wasm: HTTP ${r.status}`)
    return WebAssembly.instantiate(await r.arrayBuffer(), go.importObject).catch(() => Promise.reject(e))
  })
  let exited = false
  go.run(instance).finally(() => (exited = true))
  const t0 = Date.now()
  while (typeof globalThis.havenStart !== "function") {
    if (exited) throw new Error("haven.wasm exited before registering its entry point")
    if (Date.now() - t0 > READY_MS) throw new Error("haven.wasm: entry point not registered in time")
    await new Promise(r => setTimeout(r, 10))
  }
  return wrap(globalThis)
}

/**
 * The wasm's response: the one web-vault's boot script (nv-preload.js bootScript) already started for this same URL,
 * taken once, else a fetch of its own. A failed or refused early one is fetched again. One download in every engine:
 * Safari's never handed a <link rel=preload> to this fetch, and downloaded the wasm twice (Tidy's audit 11-20, W5).
 */
export function wasmResponse(wasmUrl, g = globalThis, get = url => fetch(url)) {
  const early = g.__nvHavenWasm
  let href = null
  try { href = new URL(String(wasmUrl), g.document?.baseURI).href } catch {}
  if (!early || !href || early.href !== href) return get(wasmUrl)
  delete g.__nvHavenWasm
  return Promise.resolve(early.res).then(r => (r?.ok ? r : get(wasmUrl)), () => get(wasmUrl))
}

/** The entry point as a handle. Also used with the test stub, which exposes the same three functions. */
export function wrap(g) {
  return {
    start: cfg => g.havenStart(cfg),
    conn: (id, opts) => g.havenConn(String(id), opts),
    stop: () => g.havenStop(),
  }
}

// H3 proof driver: serves tools/haven-proof with Vite, runs it in headless Chrome, page and/or worker,
// phase 1 then a real reload into phase 2 in the same profile.
//
//   HAVEN_GO=~/.buzz/REPOS/haven-wasm-h1/haven-go node tools/haven-proof/run.mjs      # builds haven.wasm
//   HAVEN_WASM=/path/haven.wasm CONTEXT=worker node tools/haven-proof/run.mjs          # prebuilt, worker only
//
// CONTEXT = page | worker | both (default both). CHROME overrides the browser path. Exit 0 only if every check passes.
import { spawn, execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, existsSync, copyFileSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { randomBytes } from "node:crypto"
import { createServer } from "vite"

const here = dirname(fileURLToPath(import.meta.url))
const webRelay = resolve(here, "../..")
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const contexts = { page: ["page"], worker: ["worker"], both: ["page", "worker"] }[process.env.CONTEXT || "both"]
const pub = mkdtempSync(join(tmpdir(), "haven-proof-pub-"))

let wasm = process.env.HAVEN_WASM
if (process.env.STUB) console.log("STUB=1: JS stand-in for havenConn, checks the harness only")
else if (!wasm) {
  if (!process.env.HAVEN_GO) throw new Error("set HAVEN_WASM or HAVEN_GO")
  wasm = join(pub, "haven.wasm")
  const t0 = Date.now()
  execFileSync("go", ["build", "-o", wasm, "."], { cwd: process.env.HAVEN_GO, env: { ...process.env, GOOS: "js", GOARCH: "wasm" }, stdio: "inherit" })
  const rev = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: process.env.HAVEN_GO }).toString().trim()
  console.log(`built haven.wasm at ${rev} in ${Date.now() - t0} ms, ${(statSync(wasm).size / 1e6).toFixed(1)} MB`)
} else copyFileSync(wasm, join(pub, "haven.wasm"))
copyFileSync(join(execFileSync("go", ["env", "GOROOT"]).toString().trim(), "lib/wasm/wasm_exec.js"), join(pub, "wasm_exec.js"))

const vite = await createServer({
  configFile: false, root: here, publicDir: pub, logLevel: "warn",
  server: { host: "127.0.0.1", port: 0, fs: { allow: [webRelay] } },
  worker: { format: "es" },
})
await vite.listen()
const origin = `http://127.0.0.1:${vite.httpServer.address().port}`

const results = []
for (const context of contexts) results.push(...(await runContext(context)))
await vite.close()
rmSync(pub, { recursive: true, force: true })

let fail = 0
for (const r of results) {
  console.log(`\n== ${r.context} phase ${r.phase}: ${r.ok ? "PASS" : "FAIL"}  ${JSON.stringify(r.data)}`)
  for (const c of r.checks) {
    if (!c.pass) fail++
    console.log(`  ${c.pass ? "ok  " : "FAIL"} ${c.name}${c.pass && !process.env.VERBOSE ? "" : "  " + c.detail}`)
  }
}
console.log(`\n${fail ? `${fail} check(s) failed` : "all checks passed"}`)
process.exit(fail ? 1 : 0)

async function runContext(context) {
  const profile = mkdtempSync(join(tmpdir(), "haven-proof-chrome-"))
  const proc = spawn(chrome, ["--headless=new", "--no-proxy-server", "--no-first-run", "--no-default-browser-check",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" })
  const out = []
  try {
    const portFile = join(profile, "DevToolsActivePort")
    for (let i = 0; i < 200 && !existsSync(portFile); i++) await sleep(50)
    const port = readFileSync(portFile, "utf8").split("\n")[0]
    const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === "page")
    const cdp = await connect(page.webSocketDebuggerUrl)
    cdp.on("Runtime.consoleAPICalled", p => process.stderr.write(`[${context}] ${p.args.map(a => a.value ?? a.description ?? "").join(" ")}\n`))
    cdp.on("Runtime.exceptionThrown", p => process.stderr.write(`[${context}] exception: ${p.exceptionDetails.exception?.description ?? p.exceptionDetails.text}\n`))
    await cdp.send("Runtime.enable")
    await cdp.send("Page.enable")

    const params = { context, stub: !!process.env.STUB, ownerSk: randomBytes(32).toString("hex"), strangerSk: randomBytes(32).toString("hex") }
    for (const phase of [1, 2]) {
      const hash = encodeURIComponent(JSON.stringify({ ...params, phase }))
      const loaded = cdp.once("Page.loadEventFired")
      if (phase === 1) await cdp.send("Page.navigate", { url: `${origin}/index.html#${hash}` })
      else {
        await evaluate(cdp, `location.hash = ${JSON.stringify(hash)}`)
        await cdp.send("Page.reload", { ignoreCache: true })
      }
      await loaded
      let r
      for (const end = Date.now() + 120_000; Date.now() < end && !(r = await evaluate(cdp, "window.__result")); ) await sleep(100)
      r ??= { ok: false, checks: [{ name: "result before timeout", pass: false, detail: "no window.__result in 120 s" }], data: {} }
      out.push({ context, phase, ...r })
      params.noteId = r.data?.noteId ?? params.noteId
    }
  } finally {
    proc.kill("SIGKILL")
    rmSync(profile, { recursive: true, force: true })
  }
  return out
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)) }

async function evaluate(cdp, expression) {
  const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true })
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text)
  return r.result.value
}

async function connect(url) {
  const ws = new WebSocket(url)
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
  let nextId = 1
  const pending = new Map(), listeners = new Map()
  ws.onmessage = m => {
    const msg = JSON.parse(m.data)
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id)
      pending.delete(msg.id)
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result)
    } else if (msg.method) for (const fn of listeners.get(msg.method) ?? []) fn(msg.params)
  }
  const on = (method, fn) => listeners.set(method, [...(listeners.get(method) ?? []), fn])
  return {
    send: (method, params = {}) => new Promise((resolve, reject) => {
      const id = nextId++
      pending.set(id, { resolve, reject })
      ws.send(JSON.stringify({ id, method, params }))
    }),
    on,
    once: method => new Promise(resolve => {
      const fn = p => { listeners.set(method, (listeners.get(method) ?? []).filter(f => f !== fn)); resolve(p) }
      on(method, fn)
    }),
  }
}

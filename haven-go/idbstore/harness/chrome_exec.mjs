// go test -exec target for GOOS=js GOARCH=wasm: serves the test binary to a
// headless Chrome with a fresh profile and streams its console to stdout.
//
// Every binary runs twice in the same profile: IDBSTORE_PHASE=1, then a real
// Page.reload (new document, new Go runtime, same IndexedDB), then
// IDBSTORE_PHASE=2. The exit code is the worst of the two runs.
//
// Needs Node 22+ (global WebSocket).
//
// Environment:
//   IDBSTORE_CONTEXT=page|worker   where the Go binary runs (default page)
//   IDBSTORE_TARGET=desktop|android
//     desktop: spawns headless Chrome with a throwaway profile (CHROME= path).
//     android: uses Chrome on the adb device (ANDROID_SERIAL, ADB=) in a new tab
//       on http://localhost:IDBSTORE_PORT via adb reverse. That origin's storage
//       is cleared before and after, and the tab is closed. Nothing else in the
//       browser is touched.

import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [wasmPath, ...args] = process.argv.slice(2);
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const goroot = execFileSync("go", ["env", "GOROOT"]).toString().trim();
const timeoutMs = Number(process.env.IDBSTORE_TIMEOUT_MS || 30 * 60 * 1000);

const target = process.env.IDBSTORE_TARGET || "desktop";
const context = process.env.IDBSTORE_CONTEXT || "page";
const adbBin = process.env.ADB || "/opt/homebrew/bin/adb";
const adb = (...a) => execFileSync(adbBin, [...(process.env.ANDROID_SERIAL ? ["-s", process.env.ANDROID_SERIAL] : []), ...a]).toString().trim();

const files = {
  "/index.html": ["text/html", readFileSync(join(here, "index.html"))],
  "/wasm_exec.js": ["text/javascript", readFileSync(join(goroot, "lib/wasm/wasm_exec.js"))],
  "/worker.js": ["text/javascript", readFileSync(join(here, "worker.js"))],
  "/test.wasm": ["application/wasm", readFileSync(wasmPath)],
};
const server = createServer((req, res) => {
  const f = files[new URL(req.url, "http://x").pathname];
  if (!f) { res.writeHead(404).end(); return; }
  res.writeHead(200, { "content-type": f[0], "cache-control": "no-store" }).end(f[1]);
});
const listenPort = target === "android" ? Number(process.env.IDBSTORE_PORT || 47123) : 0;
await new Promise((r) => server.listen(listenPort, "127.0.0.1", r));
const port0 = server.address().port;
const origin = target === "android" ? `http://localhost:${port0}` : `http://127.0.0.1:${port0}`;

let exitCode = 1;
const cleanups = [() => server.close()];
const cleanup = async () => {
  for (const fn of cleanups.reverse()) { try { await fn(); } catch {} }
};
process.on("SIGINT", async () => { await cleanup(); process.exit(130); });
const deadline = setTimeout(async () => { console.error("chrome_exec: timed out"); await cleanup(); process.exit(124); }, timeoutMs);

// Returns the page's webSocketDebuggerUrl.
async function openPage() {
  if (target === "android") {
    adb("reverse", `tcp:${port0}`, `tcp:${port0}`);
    cleanups.push(() => adb("reverse", "--remove", `tcp:${port0}`));
    const fwd = adb("forward", "tcp:0", "localabstract:chrome_devtools_remote");
    cleanups.push(() => adb("forward", "--remove", `tcp:${fwd}`));
    // Android Chrome refuses /json/new; the browser target can still open a tab.
    // Foreground, so the page runs visible the way a real one would.
    const version = await (await fetch(`http://127.0.0.1:${fwd}/json/version`)).json();
    const browser = await connect(version.webSocketDebuggerUrl);
    const { targetId } = await browser.send("Target.createTarget", { url: "about:blank" });
    cleanups.push(() => browser.send("Target.closeTarget", { targetId }));
    for (let i = 0; i < 50; i++) {
      const page = (await (await fetch(`http://127.0.0.1:${fwd}/json/list`)).json()).find((t) => t.id === targetId);
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
      await sleep(100);
    }
    throw new Error("new tab never showed up in /json/list");
  }
  const profile = mkdtempSync(join(tmpdir(), "idbstore-chrome-"));
  const proc = spawn(chrome, [
    "--headless=new", "--no-proxy-server", "--no-first-run", "--no-default-browser-check",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank",
  ], { stdio: "ignore" });
  cleanups.push(() => rmSync(profile, { recursive: true, force: true }));
  cleanups.push(() => proc.kill("SIGKILL"));
  const portFile = join(profile, "DevToolsActivePort");
  for (let i = 0; i < 200 && !existsSync(portFile); i++) await sleep(50);
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  return targets.find((t) => t.type === "page").webSocketDebuggerUrl;
}

try {
  const cdp = await connect(await openPage());
  const clearOrigin = () => cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  if (target === "android") {
    await clearOrigin();
    cleanups.push(clearOrigin);
  }

  cdp.on("Runtime.consoleAPICalled", (p) => {
    const line = p.args.map((a) => a.value ?? a.description ?? "").join(" ");
    (p.type === "error" ? process.stderr : process.stdout).write(line + "\n");
  });
  cdp.on("Runtime.exceptionThrown", (p) => {
    process.stderr.write(`chrome_exec: page exception: ${p.exceptionDetails.exception?.description ?? p.exceptionDetails.text}\n`);
  });
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");

  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => k.startsWith("IDBSTORE_") || k === "GOTRACEBACK"));
  const codes = [];
  for (const phase of [1, 2]) {
    const loaded = cdp.once("Page.loadEventFired");
    if (phase === 1) await cdp.send("Page.navigate", { url: `${origin}/index.html#phase=1` });
    else {
      await evaluate(cdp, `location.hash = "phase=2"`);
      await cdp.send("Page.reload", { ignoreCache: true });
    }
    await loaded;
    if (phase === 1) {
      const info = await evaluate(cdp, `(async () => JSON.stringify({ ua: navigator.userAgent, visibility: document.visibilityState,
        persistBefore: await navigator.storage.persisted(), persist: await navigator.storage.persist(),
        persistAfter: await navigator.storage.persisted() }))()`, true);
      process.stderr.write(`chrome_exec: ${target} ${context} ${origin} ${info}\n`);
    }
    const t0 = Date.now();
    await evaluate(cdp, `window.__run(${JSON.stringify({ args, env, context })}); 0`);
    let code;
    while ((code = await evaluate(cdp, "window.__exit")) === undefined) await sleep(100);
    const inst = await evaluate(cdp, "window.__instantiateMs");
    process.stderr.write(`chrome_exec: phase ${phase} exit ${code} in ${Date.now() - t0} ms (wasm instantiate ${Math.round(inst)} ms)\n`);
    codes.push(code);
  }
  exitCode = Math.max(...codes);
} catch (e) {
  console.error("chrome_exec:", e);
  exitCode = 1;
} finally {
  clearTimeout(deadline);
  await cleanup();
}
process.exit(exitCode);

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function evaluate(cdp, expression, awaitPromise = false) {
  const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let nextId = 1;
  const pending = new Map();
  const listeners = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
    } else if (msg.method) {
      for (const fn of listeners.get(msg.method) ?? []) fn(msg.params);
    }
  };
  const on = (method, fn) => { listeners.set(method, [...(listeners.get(method) ?? []), fn]); };
  return {
    send: (method, params = {}) => new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    }),
    on,
    once: (method) => new Promise((resolve) => {
      const fn = (p) => { listeners.set(method, (listeners.get(method) ?? []).filter((f) => f !== fn)); resolve(p); };
      on(method, fn);
    }),
  };
}

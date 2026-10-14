// The service worker keeps the app usable offline from the first visit: at install it stores the app shell
// (index.html and the files it links), and a navigation it has never seen falls back to that shell offline.
// sw.js runs here against a fake worker global: `self`, `caches`, `fetch` and `location`, like a worker's.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const SW = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8")
const ORIGIN = "https://vault.example", SCOPE = `${ORIGIN}/vault/`
const INDEX = `<!doctype html><html><head><link rel="manifest" href="./manifest.json">
<link rel="apple-touch-icon" sizes="180x180" href="./icon-180.png">
<script type="module" crossorigin src="/vault/assets/index-Ab12Cd34.js"></script>
<link rel="stylesheet" crossorigin href="/vault/assets/index-Ef56Gh78.css">
<link rel="preconnect" href="https://fonts.example/x"></head><body></body></html>`

// A Cache / CacheStorage pair that matches on URL, with the ignoreSearch option.
function cacheStorage() {
  const stores = new Map()
  const key = (r, o) => { const u = new URL(typeof r === "string" ? r : r.url); if (o?.ignoreSearch) u.search = ""; return u.href }
  const cache = () => {
    const m = new Map()
    return {
      async match(r, o) { const k = key(r, o); for (const [u, res] of m) if (key(u, o) === k) return res.clone(); return undefined },
      async put(r, res) { m.set(key(r), res) },
      async delete(r) { return m.delete(key(r)) },
      async keys() { return [...m.keys()].map(u => new Request(u)) },
    }
  }
  return {
    async open(n) { if (!stores.has(n)) stores.set(n, cache()); return stores.get(n) },
    async keys() { return [...stores.keys()] },
    async delete(n) { return stores.delete(n) },
    async match(r, o) { for (const c of stores.values()) { const h = await c.match(r, o); if (h) return h } return undefined },
  }
}

// Loads sw.js into a worker-like global. `files` is what the network serves (url -> body); offline rejects every fetch.
function worker({ files = {}, offline = false } = {}) {
  const listeners = {}, fetched = []
  const caches = cacheStorage()
  const self = {
    skipWaiting: async () => {}, clients: { claim: async () => {} },
    addEventListener: (t, f) => (listeners[t] = f),
  }
  const fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url
    fetched.push(url)
    if (offline) throw new TypeError("Failed to fetch")
    const f = files[new URL(url).pathname]
    if (!f) return new Response("missing", { status: 404 })
    return new Response(f.body, { status: 200, headers: { "Content-Type": f.type, ETag: f.etag || `"${f.body.length}"` } })
  }
  const ctx = { self, caches, fetch, location: new URL("sw.js", SCOPE), Request, Response, URL, console }
  ctx.globalThis = ctx
  vm.runInNewContext(SW, ctx)
  const fire = (type, ev) => {
    const waits = [], responses = []
    listeners[type]({ ...ev, waitUntil: p => waits.push(p), respondWith: p => responses.push(p) })
    return Promise.all(waits).then(() => Promise.all(responses))
  }
  return { fire, caches, fetched }
}

// Node's Request refuses mode "navigate"; the worker only reads url, method and mode off a navigation request.
const nav = url => ({ url, method: "GET", mode: "navigate" })

const site = {
  "/vault/": { body: INDEX, type: "text/html" },
  "/vault/manifest.json": { body: "{}", type: "application/json" },
  "/vault/icon-180.png": { body: "png", type: "image/png" },
  "/vault/assets/index-Ab12Cd34.js": { body: "js", type: "text/javascript" },
  "/vault/assets/index-Ef56Gh78.css": { body: "css", type: "text/css" },
}

test("install stores the app shell: index.html and every same-origin file it links", async () => {
  const w = worker({ files: site })
  await w.fire("install")
  const c = await w.caches.open("nv-web-vault-v2")
  for (const p of Object.keys(site)) assert.ok(await c.match(`${ORIGIN}${p}`), `${p} is cached at install`)
  assert.ok(!w.fetched.some(u => u.startsWith("https://fonts.example")), "other origins are not fetched")
  assert.equal(await (await c.match(SCOPE)).text(), INDEX)
})

test("after the first visit, a reload offline is served from the cache", async () => {
  const w = worker({ files: site })
  await w.fire("install")
  // The network is gone. The worker's fetch handler must answer the page and its script from the cache.
  const off = worker({ files: {}, offline: true })
  const c = await off.caches.open("nv-web-vault-v2"), src = await w.caches.open("nv-web-vault-v2")
  for (const r of await src.keys()) await c.put(r, await src.match(r))
  const [page] = await off.fire("fetch", { request: nav(SCOPE) })
  assert.equal(page?.status, 200, "index.html comes from the cache")
  assert.equal(await page.text(), INDEX)
  const [js] = await off.fire("fetch", { request: new Request(`${SCOPE}assets/index-Ab12Cd34.js`) })
  assert.equal(await js.text(), "js", "the hashed script comes from the cache without touching the network")
  assert.ok(!off.fetched.includes(`${SCOPE}assets/index-Ab12Cd34.js`), "a cached asset is not fetched")
})

test("offline, a page URL never seen gets the shell, as the server would send index.html", async () => {
  const w = worker({ files: site })
  await w.fire("install")
  const off = worker({ offline: true })
  const c = await off.caches.open("nv-web-vault-v2"), src = await w.caches.open("nv-web-vault-v2")
  for (const r of await src.keys()) await c.put(r, await src.match(r))
  const [page] = await off.fire("fetch", { request: nav(`${SCOPE}?note=abc`) })
  assert.equal(await page.text(), INDEX)
  const [sub] = await off.fire("fetch", { request: new Request(`${SCOPE}never.json`) })
  assert.equal(sub, undefined, "a non-page request that was never cached stays a network failure")
})

test("a page not served offline is still an error, not an empty response, when there is no shell", async () => {
  const off = worker({ offline: true })
  const [page] = await off.fire("fetch", { request: nav(SCOPE) })
  assert.equal(page, undefined)
})

test("activate moves the v1 cache into v2 and deletes it", async () => {
  const w = worker({ files: site })
  const v1 = await w.caches.open("nv-web-vault-v1")
  await v1.put(new Request(`${SCOPE}assets/old-Zz00Yy11.js`), new Response("old", { headers: { "Content-Type": "text/javascript" } }))
  await w.fire("activate")
  const c = await w.caches.open("nv-web-vault-v2")
  assert.equal(await (await c.match(`${SCOPE}assets/old-Zz00Yy11.js`)).text(), "old")
  assert.deepEqual(await w.caches.keys(), ["nv-web-vault-v2"])
})

test("hashed assets are cache first: a second request does not hit the network", async () => {
  const w = worker({ files: site })
  const url = `${SCOPE}assets/index-Ab12Cd34.js`
  await w.fire("fetch", { request: new Request(url) })
  await new Promise(r => setTimeout(r, 0))
  const before = w.fetched.length
  const [res] = await w.fire("fetch", { request: new Request(url) })
  assert.equal(await res.text(), "js")
  assert.equal(w.fetched.length, before, "served from the cache")
})

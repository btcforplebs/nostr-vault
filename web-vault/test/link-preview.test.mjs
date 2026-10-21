// Link cards read a page's OpenGraph from this browser itself (link-preview.js): no server, no proxy.
import test from "node:test"
import assert from "node:assert/strict"
import { canPreview, decodeEntities, parseOpenGraph, fetchPreview, preview, resetPreviews } from "../src/components/link-preview.js"

const page = (html, { type = "text/html; charset=utf-8", status = 200, url = "" } = {}) =>
  ({ ok: status >= 200 && status < 300, status, url, headers: new Headers({ "content-type": type }), body: new Response(html).body, text: async () => html })

test("only public https pages are fetched", () => {
  for (const u of ["https://example.com/a", "https://news.ycombinator.com/item?id=1"]) assert.equal(canPreview(u), true, u)
  for (const u of ["http://example.com/", "https://localhost/", "https://127.0.0.1/", "https://192.168.1.1/", "https://10.0.0.5/",
    "https://[::1]/", "https://[fe80::1]/", "https://router.local/", "https://x.onion/", "javascript:alert(1)", "", null])
    assert.equal(canPreview(u), false, String(u))
})

test("og tags in either attribute order, name= too, entities decoded, <title> as the fallback", () => {
  const html = `<html><head><title>Fallback</title>
    <meta content="Bob&#39;s &amp; Co &#x2019;s" property="og:title">
    <meta name="og:description" content='Line one
      line two'>
    <meta property="og:site_name" content="Bob's Blog" />
    <meta property="og:image" content="/img/card.png?x=1&amp;y=2">`
  assert.deepEqual(parseOpenGraph(html, "https://bob.example/post/1"), {
    title: "Bob's & Co ’s", description: "Line one line two", siteName: "Bob's Blog", image: "https://bob.example/img/card.png?x=1&y=2",
  })
  assert.equal(parseOpenGraph("<title> Just a title </title>", "https://a.example/").title, "Just a title")
  assert.equal(parseOpenGraph("<meta property=og:description content=x>", "https://a.example/"), null, "no title, no preview (iOS)")
})

test("an og:image off https or on the LAN is dropped, the rest of the preview kept", () => {
  for (const img of ["http://cdn.example/a.png", "https://192.168.0.2/a.png", "data:image/png;base64,AA", "javascript:x"]) {
    const m = parseOpenGraph(`<meta property="og:title" content="T"><meta property="og:image" content="${img}">`, "https://a.example/")
    assert.equal(m.title, "T"); assert.equal(m.image, null, img)
  }
})

test("decodeEntities leaves unknown and out-of-range entities alone", () => {
  assert.equal(decodeEntities("&bogus; &#0; &#x110000; &lt;b&gt;"), "&bogus; &#0; &#x110000; <b>")
})

test("the fetch carries no cookies or referrer, and a CORS refusal is a plain link (null), not an error", async () => {
  let seen
  const ok = await fetchPreview("https://a.example/p", { fetch: async (u, o) => { seen = o; return page(`<meta property="og:title" content="Hi">`, { url: u }) } })
  assert.equal(ok.title, "Hi")
  assert.equal(seen.credentials, "omit"); assert.equal(seen.referrerPolicy, "no-referrer"); assert.equal(seen.mode, "cors")
  assert.equal(await fetchPreview("https://a.example/p", { fetch: async () => { throw new TypeError("Failed to fetch") } }), null)
})

test("not HTML, not 2xx, or redirected onto the LAN: no preview", async () => {
  const t = `<meta property="og:title" content="T">`
  assert.equal(await fetchPreview("https://a.example/", { fetch: async () => page(t, { type: "application/json" }) }), null)
  assert.equal(await fetchPreview("https://a.example/", { fetch: async () => page(t, { status: 404 }) }), null)
  assert.equal(await fetchPreview("https://a.example/", { fetch: async () => page(t, { url: "https://192.168.1.1/" }) }), null)
  let called = false
  assert.equal(await fetchPreview("https://127.0.0.1/", { fetch: async () => { called = true } }), null)
  assert.equal(called, false, "a loopback link is never fetched")
})

test("only the first 50 KB of a page is read", async () => {
  const late = "x".repeat(60_000) + `<meta property="og:title" content="Too late">`
  assert.equal(await fetchPreview("https://a.example/", { fetch: async () => page(late) }), null)
  const early = `<meta property="og:title" content="Early">` + "x".repeat(200_000)
  assert.equal((await fetchPreview("https://a.example/", { fetch: async () => page(early) })).title, "Early")
})

test("one fetch per URL, a miss cached too, at most four at once", async () => {
  resetPreviews()
  const calls = [], gates = []
  let open = 0, peak = 0
  const get = async u => {
    calls.push(u); open++; peak = Math.max(peak, open)
    await new Promise(r => gates.push(r))
    open--
    return page(`<meta property="og:title" content="${u}">`)
  }
  const urls = Array.from({ length: 10 }, (_, i) => `https://s${i}.example/`)
  const all = Promise.all([...urls, ...urls].map(u => preview(u, { fetch: get })))
  for (let i = 0; i < 40 && calls.length < urls.length; i++) { await new Promise(r => setTimeout(r, 0)); gates.splice(0).forEach(g => g()) }
  const res = await all
  assert.equal(calls.length, 10, "the second card for each URL shares the first fetch")
  assert.ok(peak <= 4, `peak ${peak}`)
  assert.equal(res[0].title, urls[0])
  let again = 0
  await preview("https://s0.example/", { fetch: async () => { again++; return page("") } })
  assert.equal(again, 0)
  resetPreviews()
  let misses = 0
  const miss = async () => { misses++; throw new TypeError("CORS") }
  assert.equal(await preview("https://m.example/", { fetch: miss }), null)
  assert.equal(await preview("https://m.example/", { fetch: miss }), null)
  assert.equal(misses, 1, "a refused site is not asked again on every render")
  resetPreviews()
})

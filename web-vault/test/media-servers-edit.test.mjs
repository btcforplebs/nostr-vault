// Settings › Media Servers: the kind 10063 list read in order, tags round-tripping with the other tags kept, and
// add/remove. Throwaway keys: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { serverEntries, serverTags, addServer, removeServer, serverProblem } from "../src/net/list-edit.js"
import { serverList } from "../src/net/upload.js"

const SK = generateSecretKey()
const list = tags => finalizeEvent({ kind: 10063, content: "", tags, created_at: 10 }, SK)

test("servers keep the list's order, lose a trailing slash and duplicates, and keep ones uploads skip", () => {
  const ev = list([["server", "https://b.example/"], ["server", "https://a.example"], ["server", "https://b.example"], ["server", "http://plain.example"], ["server", "https://cdn.satellite.earth"], ["server", " "], ["alt", "x"]])
  assert.deepEqual(serverEntries(ev), ["https://b.example", "https://a.example", "http://plain.example", "https://cdn.satellite.earth"])
  // What uploads use is unchanged: only the usable ones, same order.
  assert.deepEqual(serverList(ev), ["https://b.example", "https://a.example"])
  assert.deepEqual(serverTags(serverEntries(ev), ev), [["alt", "x"], ["server", "https://b.example"], ["server", "https://a.example"], ["server", "http://plain.example"], ["server", "https://cdn.satellite.earth"]])
  assert.deepEqual(serverEntries(undefined), [])
})

test("add goes last and only once; remove; an empty list can't be saved", () => {
  let urls = addServer(["https://a.example"], "https://b.example")
  assert.deepEqual(urls, ["https://a.example", "https://b.example"])
  assert.deepEqual(addServer(urls, "https://a.example"), urls)
  urls = removeServer(urls, "https://a.example")
  assert.deepEqual(urls, ["https://b.example"])
  assert.equal(serverProblem(urls), "")
  assert.match(serverProblem([]), /at least one/)
})

test("each saved server is tested as the page opens, and its line says when (the phone's statusLine)", async () => {
  const { readFileSync } = await import("node:fs")
  const src = readFileSync(new URL("../src/screens/MediaServersPage.jsx", import.meta.url), "utf8")
  assert.match(src, /setUrls\(start\(r\)\); start\(r\)\.forEach\(test\)/)
  assert.match(src, / · checked \{checkedAgo\(h\.at\)\}/)
  // checkedAgo is plain JS after the component; evaluate just it.
  const fn = src.slice(src.indexOf("export function checkedAgo")).replace("export ", "")
  const checkedAgo = new Function(`${fn}; return checkedAgo`)()
  assert.equal(checkedAgo(1000, 30_000), "just now")
  assert.equal(checkedAgo(0, 5 * 60_000, "en-US"), "5 minutes ago")
  assert.equal(checkedAgo(0, 2 * 3600_000, "en-US"), "2 hours ago")
})

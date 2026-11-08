// Settings › Media Servers: the kind 10063 list read in order, tags round-tripping with the other tags kept, and
// add/remove. Throwaway keys: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, finalizeEvent, getPublicKey } from "nostr-tools/pure"
import { serverEntries, serverTags, addServer, removeServer, serverProblem, isMeshServer } from "../src/net/list-edit.js"
import { meshVaultRows } from "../src/net/mesh-vault-rows.js"
import { npubEncode } from "nostr-tools/nip19"
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
  assert.match(src, /setUrls\(start\(r\)\); start\(r\)\.filter\(u => !isMeshServer\(u\)\)\.forEach\(test\)/)
  assert.match(src, / · checked \{checkedAgo\(h\.at\)\}/)
  // checkedAgo is plain JS after the component; evaluate just it.
  const fn = src.slice(src.indexOf("export function checkedAgo")).replace("export ", "")
  const checkedAgo = new Function(`${fn}; return checkedAgo`)()
  assert.equal(checkedAgo(1000, 30_000), "just now")
  assert.equal(checkedAgo(0, 5 * 60_000, "en-US"), "5 minutes ago")
  assert.equal(checkedAgo(0, 2 * 3600_000, "en-US"), "2 hours ago")
})

test("mesh vaults get their own rows: named by pairing, else by role or Mesh vault; never tested; never the only entry", async () => {
  const [a, b, c] = [1, 2, 3].map(() => getPublicKey(generateSecretKey()))
  const mesh = hex => `fipsmesh://${npubEncode(hex)}/`
  const ev = list([["server", "https://a.example"], ["server", mesh(a)], ["server", mesh(b)], ["server", mesh(c)], ["server", "fipsmesh://nonsense/"]])
  const urls = serverEntries(ev)
  assert.deepEqual(urls.filter(u => !isMeshServer(u)), ["https://a.example"])
  const tail = hex => `${npubEncode(hex).slice(0, 9)}…${npubEncode(hex).slice(-4)}`
  const rows = meshVaultRows(urls, [{ hex: a, name: "Logen's Mac", role: "mac" }, { hex: b, name: "", role: "homeVault" }])
  assert.deepEqual(rows.map(r => [r.url, r.title]), [[mesh(a), "Logen's Mac"], [mesh(b), `Mobile vault ${tail(b)}`], [mesh(c), `Mesh vault ${tail(c)}`]])
  // Remove takes a mesh entry off the list that is saved, the other tags kept.
  assert.deepEqual(serverTags(removeServer(urls, mesh(b)), ev).map(t => t[1]), ["https://a.example", mesh(a), mesh(c), "fipsmesh://nonsense/"])
  // A list of only mesh vaults isn't published (NIP-F1).
  assert.match(serverProblem([mesh(a)]), /at least one/)
  assert.equal(serverProblem([mesh(a), "https://a.example"]), "")
  const { readFileSync } = await import("node:fs")
  const page = readFileSync(new URL("../src/screens/MediaServersPage.jsx", import.meta.url), "utf8")
  assert.match(page, /servers\.map\(\(url, i\)/) // the health-checked rows are the non-mesh ones
  const section = readFileSync(new URL("../src/screens/MeshVaultRows.jsx", import.meta.url), "utf8")
  assert.match(section, /Your Vaults on the Mesh/)
  assert.match(section, /<span class="tag">mesh<\/span>/)
  assert.doesNotMatch(section, /Health|testServer|offline/)
})

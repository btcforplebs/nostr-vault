// The public post page's mesh photos: the server reads the shared post author's 10063 and, for a photo of that post
// with a hash, when the author names a fipsmesh:// vault, writes the hash and vaults on the <img> and adds the one
// script that reads it over FIPS (web-relay src/fips/share-photos.js). Replies never do: anyone can reply. Signed
// events from throwaway keys and a fake relay query.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { PUBLIC_SEEDS } from "../../web-relay/src/fips/node.js"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { blossomHash, meshPhotoAuthors, meshPhotoHashes, meshVaults, noteParts, renderPost, MESH_PHOTO_SCRIPT } from "../thread-page/page.js"
import { loadThread, readDeleted, readMeshVaults } from "../thread-page/fetch.js"

const alice = generateSecretKey(), bob = generateSecretKey(), vault = generateSecretKey(), vault2 = generateSecretKey()
const A = getPublicKey(alice), B = getPublicKey(bob), V = getPublicKey(vault), V2 = getPublicKey(vault2)
let clock = 1_760_000_000
const sign = (sk, kind, content, tags = []) => finalizeEvent({ kind, content, tags, created_at: clock++ }, sk)
const HASH = "e40a76df2e154784d6d159ddca808c295eb514274b965d53e1f27575a6c8ee0e", OTHER = "ab".repeat(32)
const PHOTO = `https://media.example/${HASH}.png`
const mesh = pk => ["server", `fipsmesh://${npubEncode(pk)}/`]
const list = (sk, servers) => sign(sk, 10063, "", servers)

test("a photo's hash: its imeta x, else the one its Blossom path names; never for a video", () => {
  assert.equal(noteParts(`hi ${PHOTO}`, [["imeta", `url ${PHOTO}`, `x ${OTHER}`]]).media[0].x, OTHER)
  assert.equal(noteParts(`hi ${PHOTO}`).media[0].x, HASH)
  assert.equal(noteParts("https://media.example/photo.png").media[0].x, undefined)
  assert.equal(noteParts(`https://media.example/${HASH}.mp4`).media[0].x, undefined)
  assert.equal(blossomHash(`https://media.example/${HASH}/thumb.png`), undefined, "the hash must be the last part")
})

test("meshVaults: fipsmesh:// servers with the trailing slash, as x-only hex, once each, at most three", () => {
  const ev = list(alice, [["server", "https://cdn.example"], mesh(V), mesh(V), ["server", `fipsmesh://${npubEncode(V2)}`], ["server", "fipsmesh://npub1bad/"]])
  assert.deepEqual(meshVaults(ev), [V])
  const many = list(alice, [1, 2, 3, 4].map(() => mesh(getPublicKey(generateSecretKey()))))
  assert.equal(meshVaults(many).length, 3)
})

test("readMeshVaults: the newest signed 10063 per author; a forged or vault-less one names nothing", async () => {
  const old = list(alice, [mesh(V2)]), newest = list(alice, [["server", "https://cdn.example"], mesh(V)])
  const forged = { ...list(bob, [mesh(V)]), content: "x" } // signature no longer matches
  const asked = []
  const query = async (relays, filter) => { asked.push(filter); return [newest, old, forged, list(generateSecretKey(), [mesh(V)])] }
  const got = await readMeshVaults([A, B], query)
  assert.deepEqual([...got], [[A, [V]]])
  assert.deepEqual(asked[0].kinds, [10063])
  assert.deepEqual((await readMeshVaults([], query)).size, 0, "no read with no photo authors")
  assert.equal(asked.length, 1)
})

test("the page: the post's hashed photo carries data-x/data-vaults, and only then the script", () => {
  const post = sign(alice, 1, `Another FIPS test\n${PHOTO}`, [["imeta", `url ${PHOTO}`, `x ${HASH}`]])
  const reply = sign(bob, 1, `mine https://media.example/${OTHER}.jpg`, [["e", post.id, "", "root"]])
  const page = vaults => renderPost({ post, replies: [{ event: reply, depth: 1 }], profiles: new Map(), code: "x", vaults })
  const withVault = page([V, V2])
  assert.match(withVault, new RegExp(`<img src="${PHOTO}"[^>]* data-x="${HASH}" data-vaults="${V},${V2}">`))
  assert.doesNotMatch(withVault, new RegExp(`${OTHER}.jpg"[^>]*data-x`), "a reply's photo stays plain")
  assert.equal(withVault.split(`<script type="module" src="${MESH_PHOTO_SCRIPT}"></script>`).length, 2, "one script")
  const plain = page([])
  assert.doesNotMatch(plain, /data-vaults|<script/, "no vault: no script at all")
})

test("a reply's photo never arms the script, even when its author names a vault", () => {
  const post = sign(alice, 1, "text only, no photo")
  const reply = sign(bob, 1, `look ${PHOTO}`, [["e", post.id, "", "root"], ["imeta", `url ${PHOTO}`, `x ${HASH}`]])
  const html = renderPost({ post, replies: [{ event: reply, depth: 1 }], profiles: new Map(), code: "x", vaults: [V] })
  assert.doesNotMatch(html, /data-vaults|<script/)
})

test("the script is chosen from the post's data, not from text that looks like the attribute", () => {
  const post = sign(alice, 1, `see <img data-x="${HASH}" data-vaults="${V}">`)
  const html = renderPost({ post, replies: [], profiles: new Map(), code: "x", vaults: [V] })
  assert.doesNotMatch(html, /<script/)
})

test("loadThread reads only the post author's 10063, and only when the post has a hashed photo", async () => {
  const post = sign(alice, 1, `look ${PHOTO}`)
  const reply = sign(bob, 1, `mine https://media.example/${OTHER}.jpg`, [["e", post.id, "", "root"]])
  const asked = []
  const query = async (relays, f) => {
    asked.push(f)
    if (f.ids) return [post]
    if (f["#e"]) return [reply]
    if (f.kinds?.[0] === 10063) return [list(alice, [mesh(V)]), list(bob, [mesh(V2)])]
    return []
  }
  const { vaults } = await loadThread({ id: post.id, relays: [] }, query)
  assert.deepEqual(vaults, [V])
  assert.deepEqual(asked.filter(f => f.kinds?.[0] === 10063).map(f => f.authors), [[A]], "the post author only")
  assert.deepEqual(meshPhotoAuthors([post, reply]), [A, B])

  const textPost = sign(alice, 1, "no photo")
  asked.length = 0
  const q2 = async (relays, f) => { asked.push(f); return f.ids ? [textPost] : f.kinds?.[0] === 10063 ? [list(alice, [mesh(V)])] : [] }
  assert.deepEqual((await loadThread({ id: textPost.id, relays: [] }, q2)).vaults, [])
  assert.equal(asked.filter(f => f.kinds?.[0] === 10063).length, 0, "no photo: no 10063 read")
})

test("a post its author deleted (kind 5) arms no mesh read; someone else's kind 5 or a forged one doesn't count", async () => {
  const post = sign(alice, 1, `look ${PHOTO}`, [["imeta", `url ${PHOTO}`, `x ${HASH}`]])
  const del = (sk, tags) => sign(sk, 5, "", tags)
  const relaysWith = fives => async (relays, f) =>
    f.ids ? [post] : f.kinds?.[0] === 10063 ? [list(alice, [mesh(V)])] : f.kinds?.[0] === 5 ? fives : []
  assert.equal(await readDeleted(post, relaysWith([del(alice, [["e", post.id]])])), true)
  assert.equal(await readDeleted(post, relaysWith([del(bob, [["e", post.id]])])), false, "only the author can delete")
  assert.equal(await readDeleted(post, relaysWith([{ ...del(alice, [["e", OTHER]]), tags: [["e", post.id]] }])), false, "forged")
  assert.deepEqual((await loadThread({ id: post.id, relays: [] }, relaysWith([del(alice, [["e", post.id]])]))).vaults, [])
  assert.deepEqual((await loadThread({ id: post.id, relays: [] }, relaysWith([]))).vaults, [V])
})

test("the server keeps the post's own image hashes, as many as the page reads; no video, no long-form", () => {
  const imgs = Array.from({ length: 10 }, (_, i) => `https://media.example/${String(i).repeat(64)}.png`)
  const post = sign(alice, 1, `${imgs.join(" ")} https://media.example/${OTHER}.mp4`)
  assert.equal(meshPhotoHashes(post).length, 8)
  assert.ok(!meshPhotoHashes(post).includes(OTHER))
  assert.deepEqual(meshPhotoHashes(sign(alice, 30023, PHOTO, [["d", "a"]])), [])
})

test("the /thread/ CSP: scripts from the share script and its chunks only; connect-src is exactly PUBLIC_SEEDS' hosts", () => {
  const conf = readFileSync(new URL("../../website/nginx.conf", import.meta.url), "utf8")
  const csp = /~\^\/thread\/\s+"([^"]+)"/.exec(conf)[1]
  const dir = name => csp.split(";").map(d => d.trim().split(/\s+/)).find(d => d[0] === name)?.slice(1)
  assert.deepEqual(dir("script-src"), [`https://nostrvault.app${MESH_PHOTO_SCRIPT}`, "https://nostrvault.app/relay/assets/"])
  assert.deepEqual(dir("connect-src").sort(), PUBLIC_SEEDS.map(u => `wss://${new URL(u).host}`).sort())
  assert.equal(dir("worker-src"), undefined)
  assert.doesNotMatch(csp, /unsafe-eval|wasm/)
})

// The public post page's mesh photos: the server reads each photo author's 10063 and, for a photo with a hash whose
// author names a fipsmesh:// vault, writes the hash and vaults on the <img> and adds the one script that reads it over
// FIPS (web-relay src/fips/share-photos.js). Signed events from throwaway keys and a fake relay query.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { blossomHash, meshPhotoAuthors, meshVaults, noteParts, renderPost, MESH_PHOTO_SCRIPT } from "../thread-page/page.js"
import { loadThread, readMeshVaults } from "../thread-page/fetch.js"

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

test("the page: a hashed photo whose author names a vault carries data-x/data-vaults, and only then the script", () => {
  const post = sign(alice, 1, `Another FIPS test\n${PHOTO}`, [["imeta", `url ${PHOTO}`, `x ${HASH}`]])
  const reply = sign(bob, 1, `mine https://media.example/${OTHER}.jpg`, [["e", post.id, "", "root"]])
  const page = vaults => renderPost({ post, replies: [{ event: reply, depth: 1 }], profiles: new Map(), code: "x", vaults })
  const withVault = page(new Map([[A, [V, V2]]]))
  assert.match(withVault, new RegExp(`<img src="${PHOTO}"[^>]* data-x="${HASH}" data-vaults="${V},${V2}">`))
  assert.doesNotMatch(withVault, new RegExp(`${OTHER}.jpg"[^>]*data-x`), "bob names no vault: his photo stays plain")
  assert.equal(withVault.split(`<script type="module" src="${MESH_PHOTO_SCRIPT}"></script>`).length, 2, "one script")
  const plain = page(new Map())
  assert.doesNotMatch(plain, /data-vaults|<script/, "no vault anywhere: no script at all")
})

test("loadThread reads the 10063s of the authors with a hashed photo, beside the profiles", async () => {
  const post = sign(alice, 1, `look ${PHOTO}`)
  const reply = sign(bob, 1, "text only", [["e", post.id, "", "root"]])
  const asked = []
  const query = async (relays, f) => {
    asked.push(f)
    if (f.ids) return [post]
    if (f["#e"]) return [reply]
    if (f.kinds?.[0] === 10063) return [list(alice, [mesh(V)])]
    return []
  }
  const { vaults } = await loadThread({ id: post.id, relays: [] }, query)
  assert.deepEqual([...vaults], [[A, [V]]])
  assert.deepEqual(asked.find(f => f.kinds?.[0] === 10063).authors, [A], "only authors with a photo that has a hash")
  assert.deepEqual(meshPhotoAuthors([post, reply]), [A])
})

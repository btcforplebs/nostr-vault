// Zap the artist from Now Playing (ArtistZapPill): the artist's Nostr key, found as MusicArtistKey.hex finds it.
// CORS checked by hand 2026-10-31: primal.net, blink.sv and wavlake.com lnurlp all send Access-Control-Allow-Origin: *.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { npubEncode } from "nostr-tools/nip19"
import { artistKey, rememberArtist } from "../src/readers/wavlake.js"

const hex = "a".repeat(64), npub = npubEncode(hex)

test("the song's own npub, without asking Wavlake", async () => {
  assert.equal(await artistKey({ artistId: "x1", artistNpub: npub }, () => assert.fail("asked")), hex)
})

test("an npub another page named this session, without asking", async () => {
  rememberArtist({ id: "x2", npub })
  assert.equal(await artistKey({ artistId: "x2" }, () => assert.fail("asked")), hex)
})

test("else the artist's own page, asked once per artist; no key on the page is null, and is asked again later", async () => {
  let asked = 0
  const get = async url => { asked++; assert.match(url, /\/artist\/x3$/); return { name: "Band", artistNpub: npub, albums: [] } }
  assert.equal(await artistKey({ artistId: "x3" }, get), hex)
  assert.equal(await artistKey({ artistId: "x3" }, get), hex)
  assert.equal(asked, 1)
  let none = 0
  const noKey = async () => { none++; return { name: "Nobody", albums: [] } }
  assert.equal(await artistKey({ artistId: "x4" }, noKey), null)
  await new Promise(r => setTimeout(r, 0))
  assert.equal(await artistKey({ artistId: "x4" }, noKey), null)
  assert.equal(none, 2)
  assert.equal(await artistKey({}, () => assert.fail("asked")), null)
})

test("Now Playing shows the artist zap for songs, not streams; it is the person zap button, hidden without a lightning address", () => {
  const np = readFileSync(new URL("../src/readers/NowPlaying.jsx", import.meta.url), "utf8")
  assert.match(np, /Up Next<\/button>\n\s*<ArtistZap track=\{t\} \/><\/>\}/)
  const az = readFileSync(new URL("../src/readers/ArtistZap.jsx", import.meta.url), "utf8")
  assert.match(az, /if \(!hex \|\| !\(profile\?\.lud16 \|\| profile\?\.lud06\)\) return null/)
  assert.match(az, /<ZapButton pubkey=\{hex\} \/>/)
})

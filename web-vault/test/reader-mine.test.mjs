// One plan step 5: your own profile in the Reader. The shell's answers hand over only plain strings (https pictures,
// http(s) website), the buttons open only the site's own pages, and none of it answers anyone but the Reader.
import test from "node:test"
import assert from "node:assert/strict"
import { mineAnswer, shopRows, mineIntents, PAGES } from "../src/napplet/reader-mine.js"
import { createBus } from "../src/napplet/bus.js"
import { READER_DTAG } from "../src/napplet/first-party-list.js"

const ME = "a".repeat(64)
const reader = { dTag: READER_DTAG, send: () => {} }, other = { dTag: "nv-compose", send: () => {} }
const ask = (bus, from, archetype, action, payload = {}) => bus.invoke(from, { archetype, action, payload })

function rig({ readOnly = false, listings = [] } = {}) {
  const seen = { edit: 0, share: 0, page: [], listing: [], copied: [] }
  const bus = createBus()
  const off = mineIntents({
    bus,
    profile: async () => ({ me: ME, npub: "npub1me", profile: { name: "Me", display_name: "Me Two", picture: "http://x/p.png", banner: "https://x/b.png", website: "https://me.example/", lud16: "me@ln.example", nip05: "_@me.example", about: "hi" }, follows: 12, followers: 3, readOnly }),
    shop: async () => listings, priceOf: l => `${l.price} sats`,
    onEdit: () => seen.edit++, onShare: () => seen.share++, onListing: l => seen.listing.push(l.id), onPage: to => seen.page.push(to), copy: async t => seen.copied.push(t),
  })
  return { bus, seen, off }
}

test("mine: plain strings only; http pictures dropped, website http(s) only, _@ trimmed, YOU can edit unless read-only", () => {
  const a = mineAnswer({ me: ME, npub: "npub1me", profile: { display_name: "D", name: "n", picture: "http://x", banner: "https://b", website: "javascript:alert(1)", nip05: "_@me.example", about: "x".repeat(5000) }, follows: 2, followers: null, readOnly: false })
  assert.equal(a.name, "D"); assert.equal(a.picture, ""); assert.equal(a.banner, "https://b"); assert.equal(a.website, "")
  assert.equal(a.nip05, "me.example"); assert.equal(a.about.length, 2000); assert.equal(a.following, 2); assert.equal(a.followers, null); assert.equal(a.canEdit, true)
  assert.equal(mineAnswer({ me: ME, npub: "x", profile: undefined, follows: 0, followers: 0, readOnly: true }).canEdit, false)
  assert.equal(mineAnswer({ me: ME, npub: "x", profile: { website: "http://site.example" }, follows: 0 }).website, "http://site.example")
})

test("shop rows: title, price, summary and the first https picture", () => {
  assert.deepEqual(shopRows([{ id: "l1", title: "Hat", summary: "warm", price: "21", images: ["http://x", "https://y"], isAuction: true }], l => `${l.price} sats`),
    [{ id: "l1", title: "Hat", summary: "warm", price: "21 sats", image: "", auction: true }])
})

test("only the Reader is answered", async () => {
  const { bus, seen } = rig()
  for (const [arch, act, p] of [["profile", "mine"], ["profile", "edit"], ["profile", "share"], ["profile", "copy", { what: "npub" }], ["page", "open", { page: "wallet" }]]) {
    const r = await ask(bus, other, arch, act, p)
    assert.equal(r.ok, false, `${arch}/${act} refused to another napplet`)
  }
  assert.deepEqual(seen, { edit: 0, share: 0, page: [], listing: [], copied: [] })
})

test("the Reader: mine answers, edit and share open the site's screens, pages only from PAGES", async () => {
  const { bus, seen } = rig()
  const m = await ask(bus, reader, "profile", "mine")
  assert.equal(m.data.name, "Me Two"); assert.equal(m.data.picture, ""); assert.equal(m.data.lud16, "me@ln.example")
  assert.equal((await ask(bus, reader, "profile", "edit")).ok, true); assert.equal(seen.edit, 1)
  assert.equal((await ask(bus, reader, "profile", "share")).ok, true); assert.equal(seen.share, 1)
  assert.equal((await ask(bus, reader, "page", "open", { page: "settings" })).ok, true)
  for (const page of ["accounts", "#/settings", "constructor", "__proto__", "toString", undefined]) assert.equal((await ask(bus, reader, "page", "open", { page })).ok, false, String(page))
  assert.deepEqual(seen.page, [PAGES.settings])
})

test("edit is refused for a read-only sign-in", async () => {
  const { bus, seen } = rig({ readOnly: true })
  assert.equal((await ask(bus, reader, "profile", "edit")).ok, false)
  assert.equal(seen.edit, 0)
  assert.equal((await ask(bus, reader, "profile", "mine")).data.canEdit, false)
})

test("copy: your npub or lightning address only, never text the frame names", async () => {
  const { bus, seen } = rig()
  assert.equal((await ask(bus, reader, "profile", "copy", { what: "npub" })).ok, true)
  assert.equal((await ask(bus, reader, "profile", "copy", { what: "ln" })).ok, true)
  assert.equal((await ask(bus, reader, "profile", "copy", { what: "evil", text: "pay me" })).ok, false)
  assert.deepEqual(seen.copied, ["npub1me", "me@ln.example"])
})

test("listing: opens only one profile/shop handed out", async () => {
  const { bus, seen } = rig({ listings: [{ id: "l1", title: "Hat", price: "1", images: [] }] })
  assert.equal((await ask(bus, reader, "profile", "listing", { id: "l1" })).ok, false, "nothing handed out yet")
  const shop = await ask(bus, reader, "profile", "shop")
  assert.equal(shop.data.length, 1)
  assert.equal((await ask(bus, reader, "profile", "listing", { id: "l1" })).ok, true)
  assert.equal((await ask(bus, reader, "profile", "listing", { id: "l2" })).ok, false)
  assert.deepEqual(seen.listing, ["l1"])
})

test("off() takes every handler away", async () => {
  const { bus, off } = rig()
  off()
  assert.equal((await ask(bus, reader, "profile", "mine")).ok, false)
})

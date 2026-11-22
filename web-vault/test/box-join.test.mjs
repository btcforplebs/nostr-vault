// Joining a box (One Vault W7): the page asks the box whether it holds the signed-in account (box-vault.js
// boxAccountCheck), and Settings' This Box row (BoxLink.jsx) shows the join form (JoinBox.jsx) to an account the box
// doesn't hold or holds watch-only. The join is the first account's code plus the joining account's own NIP-98
// signature, checked by a fake box (test/box-accounts-fake.mjs). Nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode, nsecEncode } from "nostr-tools/nip19"
import { fakeDom, fakeAccountsBox, tick, all, fire, button } from "./box-accounts-fake.mjs"

fakeDom()
const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { BoxLink } = await vite.ssrLoadModule("/src/box/BoxLink.jsx")
const { boxAccountCheck } = await vite.ssrLoadModule("/src/box/box-vault.js")
const { accountsApi } = await vite.ssrLoadModule("/src/box/api-accounts.js")
test.after(() => vite.close())

const key = () => { const sk = generateSecretKey(); return { sk, hex: getPublicKey(sk), signer: { signEvent: async t => finalizeEvent(t, sk) } } }
const first = key()
const checkFor = (box, who) => boxAccountCheck({ api: accountsApi({ signer: who.signer, base: "http://box.test/api/box", fetchImpl: box.fetchImpl }) })

async function mount(account, reload = () => {}) {
  const el = document.createElement("div")
  render(h(BoxLink, { account, reload }), el)
  await tick(10)
  return el
}
const input = el => all(el).find(n => n.localName === "input")
const form = el => all(el).find(n => n.localName === "form")
const type = async (el, text) => { fire(input(el), "input", { currentTarget: { value: text } }); await tick() }

test("the check asks the box as the signed-in account and says how the box holds it", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const stranger = key(), watched = key()
  box.addWatchOnly(watched.hex)
  for (const [who, want] of [[first, "first"], [stranger, "none"], [watched, "watchOnly"]]) {
    const c = checkFor(box, who)
    assert.equal(c.state, undefined, "not known before the box answers")
    await c.check()
    assert.equal(c.state, want)
    assert.equal(box.log.at(-1).who, who.hex, "signed by that account, not another")
  }
  const down = boxAccountCheck({ api: accountsApi({ signer: first.signer, base: "http://box.test/api/box", fetchImpl: async () => new Response("", { status: 502 }) }) })
  await down.check()
  assert.equal(down.state, null)
  assert.match(down.error, /502/)
})

test("an account the box doesn't hold: This Box shows the join form, not the box screens", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const c = checkFor(box, key()); await c.check()
  const el = await mount(c)
  assert.match(el.textContent, /This box doesn't hold this account yet/)
  assert.ok(!all(el).some(n => n.attributes?.href === "#/box"), "no link to the box screens")
  assert.ok(button(el, "Join this box"))
  render(null, el)
})

test("the first account and a signed-in one keep the link to the box screens", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const c = checkFor(box, first); await c.check()
  const el = await mount(c)
  assert.ok(all(el).some(n => n.attributes?.href === "#/box"))
  assert.ok(!/doesn't hold/.test(el.textContent))
  render(null, el)
})

test("joining: the code plus the joining account's own signature; the form says so, then the page opens again", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const joiner = key()
  const c = checkFor(box, joiner); await c.check()
  const el = await mount(c)
  await type(el, "WRONG-CODE-123"); fire(form(el), "submit"); await tick(30)
  assert.match(el.textContent, /isn't right or has expired/)
  assert.equal(box.added.size, 0)
  // The first account makes a code (W6's Add an account) and reads it out.
  const { code } = await accountsApi({ signer: first.signer, base: "http://box.test/api/box", fetchImpl: box.fetchImpl }).code()
  await type(el, `${code.slice(0, 4)}-${code.slice(4, 8)}-${code.slice(8)}`.toLowerCase())
  fire(form(el), "submit"); await tick(30)
  const joined = box.log.find(l => l.name === "accounts/join" && l.status === 200)
  assert.equal(joined.who, joiner.hex, "the join is signed by the joining account")
  assert.equal(box.added.get(npubEncode(joiner.hex))?.state, "signedIn")
  assert.equal(c.state, "signedIn")
  assert.match(el.textContent, /You're on this box now/, "still shown after the state changed")
  render(null, el)
})

test("a watch-only account joins the same way; already signed in reloads at once", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const watched = key(); box.addWatchOnly(watched.hex)
  const c = checkFor(box, watched); await c.check()
  let reloads = 0
  const el = await mount(c, () => reloads++)
  assert.match(el.textContent, /shows nothing private until the account signs in/)
  box.codes.add("ABCDEFGHJKMN")
  await type(el, "ABCD EFGH JKMN"); fire(form(el), "submit"); await tick(30)
  assert.equal(box.added.get(npubEncode(watched.hex)).state, "signedIn")
  await type(el, "ABCDEFGHJKMN"); fire(form(el), "submit"); await tick(30)
  assert.match(el.textContent, /already signed in/)
  assert.equal(reloads, 1)
  render(null, el)
})

test("a secret key typed as the code is refused here and never sent", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const c = checkFor(box, key()); await c.check()
  const el = await mount(c)
  const before = box.log.length
  await type(el, nsecEncode(generateSecretKey())); fire(form(el), "submit"); await tick(30)
  assert.match(el.textContent, /That is a secret key \(nsec\)/)
  assert.equal(box.log.length, before, "nothing sent")
  assert.equal(input(el).attributes.value ?? "", "", "cleared")
  render(null, el)
})

test("the box answers after Settings opened: the row turns into the join form", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const c = checkFor(box, key())
  const el = await mount(c); await tick(80) // effects have run: only the subscription can bring the answer now
  assert.ok(all(el).some(n => n.attributes?.href === "#/box"), "unknown yet: the plain row")
  await c.check(); await tick(80)
  assert.match(el.textContent, /This box doesn't hold this account yet/)
  render(null, el)
})

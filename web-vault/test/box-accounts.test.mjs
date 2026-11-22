// Settings › Accounts in box mode (src/box/sections/AccountsSection.jsx, One Vault W6) over a pretend box that checks
// each NIP-98 header (test/box-accounts-fake.mjs): the first account sees the accounts with their states, makes a
// one-time code and removes an account; any other account sees nothing. Nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { fakeDom, fakeAccountsBox, tick, all, fire, button } from "./box-accounts-fake.mjs"

fakeDom()
const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { AccountsSection } = await vite.ssrLoadModule("/src/box/sections/AccountsSection.jsx")
const { accountsApi } = await vite.ssrLoadModule("/src/box/api-accounts.js")
const { boxAccountCheck } = await vite.ssrLoadModule("/src/box/box-vault.js")
test.after(() => vite.close())

const key = () => { const sk = generateSecretKey(); return { hex: getPublicKey(sk), signer: { signEvent: async t => finalizeEvent(t, sk) } } }
const first = key(), other = key(), watched = key()

async function mount(box, who) {
  const el = document.createElement("div")
  const api = accountsApi({ signer: who.signer, base: "http://box.test/api/box", fetchImpl: box.fetchImpl })
  render(h(AccountsSection, { ctx: { signer: who.signer }, api }), el)
  for (let i = 0; i < 50 && box.log.length === 0; i++) await tick(5)
  await tick(10)
  return el
}

test("the first account sees every account with its state; Add an account shows a one-time code", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  box.addWatchOnly(watched.hex)
  const el = await mount(box, first)
  const t = el.textContent
  assert.match(t, /Accounts on this box/)
  assert.match(t, /First account/)
  assert.match(t, /Watch-only/)
  assert.match(t, /all yours, as on a Mac/)
  assert.equal(all(el).filter(n => n.localName === "button" && n.textContent === "Remove").length, 1, "the first account has no Remove")
  fire(button(el, "Add an account"), "click"); await tick(30)
  assert.match(el.textContent, /One-time code/)
  assert.match(el.textContent, /ABCD-0EFG-H0JK/, "grouped in fours")
  assert.match(el.textContent, /It works once, until /)
  assert.ok(box.codes.has("ABCD0EFGH0JK"))
  assert.deepEqual(box.log.map(l => [l.method, l.name, l.status]), [["GET", "accounts", 200], ["POST", "accounts/code", 200]])
  render(null, el)
})

test("Remove asks first, then takes the account off and says its notes and files stay", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  box.addWatchOnly(watched.hex)
  const el = await mount(box, first)
  fire(button(el, "Remove"), "click"); await tick()
  assert.match(el.textContent, /Its notes and files stay on the box/)
  assert.equal(box.added.size, 1, "nothing removed before the confirm")
  fire(button(el, "Remove from box"), "click"); await tick(40)
  assert.equal(box.added.size, 0)
  assert.deepEqual(box.log.find(l => l.name === "accounts/remove")?.status, 200)
  assert.match(el.textContent, /is off this box\. Its notes and files stay/)
  assert.ok(!/Watch-only/.test(el.textContent), "the list was read again")
  render(null, el)
})

test("an account that isn't the first sees nothing, not an error", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  box.added.set(npubEncode(other.hex), { state: "signedIn", added: 1 })
  const el = await mount(box, other)
  assert.equal(box.log[0].status, 403)
  assert.equal(el.textContent, "")
  render(null, el)
})

test("with the page's check: only the first account is asked to sign for the list (Tron L1)", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  box.added.set(npubEncode(other.hex), { state: "signedIn", added: 1 })
  for (const [who, shown] of [[other, false], [first, true]]) {
    const api = accountsApi({ signer: who.signer, base: "http://box.test/api/box", fetchImpl: box.fetchImpl })
    const account = boxAccountCheck({ api })
    const el = document.createElement("div")
    render(h(AccountsSection, { ctx: { signer: who.signer }, api, account }), el)
    await tick(20)
    assert.equal(box.log.filter(l => l.name === "accounts").length, 0, "nothing signed before the box says who this is")
    await account.check(); await tick(40)
    const lists = box.log.filter(l => l.name === "accounts" && l.who === who.hex)
    assert.equal(lists.length, shown ? 1 : 0, shown ? "the first account gets its list" : "another account is never asked to sign for it")
    assert.equal(/Accounts on this box/.test(el.textContent), shown)
    render(null, el)
  }
})

test("a box that can't answer says why", async () => {
  const el = document.createElement("div")
  const api = accountsApi({ signer: first.signer, base: "http://box.test/api/box", fetchImpl: async () => new Response(JSON.stringify({ error: "this box can't hold more accounts" }), { status: 503 }) })
  render(h(AccountsSection, { ctx: { signer: first.signer }, api }), el)
  await tick(40)
  assert.match(el.textContent, /This box can't hold more accounts/)
  render(null, el)
})

test("accountsApi: a refused sign-in names the signer; a wrong code shows the box's words, not 'owner only'", async () => {
  const box = fakeAccountsBox({ owner: first.hex })
  const api = accountsApi({ signer: other.signer, base: "http://box.test/api/box", fetchImpl: box.fetchImpl })
  await assert.rejects(api.join("WRONG-CODE"), e => e.status === 403 && /isn't right or has expired/.test(e.message) && !/Only the box's owner can do this/.test(e.message))
  const bad = accountsApi({ signer: { signEvent: async t => ({ ...finalizeEvent(t, generateSecretKey()), sig: "00".repeat(64) }) }, base: "http://box.test/api/box", fetchImpl: box.fetchImpl })
  await assert.rejects(bad.me(), /didn't accept this sign-in/)
  await assert.rejects(accountsApi({ signer: { readOnly: true, signEvent() {} }, base: "http://box.test/api/box", fetchImpl: box.fetchImpl }).me(), /Sign in with your account's signer/)
})

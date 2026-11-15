// The napplet switch from the page address (flag.js switchFromAddress): works signed out, cleans the address.
import test from "node:test"
import assert from "node:assert/strict"
import { nappletsOn, switchFromAddress } from "../src/napplet/flag.js"

const mem = () => { const m = new Map(); return { getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const hist = () => ({ state: null, urls: [], replaceState(_s, _t, u) { this.urls.push(u) } })

test("?napplets=1 turns napplets on and leaves the rest of the address", () => {
  const store = mem(), h = hist()
  assert.equal(switchFromAddress({ href: "https://nv.home.arpa:8443/vault/?napplets=1&x=2#/feed" }, store, h), true)
  assert.equal(nappletsOn(store), true)
  assert.deepEqual(h.urls, ["/vault/?x=2#/feed"])
})

test("?napplets=0 turns them off again", () => {
  const store = mem(); store.setItem("nv-napplets", "1")
  const h = hist()
  assert.equal(switchFromAddress({ href: "https://nv.home.arpa:8443/vault/?napplets=0" }, store, h), false)
  assert.equal(nappletsOn(store), false)
  assert.deepEqual(h.urls, ["/vault/"])
})

test("no ?napplets, or another value: nothing changes, address untouched", () => {
  for (const href of ["https://a.example/vault/", "https://a.example/vault/?shell=1", "https://a.example/vault/?napplets=yes"]) {
    const store = mem(), h = hist()
    assert.equal(switchFromAddress({ href }, store, h), null)
    assert.equal(nappletsOn(store), false)
    assert.deepEqual(h.urls, [])
  }
})

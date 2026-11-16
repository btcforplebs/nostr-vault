// The old napplet preview switch is gone (plan NV_WEB_ONE_PLAN.md step 11): the layout decides. An old bookmark's
// ?napplets=1 or =0 is taken out of the address without changing anything, and the stored tick is cleared.
import test from "node:test"
import assert from "node:assert/strict"
import { nappletsOn, setDeskLayout, forgetOldSwitch } from "../src/napplet/flag.js"

const mem = () => { const m = new Map(); return { m, getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const hist = () => ({ state: null, urls: [], replaceState(_s, _t, u) { this.urls.push(u) } })

test("the layout decides: desktop on, phone off", () => {
  setDeskLayout(true); assert.equal(nappletsOn(), true)
  setDeskLayout(false); assert.equal(nappletsOn(), false)
})

test("?napplets=1 or =0 in an old bookmark: taken out, the rest of the address kept, nothing switched", () => {
  for (const v of ["1", "0", "yes"]) {
    const store = mem(), h = hist()
    setDeskLayout(false)
    assert.equal(forgetOldSwitch({ href: `https://nv.home.arpa:8443/vault/?napplets=${v}&x=2#/feed` }, store, h), true)
    assert.deepEqual(h.urls, ["/vault/?x=2#/feed"])
    assert.equal(nappletsOn(), false)
  }
})

test("the old stored tick is cleared; an address without ?napplets is left alone", () => {
  const store = mem(), h = hist(); store.setItem("nv-napplets", "1")
  assert.equal(forgetOldSwitch({ href: "https://a.example/vault/?shell=1" }, store, h), false)
  assert.equal(store.getItem("nv-napplets"), null)
  assert.deepEqual(h.urls, [])
})

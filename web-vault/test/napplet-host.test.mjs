// The napplet host's pure parts (src/napplet/srcdoc.js, csp.js): the artifact hash covers the napplet's own bytes,
// and the bootstrap lands first in <head> so it runs before any napplet script. The frame itself is checked in a
// browser (docs/napplets/P0_SPIKE.md).
import test from "node:test"
import assert from "node:assert/strict"
import { artifactHash, buildSrcdoc } from "../src/napplet/srcdoc.js"
import { frameCsp } from "../src/napplet/csp.js"

const html = `<!doctype html><html><head lang="en"><title>x</title><script>app()</script></head><body></body></html>`

test("artifact hash is sha256 of the napplet's own bytes", async () => {
  assert.equal(await artifactHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  const before = await artifactHash(html)
  buildSrcdoc(html, "boot()", frameCsp())
  assert.equal(await artifactHash(html), before)
})

test("bootstrap goes first in <head>, before any napplet script", () => {
  const doc = buildSrcdoc(html, "boot()", "default-src 'none'")
  assert.ok(doc.startsWith(`<!doctype html><html><head lang="en"><meta http-equiv="Content-Security-Policy" content="default-src 'none'"><script>boot()</script><title>`))
  assert.ok(doc.indexOf("boot()") < doc.indexOf("app()"))
})

test("a napplet without <head> still gets the bootstrap first", () => {
  const doc = buildSrcdoc("<p>hi</p><script>app()</script>", "boot()", "default-src 'none'")
  assert.ok(doc.indexOf("boot()") < doc.indexOf("app()"))
})

test("frame CSP denies all network: no connect, no remote images or media", () => {
  const csp = frameCsp()
  assert.match(csp, /default-src 'none'/)
  assert.match(csp, /connect-src 'none'/)
  assert.doesNotMatch(csp, /https:|wss:|http:/)
})

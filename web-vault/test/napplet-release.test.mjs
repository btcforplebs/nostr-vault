// Plan P8: the publishable files for our napplets (tools/napplet-release.mjs) are built from the same list the app runs
// and stay unsigned and unsent (Logen's decision 3); and the screens that run our napplets share one mount
// (usePaneNapplet.js).
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import crypto from "node:crypto"
import { release } from "../tools/napplet-release.mjs"
import { FIRST_PARTY_LIST } from "../src/napplet/first-party-list.js"
import { parseManifest, SHELL_DOMAINS } from "../src/napplet/manifest.js"

const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")

test("release: every napplet but the sample, its exact bytes, an unsigned 35129 our Apps pane accepts", () => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "nv-release-"))
  try {
    const rows = release(out)
    assert.deepEqual(rows.map(r => r.d), FIRST_PARTY_LIST.filter(n => !n.sample).map(n => n.dTag))
    for (const r of rows) {
      const html = fs.readFileSync(path.join(out, r.d, "index.html"))
      const t = JSON.parse(fs.readFileSync(path.join(out, r.d, "manifest.unsigned.json"), "utf8"))
      assert.equal(crypto.createHash("sha256").update(html).digest("hex"), r.x)
      for (const k of ["id", "sig", "pubkey", "created_at"]) assert.equal(k in t, false, `${r.d} has no ${k}: unsigned`)
      const m = parseManifest({ ...t, pubkey: "0".repeat(64) })
      assert.equal(m.hash, r.x)
      assert.ok(m.required.every(d => SHELL_DOMAINS.includes(d)), `${r.d} asks only for domains our shell has`)
      assert.ok(m.intents.every(i => /^napplet:[a-z]+\/[a-z]+$/.test(i)))
    }
    const wot = fs.readFileSync(path.join(out, "nv-wot", "index.html"), "utf8")
    assert.ok(!wot.includes("/*@wot-maths*/") && wot.includes("function layout(web, further"), "the WoT maths is in")
    assert.match(fs.readFileSync(path.join(out, "RELEASE.md"), "utf8"), /Nothing here is signed, uploaded or sent/)
  } finally { fs.rmSync(out, { recursive: true, force: true }) }
})

test("release: the tool has no way to sign or send", () => {
  const src = read("tools/napplet-release.mjs").split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n")
  assert.doesNotMatch(src, /fetch\(|WebSocket|pool\.|finalizeEvent|signEvent|nostr-tools/)
})

test("panes: Media, WoT and Messages mount through usePaneNapplet, not each their own copy", () => {
  for (const f of ["MediaPane", "WotPane", "MessagesPane"]) {
    const s = read(`src/napplet/${f}.jsx`)
    assert.match(s, /usePaneNapplet\(ctx, host, \{/, f)
    assert.doesNotMatch(s, /openNapplet|createBus\(|grantStore\(/, f)
  }
  assert.match(read("src/napplet/usePaneNapplet.js"), /firstParty: true[\s\S]*consent: async \(\) => null/)
})

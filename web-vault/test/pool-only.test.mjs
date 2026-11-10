// Rule 2 of fix 8 on web: there is exactly one verifier, and it is pool.js. nostr-tools' SimplePool passes
// verifyEvent to every relay, so every event the app believes came through it. A second pool — or a signature
// checker bolted onto a screen — would quietly become a second source of unverified state. This test fails the
// moment someone imports one, and pins the comments that say which three files rely on the pool.
import test from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const src = fileURLToPath(new URL("../src", import.meta.url))
const walk = dir => readdirSync(dir).flatMap(name => {
  const path = join(dir, name)
  return statSync(path).isDirectory() ? walk(path) : /\.jsx?$/.test(name) ? [path] : []
})
const files = walk(src)
const rel = path => relative(src, path).replaceAll("\\", "/")
const text = path => readFileSync(path, "utf8")

test("onlyPoolImportsNostrTools", () => {
  const importing = files.filter(f => text(f).includes("nostr-tools/pool")).map(rel).sort()
  assert.deepEqual(importing, ["net/pool.js"], "a second pool: nostr-tools' SimplePool is the only verifier, and it lives in net/pool.js")
  const constructing = files.filter(f => /\bnew SimplePool\b/.test(text(f))).map(rel).sort()
  assert.deepEqual(constructing, [], "net/pool.js extends SimplePool; nothing else builds one")

  const marker = "Safe only because this event came through pool.js"
  for (const f of ["net/profiles.js", "net/dms.js", "net/vault-lists.js"])
    assert.ok(text(join(src, f)).includes(marker), `${f} lost the comment that says why it needs no verify of its own`)
})

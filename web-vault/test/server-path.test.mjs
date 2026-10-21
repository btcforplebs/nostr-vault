// server.mjs serves dist/ only: an encoded "../" must not reach a sibling directory that shares dist's name prefix.
import { test } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"; import os from "node:os"; import path from "node:path"
import { startServer } from "./support/serve.mjs"

test("the dev server refuses a path into a sibling of dist/, and still serves dist/", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nv-serve-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  fs.mkdirSync(path.join(dir, "dist")); fs.mkdirSync(path.join(dir, "dist-secret"))
  fs.writeFileSync(path.join(dir, "dist", "index.html"), "app")
  fs.writeFileSync(path.join(dir, "dist-secret", "key.txt"), "secret")
  const base = await startServer(t, new URL("../server.mjs", import.meta.url), dir)
  const get = async p => { const r = await fetch(base + p); return { status: r.status, body: await r.text() } }
  assert.deepEqual(await get("/vault/%2e%2e%2fdist-secret%2fkey.txt"), { status: 403, body: "" })
  assert.deepEqual(await get("/vault/%2e%2e%2f%2e%2e%2fetc%2fpasswd"), { status: 403, body: "" })
  assert.deepEqual(await get("/vault/"), { status: 200, body: "app" })
  assert.deepEqual(await get("/vault/index.html"), { status: 200, body: "app" })
})

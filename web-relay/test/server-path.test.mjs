// server.mjs serves ../website/relay/ only: an encoded "../" must not reach a sibling that shares its name prefix.
import { test } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"; import os from "node:os"; import path from "node:path"
import { startServer } from "./support/serve.mjs"

test("the dev server refuses a path into a sibling of its root, and still serves the root", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nv-serve-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  for (const d of ["web-relay", "website/relay", "website/relay-secret"]) fs.mkdirSync(path.join(dir, d), { recursive: true })
  fs.writeFileSync(path.join(dir, "website/relay/index.html"), "relay")
  fs.writeFileSync(path.join(dir, "website/relay-secret/key.txt"), "secret")
  const base = await startServer(t, new URL("../server.mjs", import.meta.url), path.join(dir, "web-relay"))
  const get = async p => { const r = await fetch(base + p); return { status: r.status, body: await r.text() } }
  assert.deepEqual(await get("/relay/%2e%2e%2frelay-secret%2fkey.txt"), { status: 403, body: "" })
  assert.deepEqual(await get("/relay/%2e%2e%2f%2e%2e%2fetc%2fpasswd"), { status: 403, body: "" })
  assert.deepEqual(await get("/relay/"), { status: 200, body: "relay" })
})

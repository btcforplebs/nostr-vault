// The iPhone Blossom dashboard's numbers on the web gallery: Total Files, Storage Used, Active Mirrors, Backed Up (on
// every one of your servers), and each server's health.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { galleryStats, formatBytes, BlossomStats } = await import("../src/screens/BlossomStats.jsx")
const A = "https://a.example", B = "https://b.example"
const blobs = [{ size: 1_500_000, servers: [A, B] }, { size: 500_000, servers: [A] }, { size: 0, servers: [A, B] }]

test("stats: files, bytes, servers answering of configured, and the share on every server", () => {
  assert.deepEqual(galleryStats(blobs, [A, B], { [A]: "ok", [B]: "ok" }), { totalFiles: 3, size: 2_000_000, mirrors: 2, answering: 2, backedUp: 2, percent: 66 })
  assert.equal(galleryStats(blobs, [A, B], { [A]: "ok", [B]: "HTTP 401" }).percent, null, "a server that didn't answer could hold anything")
  assert.equal(galleryStats([], [A], { [A]: "ok" }).percent, 0)
  assert.equal(galleryStats(blobs, [], {}).backedUp, 0, "no servers, nothing backed up")
})

test("a server's health: Healthy, Offline when it didn't answer, Refused with its reason", async () => {
  const { health } = await import("../src/screens/BlossomStats.jsx")
  assert.equal(health("ok"), "Healthy")
  assert.equal(health("didn't answer"), "Offline")
  assert.equal(health("Failed to fetch"), "Offline")
  assert.equal(health(undefined), "Offline")
  assert.equal(health("Auth header not found"), "Refused · Auth header not found")
})

test("sizes read like the iPhone's file sizes", () => {
  assert.equal(formatBytes(0), "Zero KB")
  assert.equal(formatBytes(512), "512 bytes")
  assert.equal(formatBytes(2_000), "2 KB")
  assert.equal(formatBytes(2_000_000), "2 MB")
  assert.equal(formatBytes(1_234_567_890), "1.2 GB")
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
test("the header shows the four numbers and each server's health", () => {
  const text = st => walk(BlossomStats({ blobs, servers: [A, B], status: st })).filter(x => typeof x === "string").join(" ")
  const t = text({ [A]: "ok", [B]: "ok" })
  for (const w of ["Total Files", "Storage Used", "Active Mirrors", "Backed Up", "2/2", "66%", "2 MB", "a.example", "Healthy", "1 not on every server"]) assert.ok(t.includes(w), w)
  const d = text({ [A]: "ok", [B]: "HTTP 401" })
  for (const w of ["1/2", "?", "Refused · HTTP 401", "1 didn't list your files, so Backed Up can't be told"]) assert.ok(d.includes(w), w)
  assert.equal(d.includes("0%"), false)
  assert.match(readFileSync(new URL("../src/screens/BlossomGallery.jsx", import.meta.url), "utf8"), /<BlossomStats blobs=\{found\.blobs\} servers=\{servers\} status=\{found\.status\} \/>/)
})

// Upload in Vault › Media: each file through the note-photo upload path (one signed 24242 per file), added to the
// gallery as held by the server that took it; failures named per file; hidden when signed in read-only.
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
const { uploadFiles, uploadNote, BlossomUpload } = await import("../src/screens/BlossomUpload.jsx")
const S1 = "https://one.example", S2 = "https://two.example"

test("each file goes through the upload path; successes become gallery files on the server that took them", async () => {
  const seen = []
  const upload = async (file, { servers }) => {
    seen.push([file.name, servers])
    if (file.name === "bad.mov") throw new Error("No media server took it. one.example: too big")
    return { url: `${S1}/${file.name}`, sha256: file.name.padEnd(64, "0"), mime: file.type, size: 10, server: S1 }
  }
  const files = [{ name: "a.jpg", type: "image/jpeg" }, { name: "bad.mov", type: "video/quicktime" }, { name: "c.mp4", type: "video/mp4" }]
  const r = await uploadFiles(files, { ctx: {}, servers: [S1, S2], upload, now: () => 1000 })
  assert.deepEqual(seen.map(s => s[0]), ["a.jpg", "bad.mov", "c.mp4"])
  assert.deepEqual(r.added.map(b => [b.kind, b.servers, b.uploaded]), [["photo", [S1], 1000], ["video", [S1], 1000]])
  assert.deepEqual(r.errors, ["bad.mov: No media server took it. one.example: too big"])
  assert.equal(uploadNote(r, [S1, S2]), "Uploaded 2 files to one.example. Open one to copy it to your other servers. bad.mov: No media server took it. one.example: too big")
  assert.equal(uploadNote({ added: r.added.slice(0, 1), errors: [] }, [S1]), "Uploaded 1 file to one.example.")
})

test("no Upload when signed in read-only or with no servers", () => {
  assert.equal(BlossomUpload({ ctx: { signer: { readOnly: true } }, servers: [S1], onAdded() {} }), null)
  assert.equal(BlossomUpload({ ctx: { signer: {} }, servers: [], onAdded() {} }), null)
})

test("the upload is the note-photo path (net/upload.js uploadPhoto), not a second signing path", () => {
  const src = readFileSync(new URL("../src/screens/BlossomUpload.jsx", import.meta.url), "utf8")
  assert.match(src, /import \{ uploadPhoto \} from "\.\.\/net\/upload\.js"/)
  assert.equal(/signEvent|finalizeEvent/.test(src), false)
})

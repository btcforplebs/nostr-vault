// An https photo whose server fails gets one mesh try. Whatever that try finds, a failed https photo stays the plain
// broken image; "Couldn't reach the owner's vault" is only for a vault link (.fips) whose vault was asked.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { npubEncode } from "nostr-tools/nip19"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { transformSync } from "rolldown/utils"
import { createFipsMedia, noVault } from "../src/net/fips-media.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { afterMeshFail } = await import("../src/components/MediaImage.jsx")

const A = "a1".repeat(32), SHA = "487dc1578912f424773b0befc4eff491f026f0f24652f1d4ff66a85639455217"
const SK = generateSecretKey(), P = getPublicKey(SK)
const listing = vaults => async () => [finalizeEvent({ kind: 10063, created_at: 1, content: "", tags: vaults.map(v => ["server", `fipsmesh://${npubEncode(v)}/`]) }, SK)]
const photo = { url: `https://blossom.example/${SHA}.jpg`, x: SHA }
const fips = { url: `http://${npubEncode(A)}.fips/${SHA}` }
const rejection = p => p.then(() => assert.fail("expected a rejection"), e => e)
const deadVault = async () => ({ getBlob: async () => { throw new Error("404") } })

test("fallback marks 'no vault to ask' apart from a vault that was asked", async () => {
  const none = createFipsMedia({ allow: () => true, startReader: deadVault, query: listing([]) })
  for (const [why, item] of [["no mesh vault", photo], ["no hash", { url: photo.url }], ["no mesh vault", fips]]) {
    const e = await rejection(none.fallback(item, P))
    assert.match(e.message, new RegExp(why))
    assert.ok(noVault(e), `${why}: nothing was asked`)
  }
  const asked = createFipsMedia({ allow: () => true, startReader: deadVault, query: listing([A]) })
  const e = await rejection(asked.fallback(photo, P))
  assert.ok(!noVault(e), `a listed vault that fails is a real miss (${e.message})`)
  assert.ok(!noVault(undefined) && !noVault(new Error("no mesh vault")), "only the marked rejection")
})

test("after a failed mesh try: https -> its own broken image; a .fips link -> not reachable, or unreached if asked", async () => {
  const none = createFipsMedia({ allow: () => true, startReader: deadVault, query: listing([]) })
  assert.equal(afterMeshFail(await rejection(none.fallback(photo, P)), photo), "web", "the plain (broken) https image")
  assert.equal(afterMeshFail(await rejection(none.fallback(fips, P)), fips), "failed", "no https copy to show")
  const asked = createFipsMedia({ allow: () => true, startReader: deadVault, query: listing([A]) })
  assert.equal(afterMeshFail(await rejection(asked.fallback(photo, P)), photo), "web",
    "an https photo is not the vault's link, even when the author's vault was asked for a copy")
  assert.equal(afterMeshFail(await rejection(asked.fallback(fips, P)), fips), "unreached", "the vault message")
})

test("MediaImage: a web photo whose try found no vault gets no second try, so it can't loop", () => {
  const src = readFileSync(new URL("../src/components/MediaImage.jsx", import.meta.url), "utf8")
  assert.match(src, /state === "web" && item\.x && !tried\.current && allowed\(author\)\) return setState\("wait"\)/)
  assert.match(src, /if \(next === "web"\) \{ tried\.current = true; setSrc\(item\.url\) \}/)
})

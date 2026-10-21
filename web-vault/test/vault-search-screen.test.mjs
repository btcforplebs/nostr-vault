// The Vault search screen against the iPhone's VaultSearchResults: 5 rows per section under All, 200 in one section,
// a hashtag opens its feed, and the iPhone's wording.
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
const { PREVIEW, SECTION_CAP, hashtagHref, Row } = await import("../src/screens/VaultSearch.jsx")
const src = readFileSync(new URL("../src/screens/VaultSearch.jsx", import.meta.url), "utf8")

test("All shows 5 per section and one section at most 200, as on the iPhone", () => {
  assert.equal(PREVIEW, 5)
  assert.equal(SECTION_CAP, 200)
  assert.match(src, /all\.slice\(0, SECTION_CAP\)/)
  assert.match(src, /Showing the newest \{SECTION_CAP\} of \{all\.length\}/)
})

test("a hashtag row opens that tag's feed (the same route a #tag in a note uses), not another search", () => {
  assert.equal(hashtagHref("Bitcoin"), "#/feed?tag=bitcoin")
  assert.equal(hashtagHref("café&x"), "#/feed?tag=caf%C3%A9%26x")
  const row = Row({ kind: "hashtags", item: "nostr", trusted: () => false })
  assert.equal(row.type, "a")
  assert.equal(row.props.href, "#/feed?tag=nostr")
  assert.match(readFileSync(new URL("../src/components/NoteText.jsx", import.meta.url), "utf8"), /#\/feed\?tag=\$\{encodeURIComponent\(/)
})

test("the iPhone's words: Search your Vault, Searching your Vault…, Nothing in your Vault matches", () => {
  for (const s of ["Search your Vault", "Searching your Vault…", "Nothing in your Vault matches", "Notes, people, hashtags, links, articles and media"]) assert.ok(src.includes(s), s)
  assert.equal(/your vault/.test(src.replace(/\/\/.*$/gm, "")), false, "lower-case vault left in the copy")
})

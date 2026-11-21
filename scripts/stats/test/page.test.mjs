import { test } from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { view } from "../../../website/stats/stats.js"

const sample = {
  generated_at: "2026-11-18T12:00:00.000Z",
  posting_users: 1234,
  by_platform: { Android: 35, iPhone: 23, iPad: 0, Mac: 2, Linux: 3, Web: 5 },
  active_7d: 29,
  active_30d: 57,
  github_downloads: 207,
  since: "2026-05-01",
}

test("view shows the totals, skips empty platforms and keeps their order", () => {
  const v = view(sample)
  assert.deepEqual(v.values, { posting_users: "1,234", active_7d: "29", active_30d: "57", github_downloads: "207" })
  assert.deepEqual(v.platforms, [["Android", "35"], ["iPhone", "23"], ["Mac", "2"], ["Linux", "3"], ["Web", "5"]])
  assert.equal(v.updated, "Last counted 2026-11-18 (UTC), from posts since 2026-05-01.")
})

test("view shows a dash when downloads could not be read, and null for a bad file", () => {
  assert.equal(view({ ...sample, github_downloads: null }).values.github_downloads, "–")
  assert.equal(view(null), null)
  assert.equal(view({ error: "x" }), null)
})

test("the page carries the method line and loads its script from the site, nothing inline", async () => {
  const html = await readFile(new URL("../../../website/stats/index.html", import.meta.url), "utf8")
  assert.match(html, /Counted from public posts tagged Nostr Vault\./)
  assert.match(html, /<script type="module" src="\/stats\/stats\.js"><\/script>/)
  assert.equal((html.match(/<script/g) ?? []).length, 1, "the site CSP (script-src 'self') blocks inline scripts")
  for (const key of Object.keys(view(sample).values)) assert.match(html, new RegExp(`data-stat="${key}"`))
})

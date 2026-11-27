// Search plan W5 (RESEARCH/NV_SEARCH_PLAN_2026_11_27.md 1c, 2.9): the Welcome / referrer / read-only sign-in people
// search orders by name match (no web of trust there yet), and hashtags go exact tag, then how many results carry it,
// then A-Z, in the Search tab and the Vault search. Throwaway hex keys, fake relay query.
import test from "node:test"
import assert from "node:assert/strict"
import { byNameMatch, rankTags } from "../src/net/people-rank.js"
import { searchPeople, hashtagsIn } from "../src/net/search.js"
import { hashtags } from "../src/net/vault-search.js"

const kind0 = (c, p, at = 1) => ({ id: c + at, kind: 0, pubkey: c.repeat(64), created_at: at, content: JSON.stringify(p), tags: [] })

test("people before an account: exact > starts with > a word starts with > contains, relay order inside each", () => {
  const evs = [kind0("1", { name: "Annabelle" }), kind0("2", { name: "Joanne" }), kind0("3", { name: "ann" }), kind0("4", { name: "Mary Ann" }), kind0("5", { name: "zed", about: "ann" }), kind0("6", { name: "Anna" })]
  assert.deepEqual(byNameMatch(evs, "Ann").map(e => e.pubkey[0]), ["3", "1", "6", "4", "2", "5"])
  assert.deepEqual(byNameMatch([{ kind: 0, pubkey: "x", content: "not json" }], "a").length, 1, "a bad profile stays, last")
})

test("searchPeople: one per pubkey (newest), then by name match", async () => {
  const sent = [kind0("1", { name: "Jackson" }), kind0("2", { name: "jack" }, 1), kind0("2", { name: "jack" }, 5)]
  let asked
  const r = await searchPeople("jack", { query: async (relays, filter) => { asked = filter; return sent } })
  assert.deepEqual(r.map(e => [e.pubkey[0], e.created_at]), [["2", 5], ["1", 1]])
  assert.deepEqual(asked.kinds, [0])
  for (const f of ["screens/WelcomeScreen.jsx", "screens/ReferrerStep.jsx", "components/ReadOnlySignIn.jsx"]) {
    const { readFileSync } = await import("node:fs")
    assert.match(readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8"), /await searchPeople\(/, f)
  }
})

test("hashtags: the exact tag first, then the most used, then A-Z", () => {
  assert.deepEqual(rankTags(new Map([["abitcoiners", 1], ["zbitcoinart", 3], ["bitcoin", 1], ["mbitcoin", 3]]), "#Bitcoin"), ["bitcoin", "mbitcoin", "zbitcoinart", "abitcoiners"])
  const notes = ["#zbitcoin #zbitcoin #zbitcoin", "#abitcoin", "#bitcoin", "#zbitcoin #abitcoin", "#abitcoin"].map((content, i) => ({ id: String(i), content }))
  assert.deepEqual(hashtagsIn(notes, "bitcoin"), ["bitcoin", "abitcoin", "zbitcoin"], "a tag three times in one note counts once")
  assert.deepEqual(hashtagsIn([...notes, { id: "x", content: "#zbitcoin" }, { id: "y", content: "#zbitcoin" }], "bitcoin"), ["bitcoin", "zbitcoin", "abitcoin"], "most used beats A-Z")
  const vault = [{ content: "#anostr", tags: [["t", "anostr"]] }, { content: "#anostr and #nostr" }, { content: "", tags: [["t", "znostr"]] }, { content: "#znostr" }, { content: "#znostr" }]
  assert.deepEqual(hashtags(vault, "nostr"), ["nostr", "znostr", "anostr"], "exact, then most notes (a tag in text and t tag of one note counts once), then A-Z")
})

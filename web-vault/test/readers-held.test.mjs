// Recipes and Marketplace keep loaded results per feed for the session. After an unfollow they must load again:
// Global is filtered by your web, and the held results still named the people only that follow brought in.
import test from "node:test"
import assert from "node:assert/strict"
import { followsDep, heldResults } from "../src/readers/held.js"

test("an unfollow misses the held results, so the feed loads again", () => {
  const held = heldResults()
  held.set("global", ["a", "b"], ["listing from someone b brought in"])
  assert.ok(held.has("global", ["b", "a"]), "the same follows in another order are the same list")
  assert.equal(held.has("global", ["a"]), false)
  assert.equal(held.get("global", ["a"]), undefined)
  assert.equal(held.has("following", ["a", "b"]), false)
})

test("a swap that keeps the count still changes the dependency", () => {
  assert.notEqual(followsDep(["a", "b"]), followsDep(["a", "c"]))
  assert.equal(followsDep(["b", "a"]), followsDep(["a", "b"]))
})

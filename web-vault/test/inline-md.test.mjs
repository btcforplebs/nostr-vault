import test from "node:test"
import assert from "node:assert/strict"
import { inlineMarks } from "../src/net/inline-md.js"

const flat = t => inlineMarks(t).map(m => m.type === "text" ? m.text : `<${m.type}>${m.text}`).join("|")

test("a note's inline markdown, as iOS draws it", () => {
  assert.equal(flat("so **very** good"), "so |<strong>very| good")
  assert.equal(flat("__also__ bold"), "<strong>also| bold")
  assert.equal(flat("an *aside* and _this_"), "an |<em>aside| and |<em>this")
  assert.equal(flat("~~no~~ yes"), "<del>no| yes")
  assert.equal(flat("run `npm ci` now"), "run |<code>npm ci| now")
})

test("plain text that only looks like markdown stays plain", () => {
  for (const t of ["snake_case_name here", "2 * 3 * 4", "price ** tbd", "a_b and c_d", "** spaced **", "file_name.txt"]) assert.equal(flat(t), t)
})

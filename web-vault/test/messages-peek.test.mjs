// The Messages peek panel's rules (src/desktop/space/messages-peek.js): unread first, Requests and blocked left out,
// and nothing drawn until the Messages screen has opened this account's messages.
import test from "node:test"
import assert from "node:assert/strict"
import { peekRows, peekOpen, PEEK_ROWS } from "../src/desktop/space/messages-peek.js"

const ME = "m".repeat(64)
const msg = (id, peer, at, from = peer) => [id, { id, peer, at, from, content: `${id} text` }]
const box = (...rows) => new Map(rows)

test("unread chats come first, each group newest first", () => {
  const messages = box(msg("a", "pa", 50), msg("b", "pb", 40), msg("c", "pc", 30), msg("d", "pd", 10))
  const counts = new Map([["pc", 1], ["pd", 3]])
  const rows = peekRows(messages, ME, new Set(), new Set(["pa", "pb", "pc", "pd"]), counts)
  assert.deepEqual(rows.map(r => r.peer), ["pc", "pd", "pa", "pb"])
  assert.deepEqual(rows.map(r => r.unread), [1, 3, 0, 0])
  assert.equal(rows[0].last.id, "c")
})

test("the last line is the newest message in the chat, mine or theirs", () => {
  const messages = box(msg("old", "pa", 10), msg("mine", "pa", 20, ME))
  const [row] = peekRows(messages, ME, new Set(), new Set(["pa"]), new Map())
  assert.equal(row.last.id, "mine")
  assert.equal(row.last.from, ME)
})

test("Requests and blocked people stay out", () => {
  const messages = box(msg("a", "friend", 30), msg("b", "stranger", 40), msg("c", "blocked", 50), msg("d", "wrote", 20), msg("e", "wrote", 21, ME))
  const counts = new Map([["stranger", 1], ["friend", 1]])
  const rows = peekRows(messages, ME, new Set(["blocked"]), new Set(["friend", "blocked"]), counts)
  // a stranger the user wrote to is in the inbox; one they never wrote to is a Request
  assert.deepEqual(rows.map(r => r.peer), ["friend", "wrote"])
})

test("at most PEEK_ROWS chats", () => {
  const all = Array.from({ length: PEEK_ROWS + 5 }, (_, i) => msg(`m${i}`, `p${i}`, i))
  const rows = peekRows(box(...all), ME, new Set(), new Set(all.map(([, m]) => m.peer)), new Map())
  assert.equal(rows.length, PEEK_ROWS)
  assert.equal(rows[0].peer, `p${PEEK_ROWS + 4}`)
})

test("nothing to draw until Messages has opened this account's messages", () => {
  assert.equal(peekOpen({ pubkey: null, messages: new Map(), loaded: false }, ME), false)
  assert.equal(peekOpen({ pubkey: "o".repeat(64), messages: box(msg("a", "pa", 1)), loaded: true }, ME), false)
  assert.equal(peekOpen({ pubkey: ME, messages: new Map(), loaded: false }, ME), false)
  assert.equal(peekOpen({ pubkey: ME, messages: new Map(), loaded: true }, ME), true)
  assert.equal(peekOpen({ pubkey: ME, messages: box(msg("a", "pa", 1)), loaded: false }, ME), true)
})

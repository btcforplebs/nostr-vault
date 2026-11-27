// Muted words match whole words and phrases (Logen 11-27, step W2), in notes and in messages: a conversation where the
// other person wrote one is hidden as a row, from the list, the peek, the badge and notifications.
import test from "node:test"
import assert from "node:assert/strict"
import { hasMutedWord, isMutedNote } from "../src/net/web-gate.js"
import { muteSet } from "../src/net/blocks.js"
import { conversations, threadShown } from "../src/net/dms.js"
import { mutedWordPeers, dmHiddenPeers } from "../src/net/dm-muted.js"
import { accountUnread } from "../src/components/useUnreadTotal.js"
import { hiddenFromUnread } from "../src/components/useDmTrust.js"
import { peekRows } from "../src/desktop/space/messages-peek.js"
import { dmNotices } from "../src/net/dm-notify.js"
import { forgetReadCache } from "../src/net/dm-read.js"

test("whole words only: 'ass' hides 'ass' and 'Ass!' but never 'class' or 'assume'", () => {
  const w = ["ass"]
  for (const t of ["ass", "what an ASS", "Ass!", "(ass)", "#ass", "ass's hat", "ass\nnext"]) assert.equal(hasMutedWord(t, w), true, t)
  for (const t of ["class", "assume", "bass guitar", "passé", "ass1", "1ass", "", null]) assert.equal(hasMutedWord(t, w), false, String(t))
})

test("phrases match across any run of spaces; letters of any script and combining marks are word parts", () => {
  assert.equal(hasMutedWord("a Crypto \n  SCAM here", ["crypto scam"]), true)
  assert.equal(hasMutedWord("cryptoscam", ["crypto scam"]), false)
  assert.equal(hasMutedWord("東京 選挙", ["選挙"]), true)
  assert.equal(hasMutedWord("café", ["cafe"]), false, "a combining accent makes it a longer word")
  assert.equal(hasMutedWord("café time", ["café"]), true)
})

test("regex characters in a muted word are matched literally", () => {
  assert.equal(hasMutedWord("I love c++ a lot", ["c++"]), true)
  assert.equal(hasMutedWord("I love cxx", ["c++"]), false)
  assert.equal(hasMutedWord("a.b", ["a.b"]), true)
  assert.equal(hasMutedWord("axb", ["a.b"]), false)
  assert.equal(hasMutedWord("price $5 (sale)", ["(sale)"]), true)
})

test("notes: the gate uses the whole-word rule", () => {
  const blocked = muteSet([], [["word", "ass"]])
  assert.equal(isMutedNote({ id: "1", kind: 1, tags: [], content: "first class seat" }, blocked), false)
  assert.equal(isMutedNote({ id: "2", kind: 1, tags: [], content: "kick ass" }, blocked), true)
})

const ME = "a".repeat(64), P = "b".repeat(64), Q = "c".repeat(64), R = "d".repeat(64)
const msg = (id, from, peer, at, content) => [id, { id, from, peer, at, content }]
const storage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) } }

test("messages: a conversation where they wrote a muted word is left out; one where only you wrote it stays", () => {
  const messages = new Map([
    msg("1", P, P, 10, "hello"), msg("2", P, P, 11, "free AIRDROP"),
    msg("3", ME, Q, 12, "is this an airdrop?"), msg("4", Q, Q, 13, "no"),
    msg("5", R, R, 14, "airdrops are fine"),
  ])
  const blocked = muteSet([], [["word", "airdrop"]])
  assert.deepEqual([...mutedWordPeers(messages, blocked.words)], [P])
  assert.deepEqual(conversations(messages, blocked).map(c => c.peer), [R, Q])
  assert.deepEqual(conversations(messages, muteSet()).map(c => c.peer), [R, Q, P], "no muted words: nothing hidden")
  assert.equal(dmHiddenPeers(messages, muteSet()) instanceof Set, true)
  assert.equal(threadShown(messages, P, { blocked, me: ME }).length, 2, "opened directly, the conversation still shows")
})

test("messages: the badge, the peek and notifications leave the muted conversation out", () => {
  forgetReadCache()
  const opts = { storage: storage(), clock: () => 1 }
  const messages = new Map([msg("1", P, P, 10, "free airdrop"), msg("2", Q, Q, 11, "hi")])
  const blocked = muteSet([], [["word", "airdrop"]])
  const trusted = new Set([P, Q])
  assert.equal(accountUnread({ pubkey: ME, messages }, ME, blocked, opts, trusted), 1)
  assert.equal(accountUnread({ pubkey: ME, messages }, ME, muteSet(), opts, trusted), 2)
  assert.deepEqual(peekRows(messages, ME, blocked, trusted, new Map()).map(r => r.peer), [Q])
  const hidden = hiddenFromUnread(messages, ME, blocked, trusted)
  const { notices } = dmNotices(messages, ME, { mark: 0, hidden, now: 100 })
  assert.deepEqual(notices.map(n => n.href), [`#/dm/${Q}`])
})

// Notifications: classifying `#p` events into rows (who / what / which note), folding several people on one note
// into one row, and the sats paid by a zap from its bolt11 (or the zap request's amount tag).
import test from "node:test"
import assert from "node:assert/strict"
import { groupNotifications, classify, replyTarget, reactionEmoji, zapSats, bolt11Sats, formatSats } from "../src/net/notifications.js"

const ME = "a".repeat(64), ALICE = "b".repeat(64), BOB = "c".repeat(64), CAROL = "d".repeat(64)
const N1 = "1".repeat(64), N2 = "2".repeat(64), N3 = "3".repeat(64)
let seq = 0
const ev = (kind, pubkey, tags, content = "", created_at = 1000 + seq) => ({ id: `${kind}-${pubkey.slice(0, 2)}-${++seq}`.padEnd(64, "0"), kind, pubkey, tags, content, created_at })
const zapReq = (sender, tags = [], extra = {}) => JSON.stringify({ kind: 9734, pubkey: sender, tags: [["p", ME], ...tags], content: "", ...extra })

test("a reply to the user's note is a reply row pointing at that note", () => {
  const r = classify(ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "nice"), ME)
  assert.equal(r.type, "reply")
  assert.equal(r.who, ALICE)
  assert.equal(r.noteId, N1)
})

test("a kind 1 with no e tag is a mention", () => {
  const r = classify(ev(1, ALICE, [["p", ME]], "hey nostr:npub…"), ME)
  assert.equal(r.type, "mention")
  assert.equal(r.noteId, null)
})

test("reply target: reply marker beats root, root beats positional, positional takes the last e", () => {
  assert.equal(replyTarget([["e", N1, "", "root"], ["e", N2, "", "reply"]]), N2)
  assert.equal(replyTarget([["e", N2, "", "reply"], ["e", N1, "", "root"]]), N2)
  assert.equal(replyTarget([["e", N1, "", "root"]]), N1)
  assert.equal(replyTarget([["e", N1], ["e", N2]]), N2)
  assert.equal(replyTarget([["e", "not-hex"], ["p", ME]]), null)
})

test("events that don't tag the user, or that the user sent, are not notifications", () => {
  assert.equal(classify(ev(1, ALICE, [["p", BOB]]), ME), null)
  assert.equal(classify(ev(7, ME, [["e", N1], ["p", ME]], "+"), ME), null)
  assert.equal(classify(ev(4, ALICE, [["p", ME]]), ME), null)
  assert.equal(classify({ kind: 1, pubkey: ALICE }, ME), null)
})

test("a repost and a reaction point at the last e tag", () => {
  const rp = classify(ev(6, ALICE, [["e", N1], ["p", ME]]), ME)
  assert.equal(rp.type, "repost")
  assert.equal(rp.noteId, N1)
  const rx = classify(ev(7, BOB, [["e", N2], ["e", N1], ["p", ME]], "🤙"), ME)
  assert.equal(rx.type, "reaction")
  assert.equal(rx.noteId, N1)
  assert.equal(rx.emoji, "🤙")
})

test("reaction content: + and empty are a heart, - is a thumbs down, long custom content is cut", () => {
  assert.equal(reactionEmoji("+"), "❤️")
  assert.equal(reactionEmoji(""), "❤️")
  assert.equal(reactionEmoji("-"), "👎")
  assert.equal(reactionEmoji("🔥"), "🔥")
  assert.equal(reactionEmoji(":a_long_shortcode:"), ":a_long_")
})

test("a zap's who is the zap request's sender, not the LNURL server that signed the 9735", () => {
  const LNURL = "e".repeat(64)
  const z = classify(ev(9735, LNURL, [["p", ME], ["e", N1], ["bolt11", "lnbc210n1pjfakefakefakefakefakefakefakefakefakefakefakefakefake"], ["description", zapReq(ALICE, [["e", N1]])]]), ME)
  assert.equal(z.type, "zap")
  assert.equal(z.who, ALICE)
  assert.equal(z.noteId, N1)
  assert.equal(z.sats, 21)
})

test("a zap with a broken description falls back to the P tag, then the 9735's own pubkey", () => {
  const LNURL = "e".repeat(64)
  assert.equal(classify(ev(9735, LNURL, [["p", ME], ["P", BOB], ["description", "{not json"]]), ME).who, BOB)
  assert.equal(classify(ev(9735, LNURL, [["p", ME]]), ME).who, LNURL)
})

test("the user zapping themself is not a notification", () => {
  assert.equal(classify(ev(9735, "e".repeat(64), [["p", ME], ["description", zapReq(ME)]]), ME), null)
})

test("bolt11 amounts: multipliers, no amount, not an invoice", () => {
  assert.equal(bolt11Sats("lnbc210n1pjfakefake"), 21)
  assert.equal(bolt11Sats("lnbc21u1pjfakefake"), 2100)
  assert.equal(bolt11Sats("lnbc1m1pjfakefake"), 100_000)
  assert.equal(bolt11Sats("lnbc11pjfakefake"), 100_000_000)
  assert.equal(bolt11Sats("lnbc2500u1pjfakefake"), 250_000)
  assert.equal(bolt11Sats("lnbc1500n1pjfakefake"), 150)
  assert.equal(bolt11Sats("lnbc10p1pjfakefake"), 0, "1 millisat rounds down to 0 sats")
  assert.equal(bolt11Sats("LNBC210N1PJFAKEFAKE"), 21, "case-insensitive")
  assert.equal(bolt11Sats("lntb210n1pjfakefake"), 21, "testnet")
  assert.equal(bolt11Sats("lnbc1pjfakefake"), 0, "no amount")
  assert.equal(bolt11Sats(""), 0)
  assert.equal(bolt11Sats(undefined), 0)
  assert.equal(bolt11Sats("not an invoice"), 0)
})

test("zapSats prefers the bolt11, then the zap request's amount tag in millisats", () => {
  assert.equal(zapSats(ev(9735, BOB, [["bolt11", "lnbc420n1x"], ["description", zapReq(ALICE, [["amount", "999000"]])]])), 42)
  assert.equal(zapSats(ev(9735, BOB, [["description", zapReq(ALICE, [["amount", "21000"]])]])), 21)
  assert.equal(zapSats(ev(9735, BOB, [["description", zapReq(ALICE, [["amount", "oops"]])]])), 0)
  assert.equal(zapSats(ev(9735, BOB, [])), 0)
})

test("formatSats: 21, 1.2k, 100k, 1.5M", () => {
  assert.equal(formatSats(21), "21")
  assert.equal(formatSats(1200), "1.2k")
  assert.equal(formatSats(1000), "1k")
  assert.equal(formatSats(100_000), "100k")
  assert.equal(formatSats(1_500_000), "1.5M")
})

test("grouping: newest first, own events out, duplicates out", () => {
  const evs = [
    ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "old", 100),
    ev(1, BOB, [["e", N1, "", "reply"], ["p", ME]], "new", 300),
    ev(1, ME, [["e", N1, "", "reply"], ["p", ME]], "mine", 400),
  ]
  const rows = groupNotifications([...evs, evs[0]], ME)
  assert.deepEqual(rows.map(r => r.events[0].content), ["new", "old"])
  assert.ok(rows.every(r => r.type === "reply" && r.who.length === 1))
})

test("grouping: reactions on the same note fold into one row; replies never fold", () => {
  const rows = groupNotifications([
    ev(7, ALICE, [["e", N1], ["p", ME]], "+", 10),
    ev(7, BOB, [["e", N1], ["p", ME]], "🔥", 30),
    ev(7, CAROL, [["e", N1], ["p", ME]], "+", 20),
    ev(7, ALICE, [["e", N2], ["p", ME]], "+", 25),
    ev(1, ALICE, [["e", N1, "", "reply"], ["p", ME]], "a", 5),
    ev(1, BOB, [["e", N1, "", "reply"], ["p", ME]], "b", 6),
  ], ME)
  assert.deepEqual(rows.map(r => [r.type, r.noteId === N1 ? "N1" : "N2", r.who.length]), [
    ["reaction", "N1", 3], ["reaction", "N2", 1], ["reply", "N1", 1], ["reply", "N1", 1],
  ])
  const folded = rows[0]
  assert.deepEqual(folded.who, [BOB, CAROL, ALICE], "newest reactor leads")
  assert.equal(folded.created_at, 30)
  assert.equal(folded.emoji, "🔥", "the row shows the newest reaction's emoji")
  assert.equal(folded.events.length, 3)
})

test("grouping: zaps on one note add up their sats, and one person twice is counted once in who", () => {
  const LNURL = "e".repeat(64)
  const zap = (sender, sats, t) => ev(9735, LNURL, [["p", ME], ["e", N3], ["bolt11", `lnbc${sats * 10}n1x`], ["description", zapReq(sender, [["e", N3]])]], "", t)
  const rows = groupNotifications([zap(ALICE, 21, 1), zap(ALICE, 21, 2), zap(BOB, 100, 3)], ME)
  assert.equal(rows.length, 1)
  assert.equal(rows[0].sats, 142)
  assert.deepEqual(rows[0].who, [BOB, ALICE])
})

test("grouping: a repost and a reaction on the same note stay separate rows", () => {
  const rows = groupNotifications([ev(6, ALICE, [["e", N1], ["p", ME]]), ev(7, ALICE, [["e", N1], ["p", ME]], "+")], ME)
  assert.deepEqual(rows.map(r => r.type).sort(), ["reaction", "repost"])
})

test("grouping: reactions with no e tag don't fold into each other", () => {
  const rows = groupNotifications([ev(7, ALICE, [["p", ME]], "+"), ev(7, BOB, [["p", ME]], "+")], ME)
  assert.equal(rows.length, 2)
})

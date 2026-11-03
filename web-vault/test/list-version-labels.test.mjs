// Recover a List's words: the app that saved a version (its client tag, else "An unknown app"), its count in the
// list's own noun, what it changed against the one before it, and "follow again" / "unfollow" titles.
import test from "node:test"
import assert from "node:assert/strict"
import { clientName, countLine, changeLine, changeTitles, mergeExplainer, saveLine } from "../src/net/list-version-labels.js"

test("the app comes from the first non-empty client tag", () => {
  assert.equal(clientName({ tags: [["p", "ab"], ["client", "Primal", "31990:x:y"]] }), "Primal")
  assert.equal(clientName({ tags: [["client", "  "], ["client", "Amethyst"]] }), "Amethyst")
  assert.equal(clientName({ tags: [["p", "ab"]] }), "An unknown app")
  assert.equal(clientName({}), "An unknown app")
})

test("counts use the list's noun", () => {
  assert.equal(countLine(3, 300), "300 follows")
  assert.equal(countLine(3, 1), "1 follow")
  assert.equal(countLine(3, 1009), "1,009 follows")
  assert.equal(countLine(10000, 2), "2 muted entries")
  assert.equal(countLine(10050, 1), "1 relay")
  assert.equal(countLine(10050, 4), "4 relays")
  assert.equal(countLine(10004, 2), "2 communities")
})

test("change against the version before", () => {
  assert.equal(changeLine({ added: 0, removed: 709 }), "−709")
  assert.equal(changeLine({ added: 3, removed: 709 }), "+3, −709")
  assert.equal(changeLine({ added: 2, removed: 0 }), "+2")
  assert.equal(changeLine({ added: 0, removed: 0 }), "no change")
})

test("titles say follow and unfollow, mute and unmute", () => {
  assert.deepEqual(changeTitles(3), { back: "Will follow again", gone: "Will unfollow", kept: "Still following" })
  assert.equal(changeTitles(10000).gone, "Will unmute")
  assert.equal(changeTitles(10003).back, "Will add back")
  assert.match(mergeExplainer(3), /Keeps everyone you follow now/)
  assert.match(mergeExplainer(10003), /Keeps everything in your list now/)
})

test("the confirm line", () => {
  assert.match(saveLine(3, "Follows", { total: 1009, added: 709, removed: 0 }), /^Saves your follows: you follow 709 again\./)
  assert.match(saveLine(3, "Follows", { total: 1008, added: 709, removed: 1 }), /you follow 709 again, 1 unfollowed\./)
  assert.match(saveLine(10003, "Bookmarks", { total: 5, added: 2, removed: 0 }), /^Saves your bookmarks as 5 entries: 2 back\./)
  assert.equal(saveLine(3, "Follows", { total: 3, added: 0, removed: 0 }), "Nothing to bring back.")
})

test("an ordinary-edit drop isn't claimed as the user's: the browser vault may miss other apps' edits (Tron, PR 1595)", async () => {
  const { leftOutLines, entryNote } = await import("../src/net/list-version-labels.js")
  const [one] = leftOutLines({ leftOut: 1, unsure: 0 })
  assert.match(one, /^1 dropped in an ordinary edit stays out\. .*can't tell whether you or another app took it out\. Tap Review to add it\.$/)
  assert.match(leftOutLines({ leftOut: 3 })[0], /^3 dropped .* stay out\. .*took them out\. Tap Review to add them\.$/)
  assert.doesNotMatch(leftOutLines({ leftOut: 2, unsure: 1 }).join(" "), /you removed yourself/)
  const d = at => `d${at}`
  assert.equal(entryNote({ status: "removed", at: 5 }, d), "Dropped d5, can't tell by whom")
  // Box mode: the box keeps every version published to it, so an ordinary edit there is the user's (Tod 2026-11-03).
  assert.equal(entryNote({ status: "removed", at: 5 }, d, { box: true }), "You removed this d5")
  assert.equal(entryNote({ status: "lost", at: 5 }, d, { box: true }), "Lost d5")
  assert.deepEqual(leftOutLines({ leftOut: 1 }, { box: true }), ["1 you removed yourself later stays out."])
  assert.equal(leftOutLines({ leftOut: 3, unsure: 1 }, { box: true })[0], "3 you removed yourself later stay out.")
  assert.match(leftOutLines({ leftOut: 3, unsure: 1 }, { box: true })[1], /^1 stays out because the versions in between/)
  assert.equal(entryNote({ status: "lost", at: 5 }, d), "Lost d5")
  assert.equal(entryNote({ status: "unsure", at: 5 }, d), "Gone d5, can't tell why")
  assert.equal(entryNote({ status: "current", at: 0 }, d), "")
  assert.equal(entryNote({ status: "back", at: 0 }, d), "")
})

test("the NIP-44 note only when private entries are saved over a NIP-04 list", async () => {
  const { needsNip44Note } = await import("../src/net/list-version-labels.js")
  const nip04 = "abc?iv=def"
  const priv = [{ ticked: true, private: true }], pub = [{ ticked: true, private: false }], off = [{ ticked: false, private: true }]
  assert.equal(needsNip44Note(10000, nip04, priv), true)
  assert.equal(needsNip44Note(10000, nip04, pub), false, "no private entries saved")
  assert.equal(needsNip44Note(10000, nip04, off), false, "the private one is unticked")
  assert.equal(needsNip44Note(10000, "nip44payload", priv), false, "already NIP-44")
  assert.equal(needsNip44Note(10000, undefined, priv), false, "no current list")
  assert.equal(needsNip44Note(3, nip04, priv), false, "kind 3 content is relay hints")
})

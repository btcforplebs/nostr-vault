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

// Feed pins (docs/SPACE_LAYOUT.md, 2026-11-05): { type: "feed", id } on the rail, the iPad's FeedMode raw value in lower
// case; it opens the Feed switched to that type. Older apps keep an unknown type in place (rule 3).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { favourite, pinKey, pinHref, pin, unpin, isPinned, normalizePins, feedPinToWeb, webFeedToPin } from "../src/desktop/rail/rail-favs.js"

test("a feed pin normalises, keys and links like the iPad's", () => {
  const music = favourite("feed", " Music ")
  assert.deepEqual(music, { type: "feed", id: "music" })
  assert.equal(pinKey(music), "feed:music")
  assert.equal(pinHref(music), "#/feed?feed=music")
  assert.equal(favourite("feed", "two words"), null)
  assert.equal(favourite("feed", ""), null)
})

test("Hashtags is 'hashtags' in the layout and 'hashtag' on the web", () => {
  assert.equal(pinHref(favourite("feed", "hashtags")), "#/feed?feed=hashtag")
  assert.equal(feedPinToWeb("hashtags"), "hashtag")
  assert.equal(webFeedToPin("hashtag"), "hashtags")
})

test("pinned once, taken off, and kept through a save and read", () => {
  const f = favourite("feed", "recipes")
  let pins = pin([{ type: "section", id: "feed" }], f)
  assert.equal(pin(pins, f), pins, "the same feed is pinned once")
  assert.ok(isPinned(pins, f))
  assert.ok(normalizePins(JSON.parse(JSON.stringify(pins))).some(p => p.type === "feed" && p.id === "recipes"))
  assert.ok(!isPinned(unpin(pins, "feed:recipes"), f))
})

test("Your space's Edit offers every feed type but Following, as chips that pin and unpin", () => {
  const dock = readFileSync(new URL("../src/desktop/space/SpaceDock.jsx", import.meta.url), "utf8")
  assert.match(dock, /\{editing && <FeedPins pins=\{layout\.pins\}/)
  assert.match(dock, /isPinned\(l\.pins, f\) \? unpin\(l\.pins, pinKey\(f\)\) : pin\(l\.pins, f\)/)
  const names = readFileSync(new URL("../src/desktop/rail/RailFavs.jsx", import.meta.url), "utf8")
  assert.doesNotMatch(names.match(/FEED_NAME = \{[^}]*\}/)[0], /following/)
})

// The iPhone's NoteTaggingTests (HavenApp/MediaLogicTests/.../NoteTaggingTests.swift), case for case.
import test from "node:test"
import assert from "node:assert/strict"
import { hashtagTags, hashtags, splitHashtags } from "../src/net/hashtags.js"

test("extracts hashtags in order without the hash", () => assert.deepEqual(hashtags("gm #nostr and #bitcoin"), ["nostr", "bitcoin"]))
test("collapses case variants", () => assert.deepEqual(hashtags("#Bitcoin #bitcoin #BITCOIN"), ["bitcoin"]))
test("a URL fragment is not a tag", () => assert.deepEqual(hashtags("see https://example.com/docs#installation for #help"), ["help"]))
test("ignores nostr and relay references", () => assert.deepEqual(hashtags("wss://relay.example/#room nostr:npub1abc#x plain #tag"), ["tag"]))
test("ignores a hash that follows a word character", () => {
  assert.deepEqual(hashtags("I write C# daily"), [])
  assert.deepEqual(hashtags("a#b"), [])
})
test("needs a letter, so digit-only runs are not tags", () => {
  assert.deepEqual(hashtags("we are #1 today"), [])
  assert.deepEqual(hashtags("#nostr2"), ["nostr2"])
})
test("strips surrounding punctuation", () => assert.deepEqual(hashtags("(#nostr), #bitcoin. #freedom!"), ["nostr", "bitcoin", "freedom"]))
test("matches non-Latin hashtags", () => assert.deepEqual(hashtags("おはよう #日本"), ["日本"]))
test("skips runs longer than the length guard", () => assert.deepEqual(hashtags(`#${"a".repeat(65)} #ok`), ["ok"]))
test("builds t tags", () => assert.deepEqual(hashtagTags("#nostr #bitcoin"), [["t", "nostr"], ["t", "bitcoin"]]))

test("splitHashtags: tags at odd places, keeping the text and spelling around them", () => {
  assert.deepEqual(splitHashtags("gm #Nostr, we are #1 and C# fans #日本"), ["gm ", "#Nostr", ", we are #1 and C# fans ", "#日本", ""])
  assert.deepEqual(splitHashtags("no tags"), ["no tags"])
})

test("a #tag link's address picks that tag's feed; other addresses pick nothing", async () => {
  const { tagChoice } = await import("../src/net/feeds.js")
  assert.deepEqual(tagChoice("#/feed?tag=Bitcoin"), { mode: "hashtag", tag: "bitcoin" })
  assert.deepEqual(tagChoice("#/feed?note=abc&tag=%E6%97%A5%E6%9C%AC"), { mode: "hashtag", tag: "日本" })
  assert.equal(tagChoice("#/feed"), null)
  assert.equal(tagChoice("#/feed?tag=two%20words"), null)
})

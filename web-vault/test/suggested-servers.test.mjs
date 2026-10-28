// Settings › Media Servers › Suggested: a server drops out once the account lists it, however it was typed, and
// every suggestion is one uploads would actually use. Same list as iOS and Android.
import test from "node:test"
import assert from "node:assert/strict"
import { SUGGESTED_MEDIA_SERVERS, notYetAdded, suggestionHost } from "../src/net/suggested-servers.js"
import { serverUrl } from "../src/net/upload.js"

const hosts = list => list.map(s => suggestionHost(s.url))

test("an empty list shows every suggestion", () => {
  assert.deepEqual(notYetAdded([]), SUGGESTED_MEDIA_SERVERS)
})

test("a listed server is hidden even with a slash, case or no scheme", () => {
  assert.ok(!hosts(notYetAdded(["https://Blossom.Primal.net/"])).includes("blossom.primal.net"))
  assert.ok(!hosts(notYetAdded(["nostr.media"])).includes("nostr.media"))
  assert.equal(notYetAdded(["https://blossom.primal.net"]).length, SUGGESTED_MEDIA_SERVERS.length - 1)
})

test("a typed nostr.build address hides blossom.nostr.build, where the apps upload it", () => {
  assert.ok(!hosts(notYetAdded(["https://nostr.build"])).includes("blossom.nostr.build"))
  assert.ok(!hosts(notYetAdded(["https://image.nostr.build"])).includes("blossom.nostr.build"))
})

test("other or junk entries hide nothing", () => {
  assert.deepEqual(notYetAdded(["https://cdn.example.com", "", " ", "http://[bad"]), SUGGESTED_MEDIA_SERVERS)
})

test("every suggestion is an https server uploads use, listed once, with a note", () => {
  for (const s of SUGGESTED_MEDIA_SERVERS) {
    assert.equal(serverUrl(s.url), s.url)
    assert.ok(s.url.startsWith("https://") && s.note)
  }
  assert.deepEqual(hosts(SUGGESTED_MEDIA_SERVERS), ["blossom.primal.net", "blossom.nostr.build", "nostr.media", "blossom.azzamo.media", "blossom.jumble.social", "nostrmedia.com"])
})

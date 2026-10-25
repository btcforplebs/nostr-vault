// "Open in …" links (src/net/web-link.js) against the iPhone's NostrWebLink (HavenApp/HavenApp/Models/NostrWebLink.swift).
// Every `expected` below is what the Swift returned for the same input: the Swift file, Bech32.swift and
// VaultNoteScope.swift compiled with a small main that prints one answer per case (2026-10-25). Same string, not
// just the same address: the TLV order matters for that.
import { test } from "node:test"
import assert from "node:assert/strict"
import { decode } from "nostr-tools/nip19"
import { MAX_RELAY_HINTS, SITE_NAMES, eventWebLink, liveStreamLink, longFormLink, naddr, nprofile, profileLink } from "../src/net/web-link.js"

const PK = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
const LONG_RELAY = "wss://" + "a".repeat(260) + ".com"

const CASES = [
  {"name":"recipe nostrcooking","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","pancakes"],["t","nostrcooking"],["title","Pancakes"]],"expected":{"url":"https://zap.cooking/recipe/naddr1qqy8qctwvdskketnqgsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8grqsqqqa28x5nk4v","site":"zap.cooking"}},
  {"name":"recipe zapcooking","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","soup"],["t","zapcooking"]],"expected":{"url":"https://zap.cooking/recipe/naddr1qqz8xmm4wqpzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053vaqvzqqqr4guljkt5z","site":"zap.cooking"}},
  {"name":"recipe tag in capitals","op":"longForm","kind":30023,"pubkey":PK,"tags":[["t","NostrCooking"],["d","stew"]],"expected":{"url":"https://zap.cooking/recipe/naddr1qqz8xar9wupzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053vaqvzqqqr4guc350a3","site":"zap.cooking"}},
  {"name":"category tag alone is not a recipe","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","pie"],["t","zapcooking-dessert"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqphq6t9qgsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8grqsqqqa28jy0q2v","site":"YakiHonne"}},
  {"name":"bare t tag is not a recipe","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","pie"],["t"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqphq6t9qgsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8grqsqqqa28jy0q2v","site":"YakiHonne"}},
  {"name":"article","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","essay"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqzk2umnv9usygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqw4rsj8cz7p","site":"YakiHonne"}},
  {"name":"article, unicode d","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","café-☕"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqykxctxcw5jmc5cj5pzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053vaqvzqqqr4guzfzaqy","site":"YakiHonne"}},
  {"name":"article, empty d","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d",""]],"expected":{"url":"https://yakihonne.com/article/naddr1qqqqygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqw4rsq8h3sh","site":"YakiHonne"}},
  {"name":"article, bare d tag skipped","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d"],["d","second"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqr8xetrdahxgq3q80cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsxpqqqp65wf6xw6k","site":"YakiHonne"}},
  {"name":"article, d of 255 bytes","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","x".repeat(255)]],"expected":{"url":"https://yakihonne.com/article/naddr1qrlhs7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0pu8s7rc0puqygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqw4rsy48n9d","site":"YakiHonne"}},
  {"name":"article, d of 256 bytes","op":"longForm","kind":30023,"pubkey":PK,"tags":[["d","x".repeat(256)]],"expected":null},
  {"name":"article, capital hex key","op":"longForm","kind":30023,"pubkey":PK.toUpperCase(),"tags":[["d","essay"]],"expected":{"url":"https://yakihonne.com/article/naddr1qqzk2umnv9usygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqw4rsj8cz7p","site":"YakiHonne"}},
  {"name":"no d tag","op":"longForm","kind":30023,"pubkey":PK,"tags":[["t","nostrcooking"]],"expected":null},
  {"name":"not long-form","op":"longForm","kind":1,"pubkey":PK,"tags":[["d","x"]],"expected":null},
  {"name":"long-form, short key","op":"longForm","kind":30023,"pubkey":"abc","tags":[["d","x"]],"expected":null},
  {"name":"live stream with its relays","op":"liveStream","pubkey":PK,"identifier":"show","relays":["wss://relay.zap.stream","https://not-a-relay","wss://nos.lol","wss://third.example"],"expected":{"url":"https://zap.stream/naddr1qqz8x6r0wuq3vamnwvaz7tmjv4kxz7fw0fshqtnnw3ex2ctdqyxhwumn8ghj7mn0wvhxcmmvqgsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8grqsqqqan8v00tkc","site":"zap.stream"}},
  {"name":"live stream, ws relay","op":"liveStream","pubkey":PK,"identifier":"show","relays":["ws://localhost:7777"],"expected":{"url":"https://zap.stream/naddr1qqz8x6r0wuq3xamn8ghj7mr0vdskc6r0wd6r5dehxumsygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqwenskd99yd","site":"zap.stream"}},
  {"name":"live stream, no relays","op":"liveStream","pubkey":PK,"identifier":"show","relays":[],"expected":{"url":"https://zap.stream/naddr1qqz8x6r0wupzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053vaqvzqqqrkvujyxu8v","site":"zap.stream"}},
  {"name":"live stream, oversized relay keeps its slot","op":"liveStream","pubkey":PK,"identifier":"show","relays":[LONG_RELAY,"wss://nos.lol","wss://third.example"],"expected":{"url":"https://zap.stream/naddr1qqz8x6r0wuqs6amnwvaz7tmwdaejumr0dspzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053vaqvzqqqrkvu8lgufq","site":"zap.stream"}},
  {"name":"live stream, empty key","op":"liveStream","pubkey":"","identifier":"x","relays":[],"expected":null},
  {"name":"profile","op":"profile","pubkey":PK,"expected":{"url":"https://brainstorm.world/p/nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8g2lcy6q","site":"Brainstorm"}},
  {"name":"profile, short key","op":"profile","pubkey":"abc","expected":null},
  {"name":"profile, not hex","op":"profile","pubkey":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","expected":null},
  {"name":"profile, 33 bytes","op":"profile","pubkey":PK + "00","expected":null},
  {"name":"nprofile NIP-19 vector","op":"nprofile","pubkey":PK,"relays":["wss://r.x.com","wss://djbas.sadkb.com"],"expected":"nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"},
  {"name":"naddr with relay","op":"naddr","kind":30023,"pubkey":PK,"identifier":"my-article","relays":["wss://relay.example.com"],"expected":"naddr1qq9x67fdv9e8g6trd3jsz9mhwden5te0wfjkccte9ejhsctdwpkx2tnrdaksygpm7rrrljungc6q0tuh5hj7ue863q73qlheu4vywtzwhx42a7j9n5psgqqqw4rsc5ggs6"},
  {"name":"naddr kind -1","op":"naddr","kind":-1,"pubkey":PK,"identifier":"x","relays":[],"expected":null},
  {"name":"naddr kind 0","op":"naddr","kind":0,"pubkey":PK,"identifier":"x","relays":[],"expected":"naddr1qqqhsq3q80cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsxpqqqqqqqtcah30"},
  {"name":"naddr kind 2^32-1","op":"naddr","kind":4294967295,"pubkey":PK,"identifier":"x","relays":[],"expected":"naddr1qqqhsq3q80cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsxp8lllll7n09ch8"},
  {"name":"naddr kind 2^32","op":"naddr","kind":4294967296,"pubkey":PK,"identifier":"x","relays":[],"expected":null}
]

const run = c => {
  const pick = l => l && { url: l.url, site: l.site }
  switch (c.op) {
    case "longForm": return pick(longFormLink(c.kind, c.pubkey, c.tags))
    case "liveStream": return pick(liveStreamLink(c.pubkey, c.identifier, c.relays))
    case "profile": return pick(profileLink(c.pubkey))
    case "naddr": return naddr(c.kind, c.pubkey, c.identifier, c.relays)
    case "nprofile": return nprofile(c.pubkey, c.relays)
  }
}

for (const c of CASES) test(`same as Swift: ${c.name}`, () => assert.deepEqual(run(c), c.expected))

test("site names match the Swift menu items", () => {
  assert.deepEqual(SITE_NAMES, { recipe: "zap.cooking", liveStream: "zap.stream", article: "YakiHonne", profile: "Brainstorm" })
  assert.equal(MAX_RELAY_HINTS, 2)
})

test("a recipe link decodes back to the recipe's address", () => {
  const link = longFormLink(30023, PK, [["d", "pancakes"], ["t", "nostrcooking"]])
  assert.equal(link.type, "recipe")
  const { type, data } = decode(link.url.replace("https://zap.cooking/recipe/", ""))
  assert.equal(type, "naddr")
  assert.deepEqual(data, { kind: 30023, pubkey: PK, identifier: "pancakes", relays: [] })
})

test("eventWebLink: a post's own kind, key and tags (FeedNote.webLink)", () => {
  assert.equal(eventWebLink({ kind: 30023, pubkey: PK, tags: [["d", "essay"]] }).url, longFormLink(30023, PK, [["d", "essay"]]).url)
  assert.equal(eventWebLink({ kind: 1, pubkey: PK, tags: [] }), null)
  assert.equal(eventWebLink(null), null)
})

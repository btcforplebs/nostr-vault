// The public post page (thread-page/): the address it takes, the HTML and preview card it draws, and the relay reads
// behind it, with signed events from throwaway keys and a fake relay query.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { naddrEncode, neventEncode, noteEncode, npubEncode } from "nostr-tools/nip19"
import { readFileSync } from "node:fs"
import { appLink, noteParts, parseTarget, previewMeta, renderMissing, renderPost, replyList, threadUrl } from "../thread-page/page.js"
import { loadThread, relaysFor, safeRelay } from "../thread-page/fetch.js"

const alice = generateSecretKey(), bob = generateSecretKey()
const A = getPublicKey(alice), B = getPublicKey(bob)
let clock = 1_760_000_000
const sign = (sk, kind, content, tags = []) => finalizeEvent({ kind, content, tags, created_at: clock++ }, sk)
const profile = (sk, fields) => sign(sk, 0, JSON.stringify(fields))

test("the address: nevent, note, naddr, bare hex and nostr: prefixes; anything else is not a post", () => {
  const post = sign(alice, 1, "hi")
  const ne = neventEncode({ id: post.id, author: A, kind: 1, relays: ["wss://relay.example.com"] })
  assert.deepEqual(parseTarget(ne), { id: post.id, author: A, kind: 1, relays: ["wss://relay.example.com"] })
  assert.equal(parseTarget(`nostr:${noteEncode(post.id)}`).id, post.id)
  assert.equal(parseTarget(post.id).id, post.id)
  const na = parseTarget(naddrEncode({ kind: 30023, pubkey: A, identifier: "my-post" }))
  assert.deepEqual([na.kind, na.author, na.identifier, na.id], [30023, A, "my-post", null])
  assert.equal(parseTarget(npubEncode(A)), null)
  assert.equal(parseTarget("nevent1garbage"), null)
  assert.equal(parseTarget("<script>"), null)
})

test("threadUrl: a note shares as /thread/<nevent>, a long-form post as /thread/<naddr>", () => {
  const note = sign(alice, 1, "hi")
  assert.equal(threadUrl(note), `https://nostrvault.app/thread/${neventEncode({ id: note.id, author: A, kind: 1 })}`)
  const art = sign(alice, 30023, "body", [["d", "slug"]])
  assert.equal(threadUrl(art), `https://nostrvault.app/thread/${naddrEncode({ kind: 30023, pubkey: A, identifier: "slug" })}`)
  assert.equal(threadUrl({ id: "x" }), null)
})

test("note text: media links come out under the text (https only), nostr: refs become mentions and post links", () => {
  const ne = neventEncode({ id: "a".repeat(64) })
  const { parts, media } = noteParts(`look nostr:${npubEncode(B)} https://x.com/a.jpg. and http://y.com/b.png see nostr:${ne}\nhttps://example.com/page`, [["imeta", "url https://x.com/v.mp4", "m video/mp4"]])
  assert.deepEqual(media, [{ url: "https://x.com/a.jpg", type: "image" }, { url: "https://x.com/v.mp4", type: "video" }])
  assert.deepEqual(parts.filter(p => p.type !== "text"), [
    { type: "mention", pubkey: B }, { type: "link", url: "http://y.com/b.png" }, { type: "ref", code: ne }, { type: "link", url: "https://example.com/page" },
  ])
})

test("the page escapes everything the post and its people say", () => {
  const post = sign(alice, 1, `<img src=x onerror=alert(1)> "quoted" https://evil.com/"><script>.jpg`)
  const reply = sign(bob, 1, "</div><script>alert(2)</script>", [["e", post.id, "", "root"]])
  const profiles = new Map([[A, { name: `<b>Al"ice</b>`, picture: `https://x.com/p.jpg"onload="alert(3)`, nip05: null }]])
  const html = renderPost({ post, replies: replyList(post, [reply]), profiles, code: neventEncode({ id: post.id }) })
  assert.doesNotMatch(html, /<script>|<img src=x|<b>Al|onload="alert/)
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/)
  assert.match(html, /&lt;\/div&gt;&lt;script&gt;alert\(2\)/)
  assert.match(html, /<title>&lt;b&gt;Al&quot;ice&lt;\/b&gt; on Nostr<\/title>/)
})

test("the way in: a note's Reply, Repost, Like and Zap all open it in the web app; an article opens the web app", () => {
  const post = sign(alice, 1, "hello")
  const html = renderPost({ post, replies: [], profiles: new Map(), code: neventEncode({ id: post.id }) })
  for (const label of ["Reply", "Repost", "Like", "Zap"])
    assert.match(html, new RegExp(`<a class="act" href="/vault/#/thread/${post.id}" aria-label="${label} in the web app">`))
  assert.match(html, new RegExp(`class="btn primary" href="/vault/#/thread/${post.id}">Reply on the web<`))
  assert.match(html, /class="btn" href="nostr:nevent1[a-z0-9]+">Open in the app</)
  assert.doesNotMatch(html, /<form/)
  const article = sign(alice, 30023, "# hi", [["d", "a"], ["title", "Hi"]])
  const ahtml = renderPost({ post: article, replies: [], profiles: new Map(), code: naddrEncode({ kind: 30023, pubkey: A, identifier: "a" }) })
  assert.doesNotMatch(ahtml, /class="act"/)
  assert.match(ahtml, /class="btn primary" href="\/vault\/">Open the web app</)
})

test("the preview card: author and text, the post's first photo as a large image, else the author's picture", () => {
  const profiles = new Map([[A, { name: "Alice", picture: "https://x.com/alice.jpg", nip05: null }], [B, { name: "Bob", picture: null, nip05: null }]])
  const photo = sign(alice, 1, `sunset with nostr:${npubEncode(B)} https://x.com/sun.webp`)
  const m = previewMeta(photo, profiles, "u")
  assert.deepEqual([m.title, m.description, m.image, m.imageIsMedia], ["Alice on Nostr", "sunset with @Bob", "https://x.com/sun.webp", true])
  const html = renderPost({ post: photo, replies: [], profiles, code: "c" })
  assert.match(html, /<meta property="og:image" content="https:\/\/x.com\/sun.webp">/)
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/)
  assert.match(html, /<link rel="canonical" href="https:\/\/nostrvault.app\/thread\/c">/)

  const text = previewMeta(sign(alice, 1, "x".repeat(400)), profiles, "u")
  assert.equal(text.image, "https://x.com/alice.jpg")
  assert.equal(text.imageIsMedia, false)
  assert.equal(text.description.length, 280)
  assert.equal(previewMeta(sign(bob, 1, "hi"), new Map(), "u").image, "https://nostrvault.app/assets/og-image.jpg")

  const art = sign(alice, 30023, "# Hi\n\nBody text here.", [["d", "s"], ["title", "My Article"], ["summary", "Short"], ["image", "https://x.com/cover.png"]])
  const am = previewMeta(art, profiles, "u")
  assert.deepEqual([am.title, am.description, am.image, am.imageIsMedia], ["My Article", "Short", "https://x.com/cover.png", true])
})

test("replies: a note's reply tree, nested and oldest first; a long-form post's replies flat", () => {
  const post = sign(alice, 1, "root")
  const r1 = sign(bob, 1, "first", [["e", post.id, "", "root"]])
  const r2 = sign(alice, 1, "nested", [["e", post.id, "", "root"], ["e", r1.id, "", "reply"]])
  const r3 = sign(bob, 1, "second", [["e", post.id, "", "root"]])
  const other = sign(bob, 1, "unrelated")
  assert.deepEqual(replyList(post, [r3, r2, other, r1]).map(r => [r.event.content, r.depth]), [["first", 1], ["nested", 2], ["second", 1]])

  const art = sign(alice, 30023, "body", [["d", "s"]])
  const c1 = sign(bob, 1111, "comment", [["A", `30023:${A}:s`]]), c2 = sign(alice, 1, "note reply", [["a", `30023:${A}:s`]])
  assert.deepEqual(replyList(art, [c2, c1, c1]).map(r => [r.event.content, r.depth]), [["comment", 1], ["note reply", 1]])
})

test("a browser goes straight into the web app on the post; the og: card stays for link previews", () => {
  const post = sign(alice, 1, "hello https://blossom.example/a.jpg")
  const html = renderPost({ post, replies: [], profiles: new Map(), code: neventEncode({ id: post.id }), hints: ["wss://relay.example"] })
  assert.match(html, new RegExp(`<meta name="nv-open" content="/vault/#/thread/${post.id}\\?r=wss%3A%2F%2Frelay.example">`))
  assert.equal(html.split("<script").length, 2, "one script")
  assert.match(html, /<script src="\/open-post.js"><\/script>\n<\/head>/, "the site's own, in the head, before the body draws")
  assert.match(html, /<meta property="og:image" content="https:\/\/blossom.example\/a.jpg">/)
  assert.doesNotMatch(html, /share-photos|data-vaults|data-x=/, "no mesh reader on this page any more: the app reads mesh photos")
  assert.doesNotMatch(renderMissing({ code: "nevent1x", valid: true }), /<script|nv-open/, "a page that isn't a post sends no one anywhere")

  assert.equal(appLink(post), `/vault/#/thread/${post.id}`)
  assert.equal(appLink(post, ["wss://a.example", "wss://b.example", "wss://c.example", "wss://d.example"]).split("r=").length, 4, "three hints at most")
  assert.equal(appLink({ id: post.id }, ['wss://x.example/"><script>']), `/vault/#/thread/${post.id}?r=wss%3A%2F%2Fx.example%2F%22%3E%3Cscript%3E`)

  const script = readFileSync(new URL("../../website/open-post.js", import.meta.url), "utf8")
  assert.match(script, /startsWith\("\/vault\/#\/thread\/"\)/, "open-post.js goes nowhere but a post in the web app")
  assert.match(script, /location\.replace\(/)
})

test("the /thread/ CSP: one script, the site's open-post.js; the page connects to nothing", () => {
  const conf = readFileSync(new URL("../../website/nginx.conf", import.meta.url), "utf8")
  const csp = /~\^\/thread\/\s+"([^"]+)"/.exec(conf)[1]
  const dir = name => csp.split(";").map(d => d.trim().split(/\s+/)).find(d => d[0] === name)?.slice(1)
  assert.deepEqual(dir("script-src"), ["https://nostrvault.app/open-post.js"])
  assert.deepEqual(dir("default-src"), ["'none'"])
  assert.equal(dir("connect-src"), undefined, "falls back to default-src 'none'")
  assert.doesNotMatch(csp, /unsafe-eval|wasm|unsafe-inline'; *script/)
})

test("not found and not a post: a 404 page that says which, no index", () => {
  assert.match(renderMissing({ code: "nevent1x", valid: true }), /couldn't find this post[\s\S]*href="nostr:nevent1x"/)
  assert.match(renderMissing({ code: "junk", valid: false }), /isn't a Nostr post link/)
  assert.match(renderMissing({ code: "junk", valid: false }), /<meta name="robots" content="noindex">/)
})

test("relay hints: only wss:// to a public host name, at most three, then the read relays", () => {
  assert.equal(safeRelay("wss://relay.example.com/"), "wss://relay.example.com")
  for (const bad of ["ws://relay.example.com", "https://relay.example.com", "wss://localhost", "wss://127.0.0.1", "wss://[::1]", "wss://10.0.0.5:7777", "wss://box", "wss://nas.local", "wss://u:p@relay.example.com", "junk"]) {
    assert.equal(safeRelay(bad), null, bad)
  }
  const rs = relaysFor({ relays: ["wss://a.com", "wss://localhost", "wss://b.com", "wss://c.com", "wss://d.com"] })
  assert.deepEqual(rs.slice(0, 3), ["wss://a.com", "wss://b.com", "wss://c.com"])
  assert.ok(rs.includes("wss://relay.damus.io") && !rs.includes("wss://d.com"))
})

/** A relay set holding `events`, answering filters by ids / kinds / authors / #e / #a / #A / #d. */
function fakeRelays(events) {
  const calls = []
  const query = async (relays, f) => {
    calls.push(f)
    return events.filter(ev =>
      (!f.ids || f.ids.includes(ev.id)) && (!f.kinds || f.kinds.includes(ev.kind)) && (!f.authors || f.authors.includes(ev.pubkey)) &&
      ["e", "a", "A", "d"].every(t => !f[`#${t}`] || ev.tags.some(x => x[0] === t && f[`#${t}`].includes(x[1]))))
  }
  return { query, calls }
}

test("loadThread: the post, its replies (deep ones one hop on), named people; forged events are dropped", async () => {
  const post = sign(alice, 1, `hello nostr:${npubEncode(B)}`)
  const r1 = sign(bob, 1, "reply", [["e", post.id, "", "root"]])
  const deep = sign(alice, 1, "old-style deep reply", [["e", r1.id]]) // tags only its parent
  const forged = { ...sign(bob, 1, "forged", [["e", post.id, "", "root"]]), content: "tampered" }
  const oldName = profile(alice, { name: "Old" }), newName = profile(alice, { name: "Alice", picture: "https://x.com/a.jpg" })
  const { query } = fakeRelays([post, r1, deep, forged, newName, oldName, profile(bob, { display_name: "Bob" })])
  const { post: got, events, profiles } = await loadThread({ id: post.id, relays: [] }, query)
  assert.equal(got.id, post.id)
  assert.deepEqual(events.map(e => e.content).sort(), ["old-style deep reply", "reply"])
  assert.equal(profiles.get(A).name, "Alice")
  assert.equal(profiles.get(B).name, "Bob")
  assert.deepEqual(replyList(got, events).map(r => [r.event.content, r.depth]), [["reply", 1], ["old-style deep reply", 2]])
})

test("loadThread: a forged copy of the post itself is not drawn; a missing post reads nothing more", async () => {
  const post = sign(alice, 1, "real")
  const { query, calls } = fakeRelays([{ ...post, content: "fake" }])
  const r = await loadThread({ id: post.id, relays: [] }, query)
  assert.equal(r.post, null)
  assert.equal(calls.some(f => f.kinds?.includes(0)), false)
})

test("loadThread: an naddr reads the newest version by that author and its replies by address", async () => {
  const v1 = sign(alice, 30023, "v1", [["d", "s"]]), v2 = sign(alice, 30023, "v2", [["d", "s"]])
  const imposter = sign(bob, 30023, "not hers", [["d", "s"]])
  const c = sign(bob, 1111, "nice", [["A", `30023:${A}:s`]])
  const { query } = fakeRelays([v1, v2, imposter, c])
  const r = await loadThread({ id: null, kind: 30023, author: A, identifier: "s", relays: [] }, query)
  assert.equal(r.post.content, "v2")
  assert.deepEqual(r.events.map(e => e.content), ["nice"])
})

// Messages (Logen, 2026-11-03): the search over names and message text, on this device only; the Requests tray at the
// top right instead of a row under the list; titles that give buttons room.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { searchChats, fold } from "../src/net/dm-search.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const msg = (id, peer, at, content) => [id, { id, peer, at, from: peer, content }]
const messages = new Map([msg("a", "pa", 10, "Are you coming to the meetup?"), msg("b", "pa", 20, "ok see you"), msg("c", "pb", 30, "Relay list: the second one"),
  msg("d", "pc", 40, "Café at noon"), msg("e", "pb", 35, "the MEETUP moved")])
const list = [{ peer: "pc", last: messages.get("d") }, { peer: "pb", last: messages.get("e") }, { peer: "pa", last: messages.get("b") }]
const names = { pa: "Juniper Vale", pb: "Dele Okafor", pc: "Zoë Marsh" }

test("an empty query gives the list back as it is", () => {
  assert.equal(searchChats(list, messages, "", pk => names[pk]), list)
  assert.equal(searchChats(list, messages, "   ", pk => names[pk]), list)
})

test("message text matches in any message of a chat, case and accents folded, the list's order kept", () => {
  const r = searchChats(list, messages, "meetup", pk => names[pk])
  assert.deepEqual(r.map(c => c.peer), ["pb", "pa"])
  assert.equal(r[0].hit.id, "e", "the newest matching message is what the row shows")
  assert.equal(r[1].hit.id, "a", "an older message matches too, not only the last line")
  assert.deepEqual(searchChats(list, messages, "cafe", pk => names[pk]).map(c => c.peer), ["pc"])
})

test("names match from profiles already loaded; a name-only match keeps the last line", () => {
  const r = searchChats(list, messages, "zoe", pk => names[pk])
  assert.deepEqual(r.map(c => [c.peer, c.hit]), [["pc", null]])
  assert.deepEqual(searchChats(list, messages, "okafor", pk => names[pk]).map(c => c.peer), ["pb"])
  assert.deepEqual(searchChats(list, messages, "nobody", pk => names[pk]), [])
  assert.equal(fold("  Zoë   MARSH "), "zoe marsh")
})

test("only chats in the list being searched come back: Requests stay out of a Messages search", () => {
  assert.deepEqual(searchChats(list.slice(0, 1), messages, "meetup", pk => names[pk]), [])
})

test("the search never leaves the page: no relay, fetch or signer in it", () => {
  for (const f of ["net/dm-search.js", "screens/MessagesTools.jsx"]) {
    const s = src(f)
    assert.doesNotMatch(s, /\bpool\b|fetch\(|querySync|fetchProfiles|nip50|search:/, f)
  }
  assert.match(src("screens/MessagesTools.jsx"), /getProfile\(pk\)/, "names come from profiles already loaded")
  const ms = src("screens/MessagesScreen.jsx")
  assert.match(ms, /const list = searchChats\(all, messages, query, searchName\)/)
  assert.match(ms, /fetchProfiles\(ctx\.vault, all\.map\(c => c\.peer\), relays\)/, "profile lookups follow the whole list, not the search")
})

test("Requests is a tray button at the top right with no count, not a row under the list", () => {
  const ms = src("screens/MessagesScreen.jsx"), tools = src("screens/MessagesTools.jsx")
  assert.match(ms, /\{!showRequests && <RequestsButton \/>\}/)
  assert.doesNotMatch(ms, /class="dm-row dm-requests"/)
  assert.match(tools, /href="#\/messages\/requests"/)
  assert.match(tools, /aria-label="Requests"/)
  assert.doesNotMatch(tools + src("styles/dms.css"), /dm-requests-badge|dm-requests-count/, "no count badge on Requests")
  assert.match(src("styles/dms.css"), /\.dm-head-actions \{[^}]*margin-left: auto;/)
})

test("headers: Messages and the compose sheet keep their titles for screen readers only; titles never wrap into buttons", () => {
  assert.match(src("screens/MessagesScreen.jsx"), /<h2 class=\{showRequests \? undefined : "sr-only"\}>/)
  assert.match(src("screens/ComposeScreen.jsx"), /<h2 class="sr-only">\{title\}<\/h2>/)
  assert.match(src("styles/compose.css"), /\.compose-post \{ grid-column: 3;/, "Post stays at the right with the title out of the grid")
  const app = src("styles/app.css")
  assert.match(app, /\.screen-head > h2 \{ min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; \}/)
  assert.match(app, /\.screen-head > \.button\.small, \.screen-head > button\.small \{ flex: none; white-space: nowrap; \}/)
  assert.match(app, /\.screen-head > span:empty \{ display: none; \}/, "the centring spacer no longer takes the title's room")
})

// How the Vault tab loads on a big account: each relay's answer handed on as it lands, zap receipts after their
// check, follower lists kept in this browser, rows built once, and answers newer than the list on screen held
// behind the "N new" pill. Throwaway keys and fake relays: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import {
  eachRelay, fetchInbound, fetchFollowerLists, fetchGivenZaps, compactLists, mergeLists, readLists, keepLists, followersOf,
  itemsFor, peopleOf, newestShown, splitArrivals, heldCount,
} from "../src/net/vault-lists.js"

const person = () => getPublicKey(generateSecretKey())
const ME = person(), ALICE = person(), BOB = person(), CAROL = person()
const N1 = "1".repeat(64)
let seq = 0
const ev = (kind, pubkey, tags = [], content = "", created_at = 1000 + ++seq) => ({ id: `${kind}-${pubkey.slice(0, 2)}-${++seq}`.padEnd(64, "0"), kind, pubkey, tags, content, created_at })
const mine = [{ ...ev(1, ME, [], "my note"), id: N1 }]
const sleep = ms => new Promise(r => setTimeout(r, ms))
const memStorage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

test("eachRelay hands a fast relay's answer on before a slow one answers, and drops what one already sent", async () => {
  const a = ev(1, ALICE, [["p", ME]]), b = ev(1, BOB, [["p", ME]])
  const answers = { "wss://fast": [a], "wss://slow": [a, b] }
  const query = async ([url]) => { if (url === "wss://slow") await sleep(40); return answers[url] }
  const seen = []
  const all = eachRelay(["wss://fast", "wss://slow"], {}, evs => seen.push(evs.map(e => e.id)), { query })
  await sleep(10)
  assert.deepEqual(seen, [[a.id]], "the fast relay drew without waiting on the slow one")
  assert.deepEqual((await all).map(e => e.id), [a.id, b.id])
  assert.deepEqual(seen[1], [b.id], "the slow relay's copy of `a` was dropped")
})

test("eachRelay rejects only when every relay failed", async () => {
  const boom = async () => { throw new Error("down") }
  await assert.rejects(eachRelay(["wss://x", "wss://y"], {}, () => {}, { query: boom }), /down/)
  const half = async ([url]) => { if (url === "wss://x") throw new Error("down"); return [] }
  assert.deepEqual(await eachRelay(["wss://x", "wss://y"], {}, () => {}, { query: half }), [])
})

test("fetchInbound draws replies first, zap receipts after their check, and keeps only checked ones in Haven", async () => {
  const reply = ev(1, ALICE, [["e", N1], ["p", ME]], "hi"), good = ev(9735, BOB, [["p", ME]]), forged = ev(9735, CAROL, [["p", ME]])
  const kept = []
  const vault = { inbox: { event: async e => { kept.push(e.id); return { ok: true } } } }
  let release
  const checked = new Promise(r => { release = r })
  const trust = async evs => { await checked; return evs.filter(e => e.id !== forged.id) }
  const drawn = []
  const done = fetchInbound(vault, ME, ["wss://r"], { trust, on: evs => drawn.push(evs.map(e => e.id)), query: async () => [reply, good, forged] })
  await sleep(10)
  assert.deepEqual(drawn, [[reply.id]], "the reply drew while the zaps were still being checked")
  release()
  await done
  assert.deepEqual(drawn[1], [good.id], "only the checked receipt follows")
  assert.deepEqual(kept.sort(), [reply.id, good.id].sort(), "the forged receipt is never kept")
})

test("a zap receipt that can't be checked now is drawn but not kept", async () => {
  const zap = ev(9735, BOB, [["p", ME]]), kept = [], drawn = []
  const vault = { inbox: { event: async e => { kept.push(e.id); return { ok: true } } } }
  await fetchInbound(vault, ME, ["wss://r"], { trust: async () => { throw new Error("offline") }, on: evs => drawn.push(...evs), query: async () => [zap] })
  assert.deepEqual(drawn.map(e => e.id), [zap.id])
  assert.deepEqual(kept, [])
})

test("follower lists arrive cut down per relay; zaps given only after their check", async () => {
  const full = { ...ev(3, ALICE, [["p", ME], ...Array.from({ length: 500 }, (_, i) => ["p", String(i).padStart(64, "0")])]) }
  const lists = []
  await fetchFollowerLists(ME, ["wss://r"], { on: l => lists.push(...l), query: async () => [full] })
  assert.deepEqual(lists, [{ id: full.id, kind: 3, pubkey: ALICE, created_at: full.created_at, tags: [["p", ME]] }])
  const given = [], z = ev(9735, BOB, [["P", ME]])
  await fetchGivenZaps(ME, ["wss://r"], { trust: async () => [], on: g => given.push(...g), query: async () => [z] })
  assert.deepEqual(given, [], "a receipt its check dropped is never handed on")
})

test("follower lists are kept between visits, small, and someone editing their list keeps their follow time", () => {
  const storage = memStorage()
  const first = ev(3, ALICE, [["p", ME], ["p", BOB]], "", 100)
  keepLists(ME, [first], storage)
  const back = readLists(ME, storage)
  assert.equal(followersOf(back, ME)[0].at, 100, "read back on the next visit")
  assert.ok(storage.getItem(`nv-vault-follower-lists:${ME}`).length < 300)
  const edited = ev(3, ALICE, [["p", ME], ["p", CAROL]], "", 500)
  const merged = mergeLists(back, [edited], ME)
  assert.deepEqual(followersOf(merged, ME), [{ pubkey: ALICE, at: 100 }], "an edited list is not a new follow")
  const unfollowed = mergeLists(merged, [ev(3, ALICE, [["p", BOB]], "", 600)], ME)
  assert.deepEqual(followersOf(unfollowed, ME), [])
  const again = mergeLists(unfollowed, [ev(3, ALICE, [["p", ME]], "", 700)], ME)
  assert.deepEqual(followersOf(again, ME), [{ pubkey: ALICE, at: 700 }], "following again is a new follow")
  assert.deepEqual(mergeLists(again, [ev(3, ALICE, [], "", 650)], ME), again, "an older list changes nothing")
  storage.setItem(`nv-vault-follower-lists:${ME}`, "{nope")
  assert.deepEqual(readLists(ME, storage), [])
})

test("sign-out forgets the kept follower lists", () => {
  const src = readFileSync(new URL("../src/haven/vault.js", import.meta.url), "utf8")
  assert.match(src, /storage\.removeItem\(`nv-vault-follower-lists:\$\{pubkey\}`\)/)
})

test("itemsFor builds the mode's rows, follow lines included; peopleOf names whoever those rows show", () => {
  const like1 = ev(7, ALICE, [["e", N1], ["p", ME]], "+"), like2 = ev(7, BOB, [["e", N1], ["p", ME]], "+"), like3 = ev(7, CAROL, [["e", N1], ["p", ME]], "+")
  const followers = [{ pubkey: CAROL, at: 5000 }]
  const rows = itemsFor("activity", "all", { own: mine, inbound: [like1, like2, like3], followers, me: ME })
  assert.deepEqual(rows.map(r => r.kind), ["follow", "like"])
  const people = peopleOf("activity", rows)
  assert.equal(people[0], CAROL)
  assert.equal(people.length, 3, "a folded line names its first two, as Who draws them")
  assert.deepEqual(peopleOf("followers", itemsFor("followers", "all", { followers, me: ME })), [CAROL])
})

test("the screen asks names once for everyone its rows name, on-screen rows first, and builds rows in a memo", () => {
  const src = readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /const items = useMemo\(\(\) => itemsFor\(/)
  assert.match(src, /peopleOf\(mode, items\.slice\(0, shown\)\)/)
  assert.match(src, /asked\.current\.add\(pk\)/)
  assert.doesNotMatch(src, /activityRows\(inbound, me\)/, "the old names pass left likers, zappers and follows out")
})

test("answers newer than the list on screen wait behind the pill; older ones fill in; nothing drawn yet takes all", () => {
  const old = ev(1, ALICE, [["p", ME]], "old", 100), late = ev(1, BOB, [["p", ME]], "new reply", 900)
  const top = newestShown([old])
  assert.equal(top, 100)
  assert.deepEqual(splitArrivals("inbound", [late], { top: 0, me: ME }), { now: [late], later: [] })
  const older = ev(1, CAROL, [["p", ME]], "older", 50)
  assert.deepEqual(splitArrivals("inbound", [late, older], { top, me: ME }), { now: [older], later: [late] })
  // Nothing it would draw (a like on a note that isn't loaded): no reason to hold it.
  const stray = ev(7, BOB, [["e", "9".repeat(64)], ["p", ME]], "+", 950)
  assert.deepEqual(splitArrivals("inbound", [stray], { top, me: ME, own: mine }).later, [])
  const lists = compactLists([ev(3, ALICE, [["p", ME]], "", 80)], ME)
  const fresh = compactLists([ev(3, ALICE, [["p", ME], ["p", BOB]], "", 990), ev(3, CAROL, [["p", ME]], "", 995)], ME)
  const split = splitArrivals("lists", fresh, { top, me: ME, lists })
  assert.deepEqual(split.now.map(l => l.pubkey), [ALICE], "an existing follower's edit goes in")
  assert.deepEqual(split.later.map(l => l.pubkey), [CAROL], "a new follower waits")
  assert.equal(heldCount({ inbound: [late], lists: split.later }, ME, mine), 2)
})

// Bookmarks (parity N1; iPhone Models/BookmarkList.swift, BookmarkMenuItem.swift, BookmarksView.swift): kind 10003,
// one public entry changed per tap, every other tag and the private part kept.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { entryFor, entries, toggled, menuState, privateEntries, setBookmark, BOOKMARKS_KIND } from "../src/net/bookmarks.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const ID = "A".repeat(64), me = "b".repeat(64)

test("an entry: a note by its id, an addressable event by kind:pubkey:d", () => {
  assert.equal(entryFor({ id: ID, kind: 1, pubkey: me, tags: [] }), `e:${ID.toLowerCase()}`)
  assert.equal(entryFor({ id: "x", kind: 30023, pubkey: me.toUpperCase(), tags: [["d", "post-1"]] }), `a:30023:${me}:post-1`)
  assert.equal(BOOKMARKS_KIND, 10003)
})

test("toggling changes only that entry; unknown tags stay where they were; newest first, each once", () => {
  const tags = [["e", "1".repeat(64)], ["t", "keep"], ["a", "30023:x:y"], ["e", "1".repeat(64)]]
  assert.deepEqual(entries(tags), ["e:" + "1".repeat(64), "a:30023:x:y"])
  const on = toggled(tags, "e:" + "2".repeat(64), true)
  assert.deepEqual(on, [...tags, ["e", "2".repeat(64)]])
  assert.equal(toggled(on, "e:" + "2".repeat(64), true), on, "adding one already there changes nothing")
  assert.deepEqual(toggled(tags, "e:" + "1".repeat(64), false), [["t", "keep"], ["a", "30023:x:y"]], "every copy taken out")
})

test("a note bookmarked only privately offers nothing; public wins; the private part is a JSON array of tags", () => {
  const e = "e:" + "3".repeat(64)
  assert.equal(menuState([], new Set([e]), e), "privately")
  assert.equal(menuState([["e", "3".repeat(64)]], new Set([e]), e), "remove")
  assert.equal(menuState([], new Set(), e), "add")
  assert.deepEqual(privateEntries(JSON.stringify([["e", "3".repeat(64)], ["a", "30023:x:y"]])), ["a:30023:x:y", e])
  assert.deepEqual(privateEntries("not json"), [])
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Models/BookmarkList.swift", import.meta.url), "utf8")
  assert.ok(swift.includes("case add, remove, privately") && swift.includes("static let kind = 10003"))
})

test("a save starts from the newest list, keeps its other tags and its private content, and never signs over a newer one", async () => {
  const previous = { id: "p1", kind: 10003, pubkey: me, tags: [["t", "keep"]], content: "nip44-ciphertext", created_at: 10 }
  let signed = null
  const publish = async (ctx, kind, tags, opts) => {
    assert.equal(kind, 10003); assert.equal(opts.previous, previous)
    signed = { id: "p2", kind, tags, content: opts.previous.content }
    return { event: signed }
  }
  const ctx = { session: { pubkey: me, method: "readonly" }, signer: {} }
  const note = { id: "4".repeat(64), kind: 1, pubkey: "c".repeat(64), tags: [] }
  await setBookmark(ctx, note, true, { latest: async () => ({ event: previous, checked: true }), publish })
  assert.deepEqual(signed.tags, [["t", "keep"], ["e", "4".repeat(64)]])
  assert.equal(signed.content, "nip44-ciphertext", "the private part goes out as it was")
  assert.match(src("net/bookmarks.js"), /import \{ latestList, publishList \} from "\.\/list-edit\.js"/, "list-edit.js refuses to sign over a newer copy")
})

test("the note menu has Bookmark, and Vault › Bookmarks is a page with the iPhone's words", () => {
  assert.match(src("components/Moderation.jsx"), /\{note && <BookmarkMenuItem ctx=\{ctx\} note=\{note\} onDone=\{\(\) => setOpen\(false\)\} \/>\}/)
  const item = src("components/BookmarkMenuItem.jsx")
  for (const w of ["Remove Bookmark", "Bookmarked privately", '"Bookmark"']) assert.ok(item.includes(w), w)
  assert.match(item, /if \(ctx\.signer\?\.readOnly\) return null/)
  const page = src("screens/BookmarksScreen.jsx")
  assert.ok(page.includes("No bookmarks yet. Use Bookmark in a note's ••• menu to keep it here."))
  assert.ok(page.includes("Only you can see these. They are shown here as they are; change them in the app that made them."))
  assert.match(src("screens/VaultPagesMenu.jsx"), /BOOKMARKS_PAGE = \{ id: "bookmarks", title: "Bookmarks", href: "#\/bookmarks" \}/)
  const main = readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  assert.match(main, /\{route === "bookmarks" && <BookmarksScreen ctx=\{ctx\} \/>\}/)
  assert.match(src("desktop/DesktopShell.jsx"), /view\.route === "bookmarks" \? <BookmarksScreen ctx=\{ctx\} \/>/)
})

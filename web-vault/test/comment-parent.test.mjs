// A NIP-22 comment on a note shows the note it answers, on the web as on the iPhone (2026-11-26 Mostr thread: a Nostr
// Vault kind 1111 whose parent e-tag hint was the poster's ws://127.0.0.1 and whose only reachable hint sat on the
// root's uppercase E tag). The feed threads comments under their E root and asks the parent on reachable hints only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { threadRefs } from "../src/net/thread.js"
import { buildThreads } from "../src/net/feed-layout.js"
import { parentHintRelays } from "../src/net/parent-hints.js"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { NoteBody } = await import("../src/components/NoteCard.jsx")
const { ParentPreview } = await import("../src/components/ParentPreview.jsx")

const ROOT = "e07c55".padEnd(64, "0"), PARENT = "dc14c874".padEnd(64, "0"), REPLY = "0000ebdc".padEnd(64, "1")
const KAT = "a".repeat(64), ROOTPK = "b".repeat(64), ME = "c".repeat(64)
const reply = {
  id: REPLY, kind: 1111, pubkey: ME, created_at: 200, content: "All value is subjective",
  tags: [["E", ROOT, "wss://relay.ditto.pub", ROOTPK], ["K", "1"], ["P", ROOTPK],
    ["e", PARENT, "ws://127.0.0.1:3355", KAT], ["k", "1111"], ["p", KAT]],
}
const find = (node, type, out = []) => {
  if (Array.isArray(node)) { for (const n of node) find(n, type, out); return out }
  if (!node || typeof node !== "object") return out
  if (node.type === type) out.push(node)
  find(node.props?.children, type, out)
  return out
}

test("a note comment's root is its E tag and its parent its e tag; other comments and kinds are no note thread", () => {
  assert.deepEqual(threadRefs(reply), { root: ROOT, parent: PARENT })
  const top = { ...reply, tags: [["E", ROOT, "", ROOTPK], ["K", "1"], ["e", ROOT, "", ROOTPK], ["k", "1"]] }
  assert.deepEqual(threadRefs(top), { root: ROOT, parent: ROOT })
  assert.deepEqual(threadRefs({ ...reply, tags: reply.tags.map(t => t[0] === "K" ? ["K", "34235"] : t) }), { root: null, parent: null })
  assert.deepEqual(threadRefs({ ...reply, kind: 7 }), { root: null, parent: null })
})

test("threaded feed: the comment groups under its E root, which is what gets fetched", () => {
  const [t] = buildThreads([reply])
  assert.equal(t.rootId, ROOT)
  assert.equal(t.root, null)
  const kat = { id: PARENT, kind: 1111, pubkey: KAT, created_at: 150, content: "", tags: [["E", ROOT, "", ROOTPK], ["K", "1"], ["e", ROOT, "", ROOTPK], ["k", "1"]] }
  const root = { id: ROOT, kind: 1, pubkey: ROOTPK, created_at: 100, content: "AI didn't devalue artists", tags: [] }
  const [full] = buildThreads([reply], { resolve: id => ({ [ROOT]: root, [PARENT]: kat })[id] ?? null })
  assert.deepEqual(full.entries.map(e => [e.note.id, e.depth]), [[ROOT, 0], [PARENT, 1], [REPLY, 2]])
})

test("the parent preview asks reachable hints only: the parent's loopback hint is dropped, the root's ditto.pub kept", () => {
  assert.deepEqual(parentHintRelays(reply, PARENT), ["wss://relay.ditto.pub"])
  const good = { ...reply, tags: reply.tags.map(t => t[0] === "e" ? ["e", PARENT, "wss://relay.mostr.pub", KAT] : t) }
  assert.deepEqual(parentHintRelays(good, PARENT), ["wss://relay.mostr.pub", "wss://relay.ditto.pub"])
})

test("the card draws the comment's parent above it, on those hints", () => {
  const [pp] = find(NoteBody({ event: reply, showParent: true }), ParentPreview)
  assert.ok(pp, "parent preview drawn")
  assert.equal(pp.props.id, PARENT)
  assert.deepEqual(pp.props.relays, ["wss://relay.ditto.pub"])
  assert.equal(find(NoteBody({ event: reply }), ParentPreview).length, 0)
})

test("the expanded feed asks a comment's parent; the threaded feed keeps note comments", () => {
  const src = readFileSync(new URL("../src/components/FeedRows.jsx", import.meta.url), "utf8")
  assert.match(src, /showParent=\{!!threadRefs\(n\)\.parent/)
  assert.match(src, /isNoteComment\(n\)/)
})

// First-run "Already using Nostr Vault on another device?" (setup-bring-over.js, screens/SetupBringOver.jsx).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { LINK_LIMIT, OTHER_KIND, setupNotice, FALLBACK, QUESTION, RELAYS, BACKUP, COPY, COPY_DETAIL, linkedLine, setupOutcome, waitingSince, restoreSetupBackup } from "../src/net/setup-bring-over.js"

test("linked (or already linked) goes on to setup; abort, expiry and refusal fall back", () => {
  assert.equal(setupOutcome({ step: "linked" }, 10, 20), "linked")
  assert.equal(setupOutcome({ step: "already" }, 10, 20), "linked")
  for (const step of ["expired", "aborted", "refused", "failed"]) assert.equal(setupOutcome({ step }, 10, 20), "fallback", step)
})

test("3 minutes with no answer after the scan falls back; looking for a code has no limit", () => {
  assert.equal(setupOutcome({ step: "showBack" }, 1000, 1000 + LINK_LIMIT), "wait")
  assert.equal(setupOutcome({ step: "showBack" }, 1000, 1001 + LINK_LIMIT), "fallback")
  assert.equal(setupOutcome({ step: "scanning" }, null, 99_999), "wait")
  assert.equal(setupOutcome({ step: "confirm" }, 1000, 1000 + 10 * LINK_LIMIT), "wait", "never pulled from under the confirm")
})

test("the 3 minutes start when this browser scanned the other device or put its code up", () => {
  assert.equal(waitingSince({ step: "scanning" }, null, 5), null)
  assert.equal(waitingSince({ step: "showBack" }, null, 7), 7)
  assert.equal(waitingSince({ step: "showBack" }, 7, 50), 7)
  assert.equal(waitingSince({ step: "showing" }, null, 9), 9)
})

test("the words: the three choices, Logen's copy wording, and no other mesh, FIPS, address or role words", () => {
  assert.deepEqual([RELAYS, BACKUP, COPY], ["Import from relays", "Import from a backup", "Copy from my other vault"])
  assert.equal(COPY_DETAIL, "Your Mac or another device signed in as you. Scan two codes and it copies over the mesh.")
  for (const w of [QUESTION, RELAYS, BACKUP, COPY, FALLBACK, OTHER_KIND]) assert.ok(!/mesh|fips|address|role/i.test(w), w)
  assert.equal(FALLBACK, "Couldn't reach your other device; getting your notes from your relays instead.")
  assert.equal(linkedLine("Logen's iPhone"), "Linked with Logen's iPhone. Getting your notes now.")
  const screen = readFileSync(new URL("../src/screens/SetupBringOver.jsx", import.meta.url), "utf8")
  // The text people read: JSX text and string literals, not comments or identifiers.
  const shown = [...screen.matchAll(/>([^<>{}]+)</g), ...screen.matchAll(/`([^`]*)`|"([^"]*)"/g)].map(m => m[1] ?? m[2] ?? "")
    .filter(t => !/^\.{1,2}\//.test(t)).join(" ") // not import paths
  assert.ok(shown.includes("Scan your other device"), "positive control: the scan line is read")
  for (const word of [/\bmesh\b/i, /\bfips\b/i, /\baddress\b/i, /\brole\b/i]) assert.ok(!word.test(shown), String(word))
})

test("a refusal that names Mesh settings is said without it; others pass as they are", async () => {
  const { refusalText } = await import("../src/net/mesh-pairing.js")
  const other = refusalText("refuseOtherRole", { role: "phone" })
  assert.match(other, /Mesh settings/)
  assert.equal(setupNotice(other), OTHER_KIND)
  assert.ok(!/mesh|fips|address|role/i.test(OTHER_KIND))
  assert.equal(setupNotice(refusalText("otherOwner")), refusalText("otherOwner"))
  assert.equal(setupNotice(undefined), null)
})

test("a backup restores only this account's events, and says how many", async () => {
  const { generateSecretKey, getPublicKey, finalizeEvent } = await import("nostr-tools/pure")
  const sk = generateSecretKey(), me = getPublicKey(sk), other = generateSecretKey()
  const mine = [1, 2].map(i => finalizeEvent({ kind: 1, created_at: 1000 + i, tags: [], content: `n${i}` }, sk))
  const theirs = finalizeEvent({ kind: 1, created_at: 1000, tags: [], content: "x" }, other)
  const stored = []
  const vault = { outbox: { event: async ev => (stored.push(ev.id), { ok: true }) } }
  const lines = new TextEncoder().encode([...mine, theirs].map(e => JSON.stringify(e)).join("\n"))
  assert.equal(await restoreSetupBackup({ vault, pubkey: me, bytes: lines }), "Restored 2 events from your backup. Getting the rest from your relays.")
  assert.deepEqual(stored, mine.map(e => e.id))
  await assert.rejects(restoreSetupBackup({ vault, pubkey: me, bytes: new TextEncoder().encode(JSON.stringify(theirs)) }), /nothing of yours/)
  const zip = new Uint8Array([0x50, 0x4b, 3, 4, 0])
  assert.equal(await restoreSetupBackup({ vault, pubkey: me, bytes: zip, zipImport: async () => ({ counts: { outbox: { stored: 5 }, chat: 2 }, failed: [] }) }),
    "Restored 7 events from your backup. Getting the rest from your relays.")
  await assert.rejects(restoreSetupBackup({ vault, pubkey: me, bytes: zip, zipImport: async () => ({ counts: {}, failed: [] }) }), /no notes/)
})

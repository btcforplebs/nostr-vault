// First-run "Already using Nostr Vault on another device?" (setup-bring-over.js, screens/SetupBringOver.jsx).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { LINK_LIMIT, OTHER_KIND, setupNotice, FALLBACK, QUESTION, YES, NO, linkedLine, setupOutcome, waitingSince } from "../src/net/setup-bring-over.js"

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

test("the words: Logen's question, and no mesh, FIPS, address or role words on these screens", () => {
  assert.equal(QUESTION, "Already using Nostr Vault on another device?")
  assert.equal(YES, "Yes, bring it over")
  assert.equal(NO, "No, start fresh")
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

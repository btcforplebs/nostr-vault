// The Messages and conversation screens' words, as the iPhone's DMInboxView and DMThreadView: the inbox row's last
// line, the legacy NIP-04 banner, and a link that starts the message box (typed in, never sent).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { lastPreview, hasLegacy, dmPrefill } from "../src/net/dms.js"

const HEX = "a".repeat(64)

test("an empty message reads 'No message content'", () => {
  assert.equal(lastPreview(""), "No message content")
  assert.equal(lastPreview("  \n "), "No message content")
  assert.equal(lastPreview(undefined), "No message content")
})
test("the last line is the first 60 characters, then …", () => {
  assert.equal(lastPreview("hi\n  there"), "hi there")
  assert.equal(lastPreview("x".repeat(60)), "x".repeat(60))
  assert.equal(lastPreview("x".repeat(61)), "x".repeat(60) + "…")
  assert.equal(lastPreview("🙂".repeat(70)), "🙂".repeat(60) + "…") // characters, not UTF-16 halves
})
test("a conversation with a kind 4 in it is legacy", () => {
  assert.equal(hasLegacy([{ legacy: false }, { legacy: true }]), true)
  assert.equal(hasLegacy([{ legacy: false }]), false)
  assert.equal(hasLegacy([]), false)
})
test("?text= starts the box and comes off the address", () => {
  assert.deepEqual(dmPrefill(`#/dm/${HEX}?text=Is%20this%20still%20for%20sale%3F`), { text: "Is this still for sale?", hash: `#/dm/${HEX}` })
  assert.deepEqual(dmPrefill(`#/messages?dm=${HEX}&text=hi+there`), { text: "hi there", hash: `#/messages?dm=${HEX}` })
  assert.deepEqual(dmPrefill(`#/dm/${HEX}`), { text: "", hash: `#/dm/${HEX}` })
  assert.deepEqual(dmPrefill(`#/messages?dm=${HEX}`), { text: "", hash: `#/messages?dm=${HEX}` })
})
test("the prefilled text is only typed in: the send path is untouched by it", () => {
  const src = readFileSync(new URL("../src/screens/ConversationScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /useState\(\(\) => dmPrefill\(\)\.text\)/)
  // sendMessage is called only from the form's submit handler.
  assert.equal(src.match(/sendMessage\(/g).length, 1)
  assert.match(src, /const send = async e => \{\s*e\.preventDefault\(\)/)
})
test("the screens use the iPhone's words", () => {
  const inbox = readFileSync(new URL("../src/screens/MessagesScreen.jsx", import.meta.url), "utf8")
  const conv = readFileSync(new URL("../src/screens/ConversationScreen.jsx", import.meta.url), "utf8")
  assert.match(inbox, /No Messages Yet/)
  assert.match(inbox, /Start an encrypted conversation<br \/>with New message above/)
  assert.match(conv, />Start a conversation</)
  assert.match(conv, /Some messages use NIP-04 \(legacy encryption\)\. New messages default to NIP-17\./)
})

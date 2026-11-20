// The client tag the web app adds to what it posts matches the one the iPhone and Android apps add: same tag name,
// same "Nostr Vault on <platform>" value, same kinds (1 and 1111), never added twice, and no setting that drops it.
// Read from the apps' own sources, so a change there fails here.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { generateSecretKey, finalizeEvent, getPublicKey } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishNote } from "../src/net/sync.js"
import { publishAction, reactionTemplate, repostTemplate } from "../src/net/actions.js"
import { CLIENT_NAME, LINUX_CLIENT_NAME, LINUX_UA_MARK, appendClientTag, clientName } from "../src/net/client-tag.js"

const src = path => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8")
const IOS = src("HavenApp/HavenApp/Services/EventPublisher.swift")
const ANDROID = src("NostrVault/app/src/main/java/com/nostrvault/service/EventPublisher.kt")
const fn = (text, start) => text.slice(text.indexOf(start), text.indexOf("\n    }", text.indexOf(start)))

test("the value follows the apps' \"Nostr Vault on <platform>\" naming", () => {
  const ios = [...fn(IOS, "static func appendClientTag").matchAll(/"(Nostr Vault on [^"]+)"/g)].map(m => m[1])
  const android = [...fn(ANDROID, "fun appendClientTag").matchAll(/"(Nostr Vault on [^"]+)"/g)].map(m => m[1])
  assert.deepEqual(ios, ["Nostr Vault on iPadOS", "Nostr Vault on iOS", "Nostr Vault on MacOS"])
  assert.deepEqual(android, ["Nostr Vault on Android"])
  assert.equal(CLIENT_NAME, "Nostr Vault on Web")
  // Every app's tag is the two-item ["client", name], and the badge test (fromNostrVault) keys on the prefix.
  assert.match(fn(IOS, "static func appendClientTag"), /result\.append\(\["client", clientName\]\)/)
  assert.deepEqual(appendClientTag([], 1), [["client", CLIENT_NAME]])
})

test("the same kinds as the iPhone: notes and NIP-22 comments, nothing else, and never twice", () => {
  assert.match(fn(IOS, "static func appendClientTag"), /guard kind == 1 \|\| kind == NIP10Thread\.commentKind, !tags\.contains\(where: \{ \$0\.first == "client" \}\)/)
  assert.match(src("HavenApp/HavenApp/Models/NIP10Thread.swift"), /static let commentKind = 1111/)
  // No setting: the iPhone's function reads nothing but the kind, the tags and the device.
  assert.doesNotMatch(fn(IOS, "static func appendClientTag"), /UserDefaults|AppStorage|Settings/)
  for (const kind of [0, 3, 5, 6, 7, 16, 1018, 1311, 1984, 9734, 10002, 24242]) assert.deepEqual(appendClientTag([["p", "x"]], kind), [["p", "x"]], `kind ${kind}`)
  assert.deepEqual(appendClientTag([["e", "x"]], 1111), [["e", "x"], ["client", CLIENT_NAME]])
  const theirs = [["client", "Amethyst"]]
  assert.equal(appendClientTag(theirs, 1), theirs)
})

// Throwaway key, stubbed relays: nothing leaves the test.
function ctx(t) {
  const sk = generateSecretKey()
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.resolve("")))
  return {
    session: { pubkey: getPublicKey(sk) },
    signer: { signEvent: async tmpl => finalizeEvent(tmpl, sk) },
    account: { relays: { read: [], write: ["wss://relay.example.com"] } },
    vault: { outbox: { event: async () => ({ ok: true, message: "" }) } },
  }
}

test("a posted note is signed with the tag; a like or repost is not", async t => {
  const c = ctx(t)
  const { event } = await publishNote(c.vault, c.signer, c.session.pubkey, "hello", c.account.relays.write)
  assert.deepEqual(event.tags, [["client", "Nostr Vault on Web"]])
  const other = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "x" }, generateSecretKey())
  for (const tmpl of [reactionTemplate(other, "+"), repostTemplate(other)]) {
    const { event: ev } = await publishAction(c, tmpl)
    assert.ok(!ev.tags.some(tg => tg[0] === "client"), `kind ${ev.kind}`)
  }
  const { event: comment } = await publishAction(c, { kind: 1111, created_at: 1, tags: [["e", other.id]], content: "c" })
  assert.deepEqual(comment.tags, [["e", other.id], ["client", CLIENT_NAME]])
})

// The Linux desktop window: the same web app in WebKitGTK, with the window's word in the user agent.
const DESKTOP = src("linux/native/desktop/nostr-vault-desktop")
const WEBKITGTK = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
const FIREFOX = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

test("inside the Linux window a post says \"on Linux\"; a plain browser on Linux still says \"on Web\"", () => {
  assert.equal(LINUX_CLIENT_NAME, "Nostr Vault on Linux")
  // The window sets the word the web app looks for (one name, two files: this keeps them the same).
  assert.match(DESKTOP, new RegExp(`UA_MARK = "${LINUX_UA_MARK}"`))
  assert.match(DESKTOP, /set_user_agent_with_application_details\(UA_MARK, /)
  assert.equal(clientName(`${WEBKITGTK} ${LINUX_UA_MARK}/3.2.3`), LINUX_CLIENT_NAME)
  for (const ua of [WEBKITGTK, FIREFOX, `${WEBKITGTK} X${LINUX_UA_MARK}/1`, `${WEBKITGTK} ${LINUX_UA_MARK}`, "", undefined])
    assert.equal(clientName(ua ?? ""), CLIENT_NAME, String(ua))
  assert.deepEqual(appendClientTag([], 1, clientName(`${FIREFOX} ${LINUX_UA_MARK}/1`)), [["client", LINUX_CLIENT_NAME]])
})

test("the name is read from the page at each post, so a note signed in the window carries \"on Linux\"", async t => {
  const c = ctx(t)
  const real = Object.getOwnPropertyDescriptor(globalThis, "navigator")
  t.after(() => real ? Object.defineProperty(globalThis, "navigator", real) : delete globalThis.navigator)
  for (const [ua, want] of [[`${WEBKITGTK} ${LINUX_UA_MARK}/3.2.3`, LINUX_CLIENT_NAME], [FIREFOX, CLIENT_NAME]]) {
    Object.defineProperty(globalThis, "navigator", { value: { userAgent: ua }, configurable: true, writable: true })
    const { event } = await publishNote(c.vault, c.signer, c.session.pubkey, "hi", c.account.relays.write)
    assert.deepEqual(event.tags, [["client", want]], ua)
  }
})

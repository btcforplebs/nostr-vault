// Two-scan pairing (src/net/mesh-pairing.js, mesh-pairing-session.js) against the fixtures iOS and Android read too
// (HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing, made by reference.py).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createHash } from "node:crypto"
import * as P from "../src/net/mesh-pairing.js"
import { PairingSession, PairingJoiner } from "../src/net/mesh-pairing-session.js"
import { WORDS } from "../src/net/mesh-pairing-words.js"

const dir = new URL("../../HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing/", import.meta.url)
const fx = name => JSON.parse(readFileSync(new URL(name, dir), "utf8"))
const payload = fx("payload-cases.json"), hello = fx("hello-cases.json"), words = fx("checkwords-cases.json")

test("the rule's constants are the fixtures'", () => {
  assert.equal(payload.rule.name_max, P.NAME_MAX)
  assert.deepEqual(payload.rule.roles, P.ROLES)
  assert.equal(hello.rule.hello_kind, P.HELLO_KIND)
  assert.equal(hello.rule.code_lifetime, P.CODE_LIFETIME)
  assert.equal(hello.rule.scan_window, P.SCAN_WINDOW)
  assert.equal(hello.rule.ack_window, P.ACK_WINDOW)
  assert.equal(hello.rule.hello_skew, P.HELLO_SKEW)
  assert.ok(payload.parse.length > 30 && hello.cases.length > 30)
})

for (const c of payload.parse) {
  test(`parse: ${c.name}`, () => {
    const r = P.parse(c.uri, c.own)
    if (c.expect.refusal) return assert.equal(r.refusal, c.expect.refusal)
    const e = c.expect.payload
    assert.deepEqual(r.ok, { mesh: e.mesh, meshHex: e.mesh_hex, name: e.name, role: e.role, owner: e.owner, ownerHex: e.owner_hex,
      ...(e.secret != null ? { secret: e.secret } : { echo: e.echo }) })
  })
}

for (const c of payload.build) {
  test(`build: ${c.name}`, () => {
    const uri = P.build(c.args)
    assert.equal(uri, c.expect)
    assert.ok(P.parse(uri).ok)
  })
}

test("owner and role checks", () => {
  for (const c of payload.owner) assert.equal(P.ownerCheck(c.owner, c.active, c.accounts), c.expect, c.name)
  for (const c of payload.role) assert.equal(P.roleCheck(c.npub, c.role, c.existing), c.expect, c.name)
})

test("texts read as on the apps", () => {
  for (const c of payload.texts) {
    if (c.kind === "confirm") assert.equal(P.roleConfirmText(c.role, c.name, c.setup), c.expect)
    else if (c.kind === "short") assert.equal(P.shortAddress(c.npub), c.expect)
    else assert.equal(P.refusalText(c.code, { accountName: c.account_name ?? "", role: c.role ?? "" }), c.expect, c.code)
  }
})

test("hello and ack builders", () => {
  for (const b of hello.builders) {
    const got = b.kind === "ack" ? P.ackJson(b.args.d, b.args.w) : P.helloJson(b.args)
    assert.equal(got, b.expect)
  }
})

for (const c of hello.cases) {
  test(`session (${c.side}): ${c.name}`, async () => {
    if (c.side === "joiner") {
      const j = await PairingJoiner.start(P.parse(c.qr_a).ok, c.own_mesh, c.scanned_at)
      c.steps.forEach((st, i) => {
        const got = st.op === "words" ? j.confirmWords() : j.receiveAck(st.sender, st.content, st.now)
        assert.equal(got, st.expect, `step ${i}`)
      })
      return
    }
    const s = new PairingSession({ secret: c.secret, createdAt: c.created_at, ownMeshHex: c.own_mesh, active: c.active, accounts: c.accounts })
    c.steps.forEach((st, i) => {
      const got = st.op === "hello" ? s.receiveHello(st.sender, st.content, st.now)
        : st.op === "qr" ? s.acceptSecondQR(st.uri, st.now) : s.acceptWithoutScan(st.now)
      assert.equal(got, st.expect, `step ${i}`)
    })
  })
}

test("confirm carries the hello's device", () => {
  const c = hello.cases.find(x => x.name.startsWith("happy path"))
  const s = new PairingSession({ secret: c.secret, createdAt: c.created_at, ownMeshHex: c.own_mesh, active: c.active, accounts: c.accounts })
  s.receiveHello(c.steps[0].sender, c.steps[0].content, c.steps[0].now)
  assert.equal(s.acceptSecondQR(c.steps[1].uri, c.steps[1].now), "confirm")
  assert.equal(P.npubHex(s.device.npub), c.steps[0].sender)
  assert.deepEqual([s.device.name, s.device.role], ["Logen's iPhone", "phone"])
})

test("check words and ack digest", async () => {
  const file = readFileSync(new URL("words.txt", dir))
  assert.equal(createHash("sha256").update(file).digest("hex"), words.rule.list_sha256)
  assert.deepEqual(WORDS, file.toString("utf8").split("\n").filter(Boolean))
  assert.equal(WORDS.length, 2048)
  for (const c of words.cases) {
    assert.deepEqual(await P.checkWords(c.a, c.b, c.secret), c.words)
    assert.equal(await P.ackDigest(c.secret, c.a, c.b), c.ack_digest)
  }
})

test("a new secret is fresh and readable", () => {
  const a = P.newSecret()
  assert.notEqual(a, P.newSecret())
  assert.ok(P.secretBytes(a))
  assert.equal(a.length, 22)
})

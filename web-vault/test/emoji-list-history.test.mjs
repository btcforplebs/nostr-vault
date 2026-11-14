// The emoji list (kind 10030) keeps its old version in the vault's list history first, is stored in the vault before
// it goes to relays, and nothing is signed or sent when the vault didn't keep the old copy (Logen 2026-11-14,
// RESEARCH/NV_EMOJI_LIST_HISTORY_AUDIT.md). Twin of Apple ListVersionSaveTests and Android EmojiListSave.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishList, ListNotSaved } from "../src/net/list-edit.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const old = finalizeEvent({ kind: 10030, content: "", tags: [["a", `30030:${ME}:cats`]], created_at: 100 }, SK)
const newTags = [["a", `30030:${ME}:cats`], ["a", `30030:${ME}:dogs`]]

function fakeCtx({ outboxOk = ev => true, listsHold = true } = {}) {
  const log = [], history = []
  return {
    log,
    session: { pubkey: ME },
    account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"], listed: ["wss://r.example", "wss://w.example"] } },
    signer: { signEvent: async t => { log.push("sign"); return finalizeEvent(t, SK) } },
    vault: {
      outbox: {
        query: async () => [],
        event: async ev => {
          log.push(`vault ${ev.id === old.id ? "old" : "new"}`)
          if (!outboxOk(ev)) return { ok: false, message: "blocked: disk full" }
          if (listsHold) history.push(ev)
          return { ok: true }
        },
      },
      lists: { query: async ({ ids }) => history.filter(e => ids.includes(e.id)) },
    },
  }
}

const known = event => async () => ({ event, checked: true, asked: 2, answered: 2, noRelayList: false })

function relays(t, ctx) {
  t.mock.method(pool, "publish", urls => { ctx.log.push("relays"); return urls.map(() => Promise.resolve("ok")) })
}

test("10030: the old version goes into the vault's list history first, the new one into the vault before relays", async t => {
  const ctx = fakeCtx()
  relays(t, ctx)
  const { event } = await publishList(ctx, 10030, newTags, { previous: old, latest: known(old) })
  assert.deepEqual(ctx.log, ["vault old", "sign", "vault new", "relays"])
  assert.ok(event.created_at > old.created_at)
})

test("10030: nothing is signed or sent when the vault didn't keep the old copy", async t => {
  for (const ctx of [fakeCtx({ outboxOk: ev => ev.id !== old.id }), fakeCtx({ listsHold: false })]) {
    relays(t, ctx)
    const e = await publishList(ctx, 10030, newTags, { previous: old, latest: known(old) }).catch(x => x)
    assert.ok(e instanceof ListNotSaved, String(e))
    assert.match(e.message, /couldn't be kept first/)
    assert.deepEqual(ctx.log, ["vault old"])
  }
})

test("10030: nothing goes to relays when the vault refuses the new version", async t => {
  const ctx = fakeCtx({ outboxOk: ev => ev.id === old.id })
  relays(t, ctx)
  const e = await publishList(ctx, 10030, newTags, { previous: old, latest: known(old) }).catch(x => x)
  assert.match(String(e?.message), /vault refused/)
  assert.deepEqual(ctx.log, ["vault old", "sign", "vault new"])
})

test("10030 with no list yet has nothing to keep, and still goes to the vault before relays", async t => {
  const ctx = fakeCtx()
  relays(t, ctx)
  await publishList(ctx, 10030, newTags, { previous: undefined, latest: known(undefined) })
  assert.deepEqual(ctx.log, ["sign", "vault new", "relays"])
})

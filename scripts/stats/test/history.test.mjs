import { test } from "node:test"
import assert from "node:assert/strict"
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { historyLine, lastDate, appendHistory, rebuildLines, rebuildHistory } from "../history.mjs"

const stats = day => ({
  generated_at: `${day}T15:52:16.000Z`,
  posting_users: 113,
  by_platform: { Android: 48, iPhone: 30, iPad: 2, Mac: 1, Linux: 1, Web: 31 },
  active_7d: 73,
  active_30d: 104,
  github_downloads: 377,
  since: "2026-05-01",
  relays: 4,
  method: "Counted from public posts tagged Nostr Vault.",
})

test("a history line is the date and the five public totals, nothing else", () => {
  const line = historyLine(stats("2026-11-21"))
  assert.deepEqual(Object.keys(line), ["date", "posting_users", "by_platform", "active_7d", "active_30d", "github_downloads"])
  assert.equal(line.date, "2026-11-21")
  assert.equal(historyLine({ error: "x" }), null)
  assert.equal(historyLine(null), null)
})

test("appendHistory writes at most one line per day and never a key", async () => {
  const dir = await mkdtemp(join(tmpdir(), "nv-history-"))
  const s = join(dir, "stats.json")
  const h = join(dir, "stats-history.jsonl")
  try {
    await writeFile(s, JSON.stringify(stats("2026-11-21")))
    assert.equal(await appendHistory(s, h), "appended 2026-11-21")
    assert.match(await appendHistory(s, h), /^skipped: history already has 2026-11-21/)
    await writeFile(s, JSON.stringify(stats("2026-11-22")))
    assert.equal(await appendHistory(s, h), "appended 2026-11-22")
    await writeFile(s, JSON.stringify(stats("2026-11-20"))) // an older file never goes in after a newer day
    assert.match(await appendHistory(s, h), /^skipped/)
    const text = await readFile(h, "utf8")
    assert.equal(text.trim().split("\n").length, 2)
    assert.equal(lastDate(text), "2026-11-22")
    assert.doesNotMatch(text, /[0-9a-f]{64}|npub1|relays|method/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

const pkx = c => c.repeat(64).slice(0, 64)
const at = (date, h = 12) => Date.parse(`${date}T${String(h).padStart(2, "0")}:00:00Z`) / 1000

test("rebuildLines counts posters first seen by the end of each day, by main platform, with nulls it cannot know", () => {
  const posters = new Map([
    [pkx("1"), { first: at("2026-05-01", 23), last: at("2026-11-20"), notes: { Android: 3 } }],
    [pkx("2"), { first: at("2026-05-03", 0), last: at("2026-05-03"), notes: { Linux: 2, Web: 1 } }],
    [pkx("3"), { first: at("2026-05-03", 9), last: at("2026-06-01"), notes: { iPhone: 1 } }],
    ["3c93935d" + "0".repeat(56), { first: at("2026-05-01"), last: at("2026-05-01"), notes: { Web: 1 } }], // excluded account
  ])
  const lines = rebuildLines(posters, { since: "2026-05-01", until: "2026-05-04" })
  assert.deepEqual(lines.map(l => [l.date, l.posting_users]), [["2026-05-01", 1], ["2026-05-02", 1], ["2026-05-03", 3]])
  assert.deepEqual(lines[2].by_platform, { Android: 1, iPhone: 1, iPad: 0, Mac: 0, Linux: 1, Web: 0 })
  for (const l of lines) {
    assert.equal(l.reconstructed, true)
    assert.equal(l.active_7d, null)
    assert.equal(l.active_30d, null)
    assert.equal(l.github_downloads, null)
  }
  assert.doesNotMatch(JSON.stringify(lines), /[0-9a-f]{64}|3c93935d/)
})

test("rebuildHistory fills the days before the first scanned line, keeps scanned lines, and runs again cleanly", async () => {
  const dir = await mkdtemp(join(tmpdir(), "nv-history-"))
  const p = join(dir, "posters.json")
  const h = join(dir, "stats-history.jsonl")
  try {
    await writeFile(p, JSON.stringify({ [pkx("a")]: { first: at("2026-05-02"), last: at("2026-05-04"), notes: { Mac: 1 } } }))
    await writeFile(h, JSON.stringify({ date: "2026-05-04", posting_users: 1 }) + "\n")
    for (let i = 0; i < 2; i++) {
      await rebuildHistory(p, h)
      const lines = (await readFile(h, "utf8")).trim().split("\n").map(l => JSON.parse(l))
      assert.deepEqual(lines.map(l => [l.date, l.posting_users, l.reconstructed ?? false]),
        [["2026-05-01", 0, true], ["2026-05-02", 1, true], ["2026-05-03", 1, true], ["2026-05-04", 1, false]])
    }
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

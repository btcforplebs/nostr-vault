import { test } from "node:test"
import assert from "node:assert/strict"
import { historyPoints, chartPaths, CHART_PLATFORMS } from "../../../website/stats/chart.js"

const day = (date, by, extra = {}) => JSON.stringify({ date, posting_users: 0, by_platform: by, ...extra })
const rec = { reconstructed: true }

test("historyPoints stacks platforms in order, per day, and finds the first scanned day", () => {
  const text = [
    day("2026-05-02", { Android: 2, Web: 1 }, rec),
    "not json",
    day("2026-05-01", { Android: 1 }, rec),
    JSON.stringify({ posting_users: 9 }), // no date: skipped
    day("2026-05-03", { Android: 3, iPhone: 2, Linux: 1, Web: 1 }),
    "",
  ].join("\n")
  const p = historyPoints(text)
  assert.deepEqual(p.dates, ["2026-05-01", "2026-05-02", "2026-05-03"])
  assert.deepEqual(CHART_PLATFORMS, ["Android", "iPhone", "iPad", "Mac", "Linux", "Web"])
  assert.deepEqual(p.stacks.Android, [1, 2, 3])
  assert.deepEqual(p.stacks.iPhone, [1, 2, 5])
  assert.deepEqual(p.stacks.Linux, [1, 2, 6])
  assert.deepEqual(p.stacks.Web, [1, 3, 7])
  assert.equal(p.firstScanned, 2)
  assert.equal(p.max, 7)
})

test("historyPoints: a repeated day keeps its last line; under two days there is no chart", () => {
  const p = historyPoints([day("2026-05-01", { Mac: 1 }, rec), day("2026-05-02", { Mac: 1 }), day("2026-05-02", { Mac: 4 })].join("\n"))
  assert.deepEqual(p.stacks.Mac, [1, 4])
  assert.equal(historyPoints(day("2026-05-01", { Mac: 1 })), null)
  assert.equal(historyPoints(""), null)
  assert.equal(historyPoints(undefined), null)
})

test("historyPoints: every day reconstructed gives firstScanned -1; bad counts read as 0", () => {
  const p = historyPoints([day("2026-05-01", { Web: -3, Android: "x" }, rec), day("2026-05-02", { Web: 2 }, rec)].join("\n"))
  assert.equal(p.firstScanned, -1)
  assert.deepEqual(p.stacks.Web, [0, 2])
})

test("chartPaths splits each band at the first scanned day and maps values onto the box", () => {
  const p = historyPoints([day("2026-05-01", { Android: 0 }, rec), day("2026-05-02", { Android: 2 }, rec), day("2026-05-03", { Android: 4 })].join("\n"))
  const c = chartPaths(p, { w: 100, h: 40 })
  const android = c.bands.find(b => b.platform === "Android")
  assert.equal(android.reconstructed, "M0,40L50,20L50,40L0,40Z")
  assert.equal(android.scanned, "M50,20L100,0L100,40L50,40Z")
  assert.equal(c.topReconstructed, "M0,40L50,20")
  assert.equal(c.topScanned, "M50,20L100,0")
  assert.equal(c.scannedX, 50)
})

test("chartPaths: all reconstructed draws no solid part; all scanned draws no light part", () => {
  const two = extra => historyPoints([day("2026-05-01", { Web: 1 }, extra), day("2026-05-02", { Web: 2 }, extra)].join("\n"))
  const r = chartPaths(two(rec), { w: 10, h: 10 })
  assert.equal(r.topScanned, "")
  assert.equal(r.scannedX, null)
  assert.ok(r.bands.find(b => b.platform === "Web").reconstructed)
  const s = chartPaths(two({}), { w: 10, h: 10 })
  assert.equal(s.topReconstructed, "")
  assert.equal(s.scannedX, 0)
  assert.equal(s.bands.find(b => b.platform === "Web").reconstructed, "")
})

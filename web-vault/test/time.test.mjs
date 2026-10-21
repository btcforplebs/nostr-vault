// ago(ts) turns a unix timestamp into the short age shown on notes: 5s, 3m, 2h, 4d, then a date.
import test from "node:test"
import assert from "node:assert/strict"
import { ago } from "../src/components/time.js"

const NOW = 1_760_000_000 // a fixed unix time, so the boundaries are exact

test.beforeEach(t => t.mock.timers.enable({ apis: ["Date"], now: NOW * 1000 }))
test.afterEach(t => t.mock.timers.reset())

test("seconds under a minute", () => {
  assert.equal(ago(NOW), "0s")
  assert.equal(ago(NOW - 1), "1s")
  assert.equal(ago(NOW - 59), "59s")
})

test("minutes under an hour", () => {
  assert.equal(ago(NOW - 60), "1m")
  assert.equal(ago(NOW - 119), "1m")
  assert.equal(ago(NOW - 3599), "59m")
})

test("hours under a day", () => {
  assert.equal(ago(NOW - 3600), "1h")
  assert.equal(ago(NOW - 86399), "23h")
})

test("days under 30 days", () => {
  assert.equal(ago(NOW - 86400), "1d")
  assert.equal(ago(NOW - 29 * 86400), "29d")
  assert.equal(ago(NOW - 30 * 86400 + 1), "29d")
})

test("30 days or more shows the date", () => {
  const ts = NOW - 30 * 86400
  assert.equal(ago(ts), new Date(ts * 1000).toLocaleDateString())
  assert.equal(ago(0), new Date(0).toLocaleDateString())
})

test("a timestamp in the future shows 0s, not a negative age", () => {
  assert.equal(ago(NOW + 5), "0s")
  assert.equal(ago(NOW + 10 * 86400), "0s")
})

test("milliseconds of the current time are ignored", t => {
  t.mock.timers.setTime(NOW * 1000 + 999)
  assert.equal(ago(NOW - 1), "1s")
  assert.equal(ago(NOW - 60), "1m")
})

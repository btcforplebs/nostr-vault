// Wallet History against the iPhone: a zap counts only when it involves you (ZapHistoryService.fits), rows carry the
// person's picture, dates read "2 hours ago", and a reload asked for mid-load waits its turn.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { fits, ownZaps, whenText } = await import("../src/screens/WalletHistory.jsx")
const ME = "a".repeat(64), THEM = "b".repeat(64), OTHER = "c".repeat(64)

test("a received zap must be made out to you; a sent one made by you or anonymous", () => {
  assert.equal(fits({ sender: THEM, recipient: ME }, "incoming", ME), true)
  assert.equal(fits({ sender: THEM, recipient: OTHER }, "incoming", ME), false)
  assert.equal(fits({ sender: ME, recipient: THEM }, "outgoing", ME), true)
  assert.equal(fits({ sender: OTHER, recipient: THEM }, "outgoing", ME), false)
  assert.equal(fits({ sender: OTHER, recipient: THEM, anonymous: true }, "outgoing", ME), true)
  assert.equal(fits({ sender: THEM, recipient: ME }, "incoming", undefined), false, "no account, no zap")
})

test("a zap that isn't yours shows as a plain payment, its request's text dropped", () => {
  const txs = [
    { id: "1", direction: "incoming", zap: { sender: THEM, recipient: ME, comment: "hi" }, description: null },
    { id: "2", direction: "incoming", zap: { sender: THEM, recipient: OTHER, comment: "refund me at evil.example" }, description: null },
    { id: "3", direction: "outgoing", zap: null, description: "coffee" },
  ]
  const out = ownZaps(txs, ME)
  assert.ok(out[0].zap)
  assert.equal(out[1].zap, null)
  assert.equal(out[1].description, null)
  assert.equal(out[2].description, "coffee")
})

test("dates read like the iPhone's: minutes, hours, yesterday, days, weeks", () => {
  const now = 1_800_000_000
  assert.equal(whenText(now - 300, now, "en"), "5 minutes ago")
  assert.equal(whenText(now - 7200, now, "en"), "2 hours ago")
  assert.equal(whenText(now - 86400, now, "en"), "yesterday")
  assert.equal(whenText(now - 3 * 86400, now, "en"), "3 days ago")
  assert.equal(whenText(now - 14 * 86400, now, "en"), "2 weeks ago")
  assert.equal(whenText(now - 5, now, "en"), "5 seconds ago")
})

test("rows: the person's avatar with ⚡ for a zap; one load at a time; Receive's address follows the profile", () => {
  const src = readFileSync(new URL("../src/screens/WalletHistory.jsx", import.meta.url), "utf8")
  assert.match(src, /\{person\s*\? <span class="wallet-tx-icon zap"[^>]*>\s*<Avatar pubkey=\{person\}/)
  assert.match(src, /if \(running\.current\) \{ if \(reset\) pending\.current = true; return \}/)
  assert.match(src, /if \(pending\.current\) \{ pending\.current = false; load\(true\) \}/)
  assert.match(src, /ownZaps\(txs, me\)\.map/)
  const recv = readFileSync(new URL("../src/screens/WalletReceive.jsx", import.meta.url), "utf8")
  assert.match(recv, /useProfile\(pubkey\)\?\.lud16/)
  assert.equal(/getProfile\(/.test(recv), false)
})

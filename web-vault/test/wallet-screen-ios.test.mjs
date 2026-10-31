// The wallet screen as on the iPhone (WalletLightningTab): the balance is the hero, and the cards come in its order.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")

test("the balance is the hero: LIGHTNING BALANCE, large sats, a spinner while it reads and -- when it can't", () => {
  const s = src("screens/WalletScreen.jsx")
  assert.match(s, />LIGHTNING BALANCE</)
  assert.match(s, /busy \? <Spinner label="Reading the balance" \/>/)
  assert.match(s, /class="wallet-sats-big">\{Math\.floor\(balance \/ 1000\)\.toLocaleString\(\)\}/)
  assert.match(s, /!busy && <p class="wallet-balance"><span class="wallet-sats-big muted">--<\/span>/)
  assert.match(src("styles/wallet.css"), /\.wallet-sats-big \{ font: 700 28px/)
})

test("the cards come Balance, Receive (headed by the lightning address), Send, History, then the linked wallet", () => {
  const s = src("screens/WalletScreen.jsx")
  const order = ["<Connected ", "<WalletReceive ", "<WalletSend ", "<WalletHistory ", "<Linked "].map(t => s.indexOf(t))
  assert.ok(order.every(i => i > 0), "every card is there")
  assert.deepEqual([...order].sort((a, b) => a - b), order)
})

test("with no wallet linked the screen says so first, and the link form opens from Connect a wallet", () => {
  const s = src("screens/WalletScreen.jsx")
  assert.match(s, /if \(!open\) return \(/)
  assert.match(s, /<h3>No Wallet Connected<\/h3>/)
  assert.match(s, /Link a wallet you already use to send and receive zaps\./)
  assert.match(s, /onClick=\{\(\) => setOpen\(true\)\}>Connect a wallet<\/button>/)
})

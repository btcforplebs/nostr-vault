// Receive (NIP-47 make_invoice), as on the iPhone (WalletLightningTab receiveCard): the amount in millisats and the
// optional description go to the wallet, and only an invoice for exactly that amount is shown, as a QR code.
// A fake wallet with throwaway keys answers in place of a relay: nothing leaves the machine.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip04 from "nostr-tools/nip04"
import { bytesToHex } from "nostr-tools/utils"
import { makeInvoice } from "../src/net/wallet.js"
import { invoiceMsat } from "../src/net/zaps.js"

const walletSk = generateSecretKey(), appSk = generateSecretKey()
const conn = { walletPubkey: getPublicKey(walletSk), relay: "wss://relay.wallet.example", secret: bytesToHex(appSk) }

/** A wallet that answers make_invoice with `invoice`, recording what it was asked. */
function fakeWallet(invoice) {
  const asked = []
  const relay = {
    subscribe(_filters, sub) { relay.sub = sub; queueMicrotask(() => sub.oneose()); return { close() {} } },
    async publish(req) {
      asked.push(JSON.parse(nip04.decrypt(walletSk, req.pubkey, req.content)))
      queueMicrotask(() => relay.sub.onevent(finalizeEvent({
        kind: 23195, created_at: Math.floor(Date.now() / 1000), tags: [["p", req.pubkey], ["e", req.id]],
        content: nip04.encrypt(walletSk, req.pubkey, JSON.stringify({ result_type: "make_invoice", result: { invoice } })),
      }, walletSk)))
      return ""
    },
    close() {},
  }
  return { asked, connect: async () => relay }
}

test("an invoice is asked for in millisats, with the description only when there is one", async () => {
  const w = fakeWallet("lnbc210n1receive")
  assert.equal(await makeInvoice(conn, { sats: 21, description: "  coffee " }, { connect: w.connect, amountOf: invoiceMsat }), "lnbc210n1receive")
  assert.equal(await makeInvoice(conn, { sats: 21, description: "   " }, { connect: w.connect, amountOf: invoiceMsat }), "lnbc210n1receive")
  assert.deepEqual(w.asked, [
    { method: "make_invoice", params: { amount: 21_000, description: "coffee" } },
    { method: "make_invoice", params: { amount: 21_000 } },
  ])
})

test("an invoice for another amount, or no invoice, is not shown; a bad amount asks nothing", async () => {
  await assert.rejects(makeInvoice(conn, { sats: 21 }, { connect: fakeWallet("lnbc1000n1other").connect, amountOf: invoiceMsat }), /different amount/)
  await assert.rejects(makeInvoice(conn, { sats: 21 }, { connect: fakeWallet("").connect, amountOf: invoiceMsat }), /didn't send back an invoice/)
  const w = fakeWallet("lnbc210n1x")
  for (const sats of [0, -5, 1.5, 10_000_001, NaN]) await assert.rejects(makeInvoice(conn, { sats }, { connect: w.connect }), /1 to 10,000,000/)
  assert.equal(w.asked.length, 0)
})

test("the Receive card loads, and its QR code is drawn from the invoice's modules", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  const { WalletReceive, QrCode } = await import("../src/screens/WalletReceive.jsx")
  assert.equal(typeof WalletReceive, "function")
  const svg = QrCode({ text: "LNBC210N1RECEIVE", label: "QR" })
  const [, , n] = svg.props.viewBox.split(" ").map(Number)
  assert.ok(n >= 21, "at least a version 1 code")
  const path = svg.props.children.props.d
  assert.match(path, /^(M\d+ \d+h1v1h-1z)+$/)
  // A different invoice draws a different code.
  assert.notEqual(QrCode({ text: "LNBC100N1OTHER", label: "QR" }).props.children.props.d, path)
})

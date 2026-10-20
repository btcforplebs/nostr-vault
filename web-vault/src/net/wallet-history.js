// The wallet's payment history over Nostr Wallet Connect (NIP-47 list_transactions), as the iPhone reads it
// (NWCService.listTransactions, WalletTransaction, ZapDetail). Reading history spends nothing.
import { verifyEvent } from "nostr-tools/pure"
import { walletRequest, WalletError } from "./wallet.js"

const HEX64 = /^[0-9a-f]{64}$/
/** The iPhone's page (WalletLightningTab.historyPageSize). */
export const HISTORY_PAGE = 20

/** A wallet that doesn't share history, or a connection not allowed to read it (NWCService.WalletError.isUnsupported). */
export const isUnsupported = e => e instanceof WalletError && ["NOT_IMPLEMENTED", "RESTRICTED", "UNAUTHORIZED"].includes(e.code)

// Wallets are loose about number types: int, float or numeric string.
const num = v => {
  const n = typeof v === "string" ? Number(v) : v
  return typeof n === "number" && Number.isFinite(n) ? Math.trunc(n) : null
}
const firstTag = (tags, name) => tags.find(t => Array.isArray(t) && t[0] === name && t[1])?.[1] ?? null

/**
 * A zap request (kind 9734) handed back as an invoice's description -> { sender, recipient, noteId, comment,
 * anonymous }, or null for a plain description. Its fields are whatever its author wrote: only a valid signature
 * makes the sender who it says, so an unsigned or forged one is no zap.
 */
export function zapDetailOf(description) {
  const s = (description ?? "").trim()
  if (!s.startsWith("{")) return null
  let req
  try { req = JSON.parse(s) } catch { return null }
  if (req?.kind !== 9734 || !HEX64.test(req.pubkey ?? "") || !Array.isArray(req.tags)) return null
  const { id, pubkey, created_at, kind, content, sig } = req
  try { if (!verifyEvent({ id, pubkey, created_at, kind, tags: req.tags, content, sig })) return null } catch { return null }
  const recipient = firstTag(req.tags, "p"), noteId = firstTag(req.tags, "e")
  return {
    sender: pubkey, recipient: HEX64.test(recipient ?? "") ? recipient : null, noteId: HEX64.test(noteId ?? "") ? noteId : null,
    comment: typeof content === "string" && content.trim() ? content.trim() : null,
    anonymous: req.tags.some(t => t?.[0] === "anon"),
  }
}

/** The person on the other side: the zap's sender for money in (none when anonymous), its recipient for money out. */
export const counterparty = (tx) => !tx.zap ? null : tx.direction === "incoming" ? (tx.zap.anonymous ? null : tx.zap.sender) : tx.zap.recipient

/**
 * One NIP-47 transaction -> { id, direction, state, sats, feeSats, description, created_at, settled_at, zap }, or
 * null when it has no direction or no time. `state` is newer in NIP-47; older wallets only send `settled_at`.
 */
export function parseTransaction(t) {
  if (!t || typeof t !== "object") return null
  const direction = String(t.type ?? "").toLowerCase()
  if (direction !== "incoming" && direction !== "outgoing") return null
  const created_at = num(t.created_at)
  if (created_at == null) return null
  const settled_at = num(t.settled_at)
  const desc = typeof t.description === "string" ? t.description.trim() : ""
  const zap = zapDetailOf(desc)
  const state = ["settled", "pending", "failed", "expired"].includes(String(t.state ?? "").toLowerCase())
    ? String(t.state).toLowerCase() : settled_at != null ? "settled" : "pending"
  const sats = Math.trunc((num(t.amount) ?? 0) / 1000)
  const hash = typeof t.payment_hash === "string" && t.payment_hash ? t.payment_hash.toLowerCase() : null
  const invoice = typeof t.invoice === "string" && t.invoice ? t.invoice : null
  return {
    id: hash ?? invoice ?? `${direction}-${created_at}-${sats}`, direction, state, sats,
    feeSats: Math.trunc((num(t.fees_paid) ?? 0) / 1000), description: desc && !zap ? desc : null,
    created_at, settled_at, zap,
  }
}

/** Pages merged newest first, a payment on two pages (the list moved between requests) shown once. */
export function mergeTransactions(existing, page) {
  const seen = new Set()
  return [...existing, ...page].filter(t => !seen.has(t.id) && seen.add(t.id)).sort((a, b) => b.created_at - a.created_at)
}

/** One page of history, newest first. Throws a WalletError that isUnsupported tells apart. */
export async function listTransactions(conn, { limit = HISTORY_PAGE, offset = 0 } = {}, { request = walletRequest, ...opts } = {}) {
  const { transactions } = await request(conn, "list_transactions", { limit, offset, unpaid: false }, opts)
  return mergeTransactions([], (Array.isArray(transactions) ? transactions : []).map(parseTransaction).filter(Boolean))
}

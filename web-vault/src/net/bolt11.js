// A bolt11 invoice's amount, on its own so wallet.js can read it too (zaps.js imports wallet.js, so wallet.js can't
// import zaps.js). zaps.js re-exports it under the old name.

/** The exact millisats an invoice asks for, or null for an amountless or unreadable one (Bolt11.msat). */
export function invoiceMsat(invoice) {
  const s = (invoice ?? "").trim().toLowerCase()
  const sep = s.lastIndexOf("1")
  const m = /^ln(?:bcrt|bc|tbs|tb)(\d+)([munp]?)$/.exec(s.slice(0, sep))
  if (!m) return null
  const v = BigInt(m[1])
  const msat = { "": v * 100_000_000_000n, m: v * 100_000_000n, u: v * 100_000n, n: v * 100n, p: v % 10n ? -1n : v / 10n }[m[2]]
  return msat > 0n && msat < 21_000_000n * 100_000_000_000n ? Number(msat) : null
}

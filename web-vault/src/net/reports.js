// Reporting a note or a person (NIP-56, kind 1984), as the iPhone's Report & Block does it (UGCReportingDialog,
// NostrService+Moderation): the same reasons, the report sent to the user's write relays, then the person blocked
// (net/blocks.js setBlock), so what was reported stops showing.
import { pool, publishRelays } from "./pool.js"
import { checkSigned } from "./sync.js"
import { getBlocks, setBlock } from "./blocks.js"

const HEX64 = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)

/** The iPhone's reasons, in its order. `type` is the NIP-56 report type a reader understands; NIP-56 has no
 *  "violence", so that one goes out as "other" and keeps its name in the `reason` tag and the text. */
export const REASONS = [
  { id: "spam", label: "Spam", type: "spam" },
  { id: "nudity", label: "Nudity / Sexual Content", type: "nudity" },
  { id: "violence", label: "Violence / Harm", type: "other" },
  { id: "illegal", label: "Illegal Content", type: "illegal" },
  { id: "impersonation", label: "Impersonation", type: "impersonation" },
  { id: "other", label: "Other", type: "other" },
]

/**
 * A kind 1984 for a note (`note`: its event) or a person (`pubkey`). NIP-56: the person in a `p` tag, a reported note
 * in an `e` tag, the report type on the tag naming what's reported; plus the iPhone's `reason` tag.
 */
export function reportTemplate({ note, pubkey, reason, details = "", at = now() }) {
  const r = REASONS.find(x => x.id === reason)
  if (!r) throw new Error("Pick a reason.")
  const who = note?.pubkey ?? pubkey
  if (!HEX64.test(who ?? "")) throw new Error("There's no one to report.")
  if (note && !HEX64.test(note.id ?? "")) throw new Error("That note can't be reported.")
  const tags = note ? [["e", note.id, r.type], ["p", who]] : [["p", who, r.type]]
  tags.push(["reason", r.id])
  const text = String(details).trim()
  return { kind: 1984, created_at: at, tags, content: text || `Reported ${note ? "" : "user "}for ${r.label}` }
}

/**
 * Report, then block the person. The report must reach a relay first; the block is its own step, so a block that
 * fails still leaves the report sent, and says so. ctx: { vault, signer, session, account }.
 * -> { report: event, blocked: true, alreadyBlocked } or { report, blocked: false, blockError }
 */
export async function reportAndBlock(ctx, { note, pubkey, reason, details }, { publish = (urls, ev) => pool.publish(urls, ev), block = setBlock } = {}) {
  const template = reportTemplate({ note, pubkey, reason, details })
  const who = note?.pubkey ?? pubkey
  if (who === ctx.session.pubkey) throw new Error("You can't report yourself.")
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const { network } = publishRelays(ctx.account.relays.write)
  const results = await Promise.allSettled(publish(network, event))
  if (!results.some(r => r.status === "fulfilled")) throw new Error(`The report didn't go out: no relay took it (0 of ${network.length}). Try again.`)
  try {
    if (getBlocks().blocked.has(who)) return { report: event, blocked: true, alreadyBlocked: true }
    await block(ctx, who, { block: true })
    return { report: event, blocked: true, alreadyBlocked: false }
  } catch (e) {
    return { report: event, blocked: false, blockError: String(e?.message ?? e) }
  }
}

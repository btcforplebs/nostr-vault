// Saving a merged list (Settings › Recover a List): the safe-save rules every list edit follows (#1566, list-edit.js
// publishList) plus the Lazarus spec's Recover rules. Only on the user's Save tap, never by itself. Right before
// signing the list is read again; it refuses when the newest copy isn't known or isn't the one the merge was built
// on, keeps the version being replaced in the vault's history first, signs as the list's author, and dates the new
// version after the one it replaces.
import { pool, publishRelays, uniq, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { MAX_SKEW } from "./follows.js"
import { latestList, ListNotSaved, NO_RELAY_LIST } from "./list-edit.js"
import { keepSnapshot, snapshotStore } from "./follow-backup.js"
import { mergeKind, hasPrivate } from "./list-version-merge.js"

const now = () => Math.floor(Date.now() / 1000)
/** The most NIP-44 v2 encrypts in one message. Merge always writes NIP-44, also over a NIP-04 list (Logen 2026-11-03). */
export const NIP44_MAX = 65535
/** Only the NIP-01 fields: a version found by list-versions.js carries `from`, and Haven refuses an envelope with
 *  fields it doesn't know (it never answers that EVENT). */
const nip01 = ({ id, pubkey, created_at, kind, tags, content, sig }) => ({ id, pubkey, created_at, kind, tags, content, sig })

/** The version being replaced, in the vault's /lists history (it went in through the outbox, list_history.go), and
 *  for kind 3 in Following Backup too. -> "" when kept, else why not. */
export async function keepUndoCopy(ctx, version, { store } = {}) {
  if (!version) return ""
  const base = nip01(version)
  const me = ctx.session.pubkey
  try {
    const r = await ctx.vault.outbox.event(base)
    if (!r?.ok && !/^duplicate:/.test(r?.message ?? "")) return r?.message || "your vault didn't take it"
    if (!ctx.vault.lists) return "this browser's vault keeps no list history"
    const kept = await ctx.vault.lists.query({ ids: [base.id], kinds: [base.kind], authors: [me] })
    if (!kept.some(e => e.id === base.id)) return "your vault's list history doesn't hold it"
    if (base.kind === 3) {
      const s = store ?? snapshotStore(me)
      await keepSnapshot(s, base, me)
      if (!(await s.all()).some(e => e.id === base.id)) return "Following Backup didn't keep it"
    }
    return ""
  } catch (e) { return String(e?.message ?? e) }
}

/**
 * Sign the merged list and send it out. `base`: the current version the merge was built on (null: there was none).
 * `tags`: the public tags (mergedTags), `privateTags` the entries kept private, encrypted to the user with NIP-44.
 * `baseOpened`: the base's private part was read, so `privateTags` can hold all of it; without it a base with a private
 * part is refused (the new event replaces that part, and entries never read would be wiped). `latest`, `publish` and
 * `store` are for tests.
 * -> { event, relays: [{ url, ok, message }], took } ; throws ListNotSaved or Error, and then nothing was signed.
 */
export async function saveMerged(ctx, kind, { base, baseOpened = false, tags, privateTags = [], latest = latestList, publish = (urls, ev) => pool.publish(urls, ev), store } = {}) {
  const me = ctx.session.pubkey
  if (!mergeKind(kind)) throw new Error("Not saved: this list can't be merged here.")
  if (!tags.filter(t => !["d", "title", "name", "description", "image", "alt", "client"].includes(t[0])).length && !privateTags.length)
    throw new Error("Not saved: the merged list would be empty.")
  if (hasPrivate(base) && !baseOpened) throw new Error("Not saved: the private part of the list you have now couldn't be opened, so saving would wipe it. Nothing was changed.")
  const fresh = await latest(ctx, kind)
  if (!fresh.checked && fresh.noRelayList) throw new ListNotSaved(`Not saved. ${NO_RELAY_LIST} Nothing was changed.`, fresh.event, false)
  if (!fresh.checked) throw new ListNotSaved("Not saved: not enough of your relays answered, so your newest list couldn't be read. Nothing was changed. Try again when more of them are reachable.", fresh.event, false)
  if ((fresh.event?.id ?? null) !== (base?.id ?? null))
    throw new ListNotSaved("Not saved: this list changed since you looked (another app or device saved it). It's reloaded; check the merge again.", fresh.event, true)
  const undo = await keepUndoCopy(ctx, base, { store })
  if (undo) throw new Error(`Not saved: the list you have now couldn't be kept first (${undo}), so nothing was changed.`)
  let content = ""
  if (kind === 3) content = base?.content ?? ""
  else if (privateTags.length) {
    if (!ctx.signer.crypto?.encrypt) throw new Error("Not saved: this sign-in can't encrypt your private entries.")
    // NIP-44 seals at most 65,535 bytes; say so rather than pass on the signer's bare error.
    if (new TextEncoder().encode(JSON.stringify(privateTags)).length > NIP44_MAX)
      throw new Error("Not saved: the private entries are too many for one encrypted list (NIP-44 holds 64 KB). Untick some in Review. Nothing was changed.")
    content = await ctx.signer.crypto.encrypt(me, JSON.stringify(privateTags))
  }
  const created_at = Math.max(now(), (base?.created_at ?? 0) + 1)
  if (created_at >= now() + MAX_SKEW) throw new Error("Not saved: the list you have now is dated in the future, so a new version can't be dated after it.")
  // The account the merge was for, still: a switch during a signer prompt must not save it as another account's.
  if (ctx.session.pubkey !== me) throw new Error("Not saved: the account changed.")
  const template = { kind, created_at, tags, content }
  const event = checkSigned(await ctx.signer.signEvent(template), template, me)
  const { network } = publishRelays(ctx.account.relays.write)
  const urls = uniq([...network, ...PROFILE_RELAYS])
  const results = await Promise.allSettled(publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) }))
  // Judged on the user's write relays (Lazarus): the profile index alone taking it isn't a save.
  const took = relays.filter(r => r.ok && network.includes(r.url)).length
  if (!took) throw new Error(`No relay of yours took it (0 of ${network.length}), so nothing changed.`)
  const stored = await ctx.vault.outbox.event(event)
  if (!stored?.ok && !/^duplicate:/.test(stored?.message ?? "")) throw new Error(`Sent to ${took} of your relays, but your vault refused it: ${stored?.message}`)
  if (kind === 3) await keepSnapshot(store ?? snapshotStore(me), event, me).catch(() => {})
  return { event, relays, took, of: network.length }
}

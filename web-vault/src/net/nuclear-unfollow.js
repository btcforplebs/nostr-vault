// Nuclear unfollow (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md, Logen 2026-11-19): someone unwanted (X) reaches your web,
// your notifications and your globe because people you follow follow them. This cuts X and every one of your follows
// who follows X, in ONE new follow list. The steps, in order, each a wall for the next:
//   1. the newest kind 3 on your relays is the base (findLatestList, the rules every follow edit uses), never a stale
//      local copy, and the base itself must pass wipeGuard (not a shrunken or one-relay copy);
//   2. that base is saved in this browser's Following Backup (follow-backup.js) and read back: no backup, no publish;
//   3. one kind 3: the base minus the checked people (and X), every other tag and the content exactly as they were.
// Undo republishes the backup (restoreList). No mute step (Logen: "we are cutting them and the people that follow them").
import { findLatestList, followsOf, wipeGuard, publishFollowList } from "./follows.js"
import { keepFollowChange, keepSnapshot, restoreList, snapshotStore } from "./follow-backup.js"

const HEX = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)
/** From this many people a second warning follows the first (Logen: "double warn at 25+"). */
export const DOUBLE_WARN_AT = 25

/** Your follows who follow `target`, from their follow lists (`lists`: Map pubkey -> kind 3, net/wot.js followLists),
 *  in your list's order. Never you or `target` itself. */
export function followersOfAmong(target, follows, lists, me) {
  return follows.filter(pk => pk !== target && pk !== me && followsOf(lists.get(pk)).includes(target))
}

/** Who goes: the people on the list as it is now (`shown`) whose box is ticked. `checked` holds ticks from when the list
 *  was first drawn; the list can shrink after (a refreshed follow list no longer follows X, Rebuild, a reload), and a
 *  tick for someone no longer shown must never unfollow them (Tron, #2284). Someone new on the list starts unticked. */
export const pickedOf = (shown, checked) => (shown ?? []).filter(pk => !!checked?.has(pk))

/** The warnings before publishing: always one, and a second from DOUBLE_WARN_AT people. */
export const warningsFor = n => (n >= DOUBLE_WARN_AT ? 2 : 1)

/** `base`'s tags with these people's `p` tags gone. Every other tag (other follows, relays, petnames, anything else)
 *  stays as it was, in its order. */
export function cutTags(base, remove) {
  return (base?.tags ?? []).filter(t => !(t[0] === "p" && remove.has(t[1])))
}

/**
 * Publish the cut. `remove`: the people to unfollow (the checked follows, and `target`). `onBackup` is called once the
 * base is saved and read back, before anything is signed (the screen's "Backup saved ✓").
 * -> { event, base, removed: [pubkey] actually in the base, taken, settled }
 */
export async function nuclearUnfollow({ ctx, target, remove, onBackup = () => {}, store = snapshotStore(ctx.session.pubkey), ask, publish }) {
  const me = ctx.session.pubkey, { account } = ctx
  if (!HEX.test(target ?? "") || target === me) throw new Error("That isn't someone you can unfollow.")
  const cut = new Set([...remove].filter(pk => HEX.test(pk) && pk !== me))
  if (!cut.size) throw new Error("Nobody is checked, so nothing was changed.")
  const { base, seen, asked, answered, heard, netFound, ahead } = await findLatestList({ vault: ctx.vault, pubkey: me, relays: account.relays.listed ?? [], known: account.contacts, ask })
  // The base must be one every other follow edit would build on: checked unchanged, so a shrunken, stale or one-relay
  // copy refuses here. The cut itself is the user's (checked and confirmed), so it isn't held to the size rule.
  const refused = wipeGuard({ base, tags: base?.tags ?? [], target, follow: false, seen, appCount: account.follows.length, asked, answered, heard, netFound, ahead })
  if (refused) throw new Error(refused)
  if (!base) throw new Error("Your follow list wasn't found on your relays, so nothing was changed. Try again when they answer.")
  const before = followsOf(base)
  const removed = before.filter(pk => cut.has(pk))
  if (!removed.length) throw new Error("None of them are in your newest follow list, so nothing was changed.")
  const tags = cutTags(base, cut)
  if (!followsOf({ tags }).length) throw new Error("This would leave you following nobody, so nothing was published. Uncheck someone to keep.")
  // The backup first, read back from the store: if it isn't there, nothing is signed.
  try {
    await keepSnapshot(store, base, me)
    if (!(await store.all()).some(s => s.id === base.id)) throw new Error("it isn't in the backup after saving")
  } catch (e) {
    throw new Error(`Your follow list couldn't be backed up in this browser (${e?.message ?? e}), so nothing was published.`)
  }
  onBackup(base)
  const template = { kind: 3, created_at: Math.max(now(), base.created_at + 1), tags, content: base.content ?? "" }
  const { event, taken, settled } = await publishFollowList({ vault: ctx.vault, signer: ctx.signer, pubkey: me, template, writeRelays: account.relays.write, publish })
  keepFollowChange(me, base, event, store).catch(() => {})
  return { event, base, removed, taken, settled }
}

/** Undo: the backup back as your follow list, only if the list is still the one the cut published. */
export const undoNuclear = ({ ctx, base, event, store = snapshotStore(ctx.session.pubkey), ask }) =>
  restoreList({ ctx, old: base, shown: event, store, ask })

// Names asked for one card at a time (an @name, "reply to @name", a quote's author) go out together: each is queued
// for BATCH_MS and the queue is one fetchProfiles, one REQ per relay for up to 200 names, where every card used to
// send its own (profile perf review 2026-11-27, finding 3: 198-276 REQs on one tap of Replies). As net/zaps.js
// wantTotals batches zap ids.
import { fetchProfiles, getProfile } from "./profiles.js"

export const BATCH_MS = 50
const queues = new Map() // save (true: written to Haven /feed) -> Set(pubkey)
let timer = null

/**
 * Asks for `pubkey`'s kind 0 with the others asked within BATCH_MS. `source()` -> { vault, relays } or null (the
 * vault isn't registered yet: nothing is asked). `save`: false for a stranger's card (memoryOnly). A name already
 * held isn't queued.
 */
export function wantProfile(pubkey, source, { save = true, delayMs = BATCH_MS, fetch = fetchProfiles } = {}) {
  if (!pubkey || getProfile(pubkey)) return
  if (!queues.has(save)) queues.set(save, new Set())
  queues.get(save).add(pubkey)
  timer ??= setTimeout(() => {
    timer = null
    const src = source()
    const batch = [...queues]
    queues.clear()
    if (!src) return
    // A name asked to be saved and also not saved is saved: some card on screen is a follow's.
    const saved = new Set(batch.filter(([s]) => s).flatMap(([, pks]) => [...pks]))
    const memory = batch.filter(([s]) => !s).flatMap(([, pks]) => [...pks]).filter(pk => !saved.has(pk))
    if (saved.size) fetch(src.vault, [...saved], src.relays, { save: true }).catch(() => {})
    if (memory.length) fetch(src.vault, memory, src.relays, { save: false }).catch(() => {})
  }, delayMs)
  timer?.unref?.()
}

// How many app frames the side columns run at once (plan §2: each is a walled-off page with its own service worker,
// so they cost). Pure counting, no DOM, so tests load it.
import { MAX_FRAMES } from "./columns.js"

const live = new Set()
const waiting = new Set()

/** A frame slot for card `id`, or null when MAX_FRAMES already run. -> release(), safe to call twice. */
export function claimFrame(id, max = MAX_FRAMES) {
  if (!live.has(id) && live.size >= max) return null
  live.add(id)
  let done = false
  return () => {
    if (done) return
    done = true
    live.delete(id)
    for (const f of [...waiting]) f()
  }
}

/** Call `f` once a slot frees up. -> stop(). */
export function whenFree(f) {
  const once = () => { waiting.delete(once); f() }
  waiting.add(once)
  return () => waiting.delete(once)
}

export const framesLive = () => live.size

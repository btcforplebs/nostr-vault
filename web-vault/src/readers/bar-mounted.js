// Whether the app-wide player bar (FloatingPlayer) is mounted. Minimize hands a video's sound to the bar, so where no
// bar is drawn (a guest's post or profile, GuestApp.jsx) it would start sound nobody could stop: Minimize hides there.
let mounted = 0
const listeners = new Set()

export const barMounted = () => mounted > 0

/** FloatingPlayer: call on mount; returns the unmount. */
export function mountBar() {
  mounted++
  for (const f of listeners) f(true)
  return () => { mounted--; for (const f of listeners) f(mounted > 0) }
}

/** Calls `f(isMounted)` when it changes; returns the unsubscribe. */
export function onBarMounted(f) {
  listeners.add(f)
  return () => listeners.delete(f)
}

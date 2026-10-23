// A feed's loaded results for this session, so switching feeds and back shows them at once (memory only). Kept per
// scope and per follow list: Global is filtered by your web, so after an unfollow the old results still named the
// people only that follow brought in, and the screen skipped the reload because something was held.
export function heldResults() {
  const map = new Map()
  const key = (scope, follows) => `${scope}|${[...follows].sort().join(",")}`
  return {
    get: (scope, follows) => map.get(key(scope, follows)),
    has: (scope, follows) => map.has(key(scope, follows)),
    set: (scope, follows, value) => { map.set(key(scope, follows), value) },
  }
}

// The follow list as an effect dependency: a swap that keeps the count still reloads.
export const followsDep = follows => [...follows].sort().join(",")

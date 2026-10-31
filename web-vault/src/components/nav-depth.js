// How many of this app's own pages sit behind the current one, so a screen can tell whether going back stays in the
// app: Compose opened straight at #/compose (a shared link, a bookmark) has none, and history.back() would leave the
// app or do nothing. Each history entry carries its depth in history.state.nvDepth: the first page is 0, a new hash
// adds one, and Back/Forward land on an entry that already knows its own.

const depthOf = win => win.history.state?.nvDepth
const mark = (win, depth) => win.history.replaceState({ ...(win.history.state ?? {}), nvDepth: depth }, "")

export function startNavDepth(win = window) {
  let last = depthOf(win) ?? 0
  if (depthOf(win) == null) mark(win, 0)
  const onHash = () => {
    const known = depthOf(win)
    if (known == null) mark(win, ++last)
    else last = known
  }
  win.addEventListener("hashchange", onHash)
  return () => win.removeEventListener("hashchange", onHash)
}

/** True when history.back() goes to another of this app's pages. */
export const canGoBack = (win = globalThis) => (win.history?.state?.nvDepth ?? 0) > 0

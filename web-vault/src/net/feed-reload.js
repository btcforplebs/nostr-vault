// Settings › Feed › Reload Feed (iPhone FeedSettingsView's Troubleshooting button): opens the Feed and has it sync from
// its relays again, even when a sync just ran. The ask is kept until the Feed takes it, so it works whether the Feed
// is already mounted (it hears nv:feed-refresh) or mounts after the hash change (it checks on mount).
let asked = false

export function askFeedReload({ go = h => { globalThis.location.hash = h }, dispatch = e => globalThis.dispatchEvent?.(e) } = {}) {
  asked = true
  go("#/feed")
  dispatch(new Event("nv:feed-refresh"))
}

/** True once after askFeedReload, for the Feed to sync. */
export function takeFeedReload() {
  const was = asked
  asked = false
  return was
}

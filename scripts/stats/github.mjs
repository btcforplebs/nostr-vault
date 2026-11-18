// The GitHub release download total: every asset's download_count on every release, from the public API (no token).

export const RELEASES_URL = "https://api.github.com/repos/btcforplebs/nostr-vault/releases"

/** Sums download_count over a page of releases. Throws on anything that is not a list of releases. */
export function sumDownloads(releases) {
  if (!Array.isArray(releases)) throw new Error("GitHub answered with something that is not a list of releases")
  let total = 0
  for (const r of releases) for (const a of r?.assets ?? []) total += Number.isFinite(a?.download_count) ? a.download_count : 0
  return total
}

/** The total over every page. `fetchFn` is fetch (tests pass a fake). Throws on an HTTP error, never returns a part. */
export async function downloadTotal(fetchFn = fetch, url = RELEASES_URL) {
  let total = 0
  for (let page = 1; page <= 50; page++) {
    const res = await fetchFn(`${url}?per_page=100&page=${page}`, { headers: { accept: "application/vnd.github+json", "user-agent": "nostrvault-stats" } })
    if (!res.ok) throw new Error(`GitHub releases page ${page}: HTTP ${res.status}`)
    const releases = await res.json()
    total += sumDownloads(releases)
    if (releases.length < 100) return total
  }
  throw new Error("GitHub releases: more than 50 pages")
}

// nostrvault.app/stats: reads /stats/stats.json (written once a day by scripts/stats/run.mjs) and fills in the totals.
// The page shows totals only; the file holds nothing else. view() is pure and tested by scripts/stats/test/page.test.mjs.

export const PLATFORM_ORDER = ["Android", "iPhone", "iPad", "Mac", "Linux", "Web"]

const fmt = n => (Number.isFinite(n) ? n.toLocaleString("en-US") : "–")

/** What the page shows for a stats file: the four totals as text, the platform rows, and the "updated" line. null for a bad file. */
export function view(stats) {
  if (!stats || typeof stats !== "object" || !Number.isFinite(stats.posting_users)) return null
  const platforms = PLATFORM_ORDER.filter(p => Number.isFinite(stats.by_platform?.[p]) && stats.by_platform[p] > 0)
    .map(p => [p, fmt(stats.by_platform[p])])
  const day = typeof stats.generated_at === "string" ? stats.generated_at.slice(0, 10) : null
  return {
    values: {
      posting_users: fmt(stats.posting_users),
      active_7d: fmt(stats.active_7d),
      active_30d: fmt(stats.active_30d),
      github_downloads: fmt(stats.github_downloads),
    },
    platforms,
    updated: day ? `Last counted ${day} (UTC), from posts since ${stats.since ?? "May 2026"}.` : "",
  }
}

async function load() {
  const status = document.getElementById("stats-status")
  let v = null
  try {
    const res = await fetch("/stats/stats.json", { cache: "no-cache" })
    if (res.ok) v = view(await res.json())
  } catch {}
  if (!v) {
    status.textContent = "The numbers haven't been counted yet. Check back tomorrow."
    return
  }
  status.hidden = true
  for (const [key, text] of Object.entries(v.values)) {
    const el = document.querySelector(`[data-stat="${key}"]`)
    if (el) el.textContent = text
  }
  document.getElementById("stats-grid").hidden = false
  const list = document.getElementById("platform-list")
  for (const [name, count] of v.platforms) {
    const li = document.createElement("li")
    const a = document.createElement("span")
    const b = document.createElement("span")
    a.textContent = name
    b.textContent = count
    li.append(a, b)
    list.append(li)
  }
  document.getElementById("stats-platforms").hidden = v.platforms.length === 0
  document.getElementById("stats-updated").textContent = v.updated
}

if (typeof document !== "undefined") load()

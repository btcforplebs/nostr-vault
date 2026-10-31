// The dashboard's Relay activity (iPhone RelayActivityViews): the app's log (main.jsx log(), kept in localStorage
// "nv-log") read as plain lines, each good, heads-up or a problem, and the health of the newest ones.
// Copies and reports leave out keys, ids, IP addresses and file paths.

const T = {
  boot: l => ["good", `Your vault started in ${(Number(l.loadMs) || 0) + (Number(l.startMs) || 0)} ms`],
  "signed-in": () => ["good", "Signed in"],
  account: l => ["good", `Read your account: ${Number(l.follows) || 0} follows`],
  persist: l => (l.granted ? ["good", "This browser will keep your vault"] : ["headsUp", "This browser may clear your vault when it needs room"]),
  block: () => ["good", "Blocked someone"],
  unblock: () => ["good", "Unblocked someone"],
  "boot-error": l => ["problem", `Your vault didn't start: ${l.err ?? "unknown error"}`],
  "sw-error": () => ["headsUp", "This browser couldn't keep an offline copy of the app"],
  "first-event-error": () => ["headsUp", "A first event of your new account wasn't saved"],
  "account-store-refused": () => ["headsUp", "Your vault refused part of your account"],
  "blocks-store-refused": () => ["headsUp", "Your vault refused your block list"],
  "blocks-load-failed": () => ["headsUp", "Your block list couldn't be read"],
}

/** Log lines -> [{ at (ms), level: "good" | "headsUp" | "problem", text }], oldest first. Unknown types are skipped. */
export function activityItems(lines = []) {
  const out = []
  for (const l of lines) {
    const f = T[l?.type]
    if (!f) continue
    const [level, text] = f(l)
    out.push({ at: Date.parse(l.t) || 0, level, text: redact(text) })
  }
  return out
}

/** The pill: a problem among the last 10 items, else a heads-up, else OK (RelayActivityModel.health). */
export function health(items) {
  const recent = items.slice(-10)
  if (recent.some(i => i.level === "problem")) return "problem"
  if (recent.some(i => i.level === "headsUp")) return "headsUp"
  return "good"
}

export const HEALTH = {
  good: { pill: "OK", banner: "Everything looks fine" },
  headsUp: { pill: "Heads-up", banner: "Working, with a few hiccups" },
  problem: { pill: "Problem", banner: "Something needs your attention" },
}

/** The banner's second line: "Your vault is running normally." or the newest item that isn't good. */
export const bannerDetail = items => [...items].reverse().find(i => i.level !== "good")?.text ?? "Your vault is running normally."

/** Keys, ids, IP addresses and file paths out of a line (RelayActivityModel's redaction). */
export function redact(s) {
  return String(s)
    .replace(/\b(nsec|npub|nprofile|note|nevent|naddr|ncryptsec)1[02-9ac-hj-np-z]{20,}\b/gi, "[key]")
    .replace(/\b[0-9a-f]{64}\b/gi, "[id]")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "[ip]")
    .replace(/\[?[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){3,7}\]?/gi, "[ip]")
    .replace(/(?:\/[\w.-]+){2,}/g, "[path]")
}

/** The report Copy and Export hand out. */
export function report(items, { now = new Date(), version = "" } = {}) {
  const h = health(items)
  return [`Nostr Vault (web) relay report${version ? ` · ${version}` : ""}`, `${now.toISOString()}`, `Health: ${HEALTH[h].pill}`, "",
    ...items.map(i => `${new Date(i.at).toISOString()}  ${HEALTH[i.level].pill.padEnd(8)}  ${i.text}`)].join("\n") + "\n"
}

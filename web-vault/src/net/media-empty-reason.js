// Why Vault › Media shows no files, in plain words. A read-only sign-in saw "0 files" with no reason (Ted's web sweep
// 2026-11-01, item 6): most media servers list files only for a signed request (BUD-02 "list" auth), and a read-only
// sign-in has no signer, so they refused and the grid was simply empty.

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/**
 * `servers` asked, `status` each one's answer from listBlobs ("ok" or a reason), `readOnly` whether the sign-in can
 * sign. -> the sentence to show under "No media found", or "" when every server answered with an empty list.
 */
export function emptyMediaReason({ servers = [], status = {}, readOnly = false }) {
  const missed = servers.filter(s => status[s] !== "ok")
  if (!missed.length) return ""
  const who = missed.length === servers.length
    ? servers.length === 1 ? hostOf(servers[0]) : `None of your ${servers.length} media servers`
    : `${missed.length} of your ${servers.length} media servers`
  const verb = who.startsWith("None") ? "listed" : "didn't list"
  if (readOnly) return `${who} ${verb} your files. Most media servers only list files for a signed request, and a read-only sign-in can't sign. Sign in with an extension or a bunker to see them.`
  return `${who} ${verb} your files (${missed.map(s => `${hostOf(s)}: ${status[s] ?? "no answer"}`).join("; ")}).`
}

// NAP-DM `people` (our query extension, dm-dispatch.js): the Messages napplet's New message box finds people by name,
// as the classic box does (MessagesScreen.jsx + MentionPicker): follows whose loaded name or NIP-05 matches first, then
// for 2+ characters a NIP-50 search for people you don't follow. Blocked people are never offered (B2, B3).
// Its own file so node tests drive it with fakes; the shell (shell-deps.js) hands in the real search.

export const MAX_PEOPLE = 8

/** -> hex pubkeys, best first. deps: { follows: [pk], blocked: Set, rank(query, pks, follows, blocked) -> [pk],
 *  search(query) -> Promise<[kind 0 event]>, put(event) (keep the profile so its name shows) } */
export async function findPeople(query, { follows, blocked, rank, search, put }) {
  const q = String(query ?? "").trim()
  if (!q) return []
  let found = []
  if (q.length >= 2) {
    try { const people = await search(q); for (const e of people) put(e); found = people.map(e => e.pubkey) } catch {}
  }
  return rank(q, [...follows, ...found], follows, blocked).slice(0, MAX_PEOPLE)
}

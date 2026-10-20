// The hashtags a note's text carries, as NIP-24 `t` tags: a port of the iPhone's NoteTagging.hashtags / hashtagTags
// (HavenApp/Models/NoteTagging.swift), so a note posted here is found by every hashtag feed, ours and other clients'.
// Rules, in the order they bite: a URL or nostr:/ws: token gives nothing (https://host/page#section is a fragment);
// # must not follow a letter, digit or _ (C#, a#b); the run needs a letter (#1 is "number 1"); at most 64 characters;
// lower-cased, duplicates collapse, first spelling keeps its place.
const HASHTAG = /(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+)/gu
const REFERENCE = /^(https?:\/\/|wss?:\/\/|nostr:)/i
const MAX_LENGTH = 64

export function hashtags(text) {
  const found = [], seen = new Set()
  for (const token of String(text ?? "").split(/\s+/)) {
    if (!token || REFERENCE.test(token)) continue
    for (const m of token.matchAll(HASHTAG)) {
      const tag = m[1].toLowerCase()
      if (!/\p{L}/u.test(tag) || [...tag].length > MAX_LENGTH || seen.has(tag)) continue
      seen.add(tag); found.push(tag)
    }
  }
  return found
}

export const hashtagTags = text => hashtags(text).map(t => ["t", t])

/** The text split for drawing: even items plain text, odd items a `#tag` run (with its #) that is a hashtag by the
 *  rules above. A run inside a URL or nostr: token is never split out (NoteText takes those first). */
export function splitHashtags(text) {
  const parts = []
  let at = 0
  for (const m of String(text).matchAll(HASHTAG)) {
    const tag = m[1]
    if (!/\p{L}/u.test(tag) || [...tag].length > MAX_LENGTH) continue
    parts.push(text.slice(at, m.index), m[0])
    at = m.index + m[0].length
  }
  parts.push(text.slice(at))
  return parts
}

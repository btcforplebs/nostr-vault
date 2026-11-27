// Muted words (Settings › Muted Words): `word` entries in the user's kind 10000 (NIP-51), the list blocks.js already
// reads, so a word muted here hides on every screen that hides muted words, and a word muted in another app shows
// here. A new word goes in the encrypted private part unless the user asks for it to be public (Logen 11-27: a public
// list of muted words says what upsets you). Adding or removing a word changes only that word: every other entry,
// public or private (people, other words, hashtags, threads), is kept, through the same guarded path blocking uses
// (blocks.js publishMuteList: the newest list from a majority of the user's relays, the size guard).
import { editedEntry, publishMuteList } from "./blocks.js"

/** The longest word or phrase that can be muted, in characters. */
export const MUTED_WORD_MAX = 100

/** A muted word as it is stored: NFC, lowercased, trimmed, inner spaces folded to one. "" when there is nothing. */
export const mutedWordKey = s => String(s ?? "").normalize("NFC").toLowerCase().trim().replace(/\s+/g, " ")

/** Why `s` can't be muted, or "". `have` holds the words already muted, as any app saved them, for the duplicate check. */
export function mutedWordProblem(s, have = []) {
  const w = mutedWordKey(s)
  if (!w) return "Type a word or phrase."
  if ([...w].length > MUTED_WORD_MAX) return `That's longer than ${MUTED_WORD_MAX} characters.`
  if (!/[\p{L}\p{N}]/u.test(w)) return "That has no letters or numbers to match."
  if (have.some(h => mutedWordKey(h) === w)) return "That word is already muted." // another app may have saved "Foo  Bar"
  return ""
}

/** editedEntry for a word: mute (`mute`) or unmute `word`, matched in any case and spacing. -> { tags, content } */
export function editedWordList(base, { word, mute, isPrivate = true, crypto, me }) {
  const value = mutedWordKey(word)
  if (!value) throw new Error("Type a word or phrase.")
  return editedEntry(base, { name: "word", value, same: v => mutedWordKey(v) === value, add: mute, isPrivate, crypto, me,
    refuse: { addPrivate: "Couldn't mute it privately", remove: "Couldn't unmute it" } })
}

/**
 * Mute or unmute `word` and publish the list (blocks.js publishMuteList). Private by default. Throws, publishing
 * nothing, when the word is empty or too long, the guard refuses, or the private part is needed and can't be opened.
 * ctx: { vault, signer, session, account }. `ask` and `publish` are for tests. -> { event, relays }
 */
export async function setMutedWord(ctx, word, { mute = true, isPrivate = true, ask, publish } = {}) {
  if (mute) {
    const problem = mutedWordProblem(word)
    if (problem) throw new Error(problem)
  }
  if (isPrivate && mute && !ctx.signer?.crypto) throw new Error("Couldn't mute it privately: your signer can't encrypt.")
  return publishMuteList(ctx, base => editedWordList(base, { word, mute, isPrivate, crypto: ctx.signer.crypto, me: ctx.session.pubkey }), { ask, publish })
}

/** Settings › Muted Words' two sections: the public part's words, then those only in the private part. A word in both
 *  shows once, under Public, since anyone can see it. */
export function mutedWordSections({ publicWords, privateWords } = {}) {
  const pub = [...(publicWords ?? [])]
  const seen = new Set(pub)
  return { publicWords: pub, privateWords: [...(privateWords ?? [])].filter(w => !seen.has(w)) }
}

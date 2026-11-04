// The wallet connection (NWC link) kept on the user's own Nostr account, so Nostr Vault on another device, or Wisp,
// signed in with the same key can use it. Twin of the iPhone's NWCBackup.swift + NWCBackupService.swift and Android's
// NwcBackup.kt + NwcBackupService.kt, in Wisp's format so the apps read each other's: one NIP-78 app-data event,
// kind 30078, d = "nwc-wallet-backup", content = the raw nostr+walletconnect:// string NIP-44 encrypted to the
// account's own key. Wisp marks nothing as removed; an empty content (and our `deleted` tag) means it was taken off.
//
// The link spends the wallet's money. It is only ever published as NIP-44 ciphertext (isCiphertext is checked right
// before signing), never logged, and no error here carries it. Every save and removal is locked to the account the
// screen showed: if the signed-in account changes at any step, nothing is published.
import { verifyEvent } from "nostr-tools/pure"
import { publishAction } from "./actions.js"
import { askRelay } from "./follows.js"
import { DEFAULT_RELAYS, uniq } from "./pool.js"

export const BACKUP_KIND = 30078
export const BACKUP_D = "nwc-wallet-backup"
const SCHEME = "nostr+walletconnect://"

/** Tags of a saved wallet (the content goes in already encrypted). */
export const SAVED_TAGS = [["d", BACKUP_D], ["client", "Nostr Vault"], ["encryption", "nip44"]]
/** Tags of the event that takes the saved wallet off (empty content). */
export const CLEARED_TAGS = [["d", BACKUP_D], ["deleted", "true"]]

/** Whether an event is the account's saved-wallet slot. */
export const isBackup = ev => ev?.kind === BACKUP_KIND && (ev.tags ?? []).some(t => t.length >= 2 && t[0] === "d" && t[1] === BACKUP_D)

/** Whether the slot holds no wallet: empty content, or marked deleted. */
export const isCleared = (content, tags = []) =>
  !String(content ?? "").trim() || tags.some(t => t.length >= 2 && t[0] === "deleted" && t[1] === "true")

/** The wallet string in a decrypted slot, or null when it isn't one. Wisp's decryptNwcBackup rule: trimmed, and it
 *  must start with nostr+walletconnect:// in any case. */
export function walletString(plaintext) {
  const s = String(plaintext ?? "").trim()
  return s.toLowerCase().startsWith(SCHEME) ? s : null
}

/** What goes into the encrypted content: trimmed, as Wisp writes it; null for anything that isn't a wallet string. */
export const plaintextForSaving = uri => walletString(uri)

/** True only for something that may be published: never the wallet string itself, never empty. */
export const isCiphertext = content => !!String(content ?? "").trim() && !String(content).toLowerCase().includes("walletconnect")

/**
 * What the account's slot holds, as far as this browser can tell (NWCBackup.Status). Only "empty" says nothing is
 * saved; a slot that exists but wasn't (or couldn't be) read is its own state, so the screen never says "not saved"
 * while the secret may still be on the relays.
 *   { state: "unknown" }                    no relay answered
 *   { state: "empty" }                      a relay answered without one, or it was removed
 *   { state: "saved", uri, savedAt }        read
 *   { state: "needsSigner", savedAt }       saved; reading it needs the signer, asked only on a tap
 *   { state: "unreadable", savedAt }        saved, but this browser can't read it
 * `slot`: the newest slot found (or null); `answeredAny`: a relay sent its EOSE; `read`: { tried: false } |
 * { failed: true } | { plaintext }.
 */
export function backupStatus({ slot, answeredAny, read }) {
  if (!slot) return { state: answeredAny ? "empty" : "unknown" }
  if (isCleared(slot.content, slot.tags)) return { state: "empty" }
  const savedAt = slot.created_at
  if (!read || read.tried === false) return { state: "needsSigner", savedAt }
  if (read.failed) return { state: "unreadable", savedAt }
  const uri = walletString(read.plaintext)
  return uri ? { state: "saved", uri, savedAt } : { state: "unreadable", savedAt }
}

/** Whether a slot with a wallet in it exists, readable or not. */
export const hasSlot = s => s.state === "saved" || s.state === "needsSigner" || s.state === "unreadable"

/**
 * Whether "Remove from my account" is offered: whenever a wallet may be on the account (a slot, or no answer to say
 * otherwise), except when the save switch is already on, which removes it by itself. `same(uri)`: whether a saved
 * link is the wallet in use; `connected`: a wallet is in use.
 */
export function offersRemove(s, { connected, same }) {
  if (s.state === "unknown" || s.state === "needsSigner" || s.state === "unreadable") return true
  if (s.state === "saved") return !connected || !same(s.uri)
  return false
}

/** The status's words for a log or a test: the link never appears. */
export const describeStatus = s => (s.state === "saved" ? `saved(<redacted>, ${s.savedAt})` : s.savedAt ? `${s.state}(${s.savedAt})` : s.state)

/** The newest slot among `events` by `pubkey` (ties: the lower id), its signature checked on a fresh copy. */
export function newestSlot(events, pubkey) {
  let best = null
  for (const ev of events) {
    if (!isBackup(ev) || ev.pubkey !== pubkey || !verifiedCopy(ev)) continue
    if (!best || ev.created_at > best.created_at || (ev.created_at === best.created_at && ev.id < best.id)) best = ev
  }
  return best
}
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => {
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}

/** The signers that must not be asked on their own: a bunker sees the text it decrypts, and an extension may pop a
 *  prompt (Android's Amber without a standing grant). A key kept in this browser decrypts silently. */
export const asksOnTap = session => session?.method === "nip46" || session?.method === "nip07"

/** Messages for what went wrong. None carries the link. */
export const BACKUP_ERRORS = {
  readOnly: "This sign-in can't encrypt. Sign in with your key, an extension or a bunker to save the wallet to your account.",
  notAWallet: "That isn't a nostr+walletconnect:// link.",
  encryptFailed: "Couldn't encrypt the wallet. Nothing was saved.",
  accountChanged: "The account changed. Nothing was published; check again.",
}

/** The account the screen shows, held for one save or removal: its ctx, and whether it is still the one signed in.
 *  main.jsx builds a new ctx object on every render, so "still signed in" is the same pubkey with the same signer
 *  (a switch, a sign-out or a new sign-in brings another signer). */
export function lockAccount(ctx, current) {
  const pubkey = ctx?.session?.pubkey, signer = ctx?.signer
  return { pubkey, ctx, held: () => { const now = current(); return !!pubkey && now?.session?.pubkey === pubkey && now?.signer === signer } }
}

/**
 * What `pubkey`'s slot holds. `askSigner` false: a bunker or an extension isn't asked to decrypt (opening the wallet
 * screen must not send the secret to the signer), so a slot shows as needsSigner until the user taps.
 * `current()`: the app's ctx now (actions.js actionContext); a switch while this ran answers "unknown".
 * `ask`: follows.js askRelay, for tests.
 */
export async function readBackup(ctx, { askSigner = false, current, ask = askRelay } = {}) {
  const pubkey = ctx?.session?.pubkey
  if (!pubkey) return { state: "unknown" }
  const lock = lockAccount(ctx, current)
  const relays = uniq([...(ctx.account?.relays?.read ?? []), ...(ctx.account?.relays?.write ?? []), ...DEFAULT_RELAYS])
  const filter = { kinds: [BACKUP_KIND], authors: [pubkey], "#d": [BACKUP_D] }
  const replies = await Promise.all(relays.map(url => ask(url, filter).catch(() => ({ events: [], answered: false }))))
  if (!lock.held()) return { state: "unknown" }
  const answeredAny = replies.some(r => r.answered)
  const slot = newestSlot(replies.flatMap(r => r.events), pubkey)
  if (!slot || isCleared(slot.content, slot.tags)) return backupStatus({ slot, answeredAny })
  const crypto = ctx.signer?.crypto
  if (ctx.signer?.readOnly || !crypto?.decrypt) return backupStatus({ slot, answeredAny, read: { failed: true } })
  if (asksOnTap(ctx.session) && !askSigner) return backupStatus({ slot, answeredAny, read: { tried: false } })
  let read
  try { read = { plaintext: await crypto.decrypt(pubkey, slot.content) } } catch { read = { failed: true } }
  if (!lock.held()) return { state: "unknown" }
  return backupStatus({ slot, answeredAny, read })
}

/** A short error that never carries the link: `e` is only kept when it is one of ours. */
const fail = key => { const e = new Error(BACKUP_ERRORS[key]); e.code = key; return e }

/**
 * Publish `uri` as `lock`'s slot, NIP-44 encrypted to the account's own key. Refuses (nothing published) if the
 * account isn't `lock`'s at any step, if the link isn't one, or if what came back from encrypting isn't ciphertext.
 * `publish`: actions.js publishAction, for tests.
 */
export async function saveBackup(lock, uri, { publish = publishAction } = {}) {
  const plaintext = plaintextForSaving(uri)
  if (!plaintext) throw fail("notAWallet")
  if (!lock.held()) throw fail("accountChanged")
  const { ctx, pubkey } = lock
  if (ctx.signer?.readOnly || !ctx.signer?.crypto?.encrypt) throw fail("readOnly")
  let content
  try { content = await ctx.signer.crypto.encrypt(pubkey, plaintext) } catch { throw fail("encryptFailed") }
  // Never publish anything that isn't ciphertext.
  if (!isCiphertext(content)) throw fail("encryptFailed")
  // Encrypted with whichever key was signed in: still the locked account?
  if (!lock.held()) throw fail("accountChanged")
  return publishLocked(lock, { content, tags: SAVED_TAGS }, publish)
}

/** Take the saved wallet off `lock`'s account: the same slot, empty content. Needs no decryption, so it works from a
 *  browser that can't read the slot. */
export async function clearBackup(lock, { publish = publishAction } = {}) {
  if (!lock.held()) throw fail("accountChanged")
  if (lock.ctx.signer?.readOnly) throw fail("readOnly")
  return publishLocked(lock, { content: "", tags: CLEARED_TAGS }, publish)
}

async function publishLocked(lock, { content, tags }, publish) {
  const template = { kind: BACKUP_KIND, created_at: Math.floor(Date.now() / 1000), tags: tags.map(t => [...t]), content }
  // The signer signs for the account it holds; a switch between here and the relays shows as another pubkey.
  const signer = lock.ctx.signer
  const guarded = { ...lock.ctx, signer: { ...signer, signEvent: async t => {
    if (!lock.held()) throw fail("accountChanged")
    const ev = await signer.signEvent(t)
    if (ev?.pubkey !== lock.pubkey || !lock.held()) throw fail("accountChanged")
    if (ev.content !== "" && !isCiphertext(ev.content)) throw fail("encryptFailed")
    return ev
  } } }
  return publish(guarded, template)
}

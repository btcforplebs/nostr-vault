# Share Portal contract (phase 1)

"Share → Nostr Vault" with more than photos. The share surface (iOS share
extension, Android `SharePortalActivity`) holds **no key**. It reads what it
was given, lets the person pick an action and fill a small form, writes a
**share intent** to a queue and leaves. The app claims the intent, shows a
review card and signs with whatever signer the account uses.

Both platforms implement this file. The JSON fixtures in
`HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/SharePortal/` are the
tests for it: the Swift tests (`MediaLogicTests`) and the Kotlin tests
(`NostrVault/app/src/test/.../shareportal/`) read the same files.

## 1. The share intent

```json
{
  "v": 1,
  "id": "6F1C2A4E-0B7D-4C1E-9F3A-2B8C5D7E9A10",
  "created_at": 1730000000,
  "account": "npub1…",
  "action": "highlight",
  "source": {
    "url": "https://example.com/post",
    "title": "A post",
    "text": "",
    "selection": "The part worth keeping.",
    "app": "com.apple.mobilesafari",
    "ld_types": ["Article"]
  },
  "files": [ { "name": "page.pdf", "mime": "application/pdf", "path": "files/<id>/page.pdf", "bytes": 123456 } ],
  "form": { "passage": "The part worth keeping.", "comment": "" }
}
```

| Key | Rule when reading (decode rejects the whole intent if broken) |
|---|---|
| `v` | must be `1` |
| `id` | 1–64 chars of `A-Z a-z 0-9 -`. It names files on disk, so nothing else |
| `created_at` | unix seconds, integer |
| `account` | optional; an `npub1…` or empty. The app never acts as an account it does not hold |
| `action` | one of the 13 below; anything else rejects the intent |
| `source.*` | all optional strings, capped (see limits); `ld_types` max 20 entries of 100 chars |
| `files[]` | max 20. `name` has no `/`, `\`, no leading `.`, not `..`; `path` must equal `files/<id>/<name>` |
| `form` | flat string → string map, max 32 keys, keys 1–64 chars, values capped at 20,000 chars |

Limits (UTF-16 / Kotlin `String.length` units; longer values are cut, not rejected, and a cut that would split a surrogate pair lands one unit short):
`url` 4,096 · `title` 1,000 · `text` 100,000 · `selection` 10,000 · `app` 200.

Actions (`action` raw values): `highlight`, `bookmark`, `private_copy`,
`article_clip`, `media_post`, `upload`, `recipe`, `profile`, `pay`, `dm`,
`status`, `calendar`, `label`.

No secrets go in an intent: no key, no NWC string, no decrypted DM text from
elsewhere. Text the person typed (a highlight comment, later a DM body) sits in
the queue until the app claims it.

## 2. The queue

```
<root>/ShareQueue/<id>.json            the intent, written last
<root>/ShareQueue/files/<id>/<name>    its files, written first
<root>/ShareQueue/.partial-<id>.json   being written; never read
```

- iOS root: the App Group container `group.com.havenapp.relay`. Android root:
  `filesDir`, folder `share_queue/` (same layout below it).
- **Write:** copy files into `files/<id>/`, write the JSON to `.partial-<id>.json`,
  rename it to `<id>.json`. The rename is the commit.
- **Claim:** move `<id>.json` into the app's private claimed folder, then move
  `files/<id>/` after it. Only the caller whose move of the JSON succeeded owns
  the intent, so two activations cannot act on it twice. A JSON that fails to
  decode is deleted with its files, never shown.
- **Done/dismissed:** delete the claimed JSON and its files. A claimed intent
  stays on disk until then, so the review survives the app being killed (or
  Amber taking over the screen on Android).
- The photo/video `upload` action keeps today's file store (iOS `NVShareInbox`,
  Android `MainActivity.handleShareIntent`): its intent carries no files.

## 3. The classifier

`classify(input) → [action]`, pure, most likely first, no duplicates. Input:
`url`, `title`, `text`, `selection`, `files` (`mime`, `name`), `ld_types`.

1. **Web URL** = `url` if it is `http(s)://`, else the first `http(s)://…` run
   in `text` (ends at whitespace or `<>"`).
2. Signals, each checked over `url` + `text` + `selection`:
   - **pay**: a bolt11 (`lnbc…`, `lntb…`, `lntbs…`, `lnbcrt…`, then 20+ more
     `[0-9a-z]`, which allows the `1` separator and amount digits) or `lnurl1…`
     (20+ more `[0-9a-z]`) as a whole word, case-insensitive, optional
     `lightning:` before it; or the trimmed `text` is exactly a lightning
     address (`name@domain.tld`, optional `lightning:`).
   - **profile**: `npub1` + 58 bech32 chars, or `nprofile1` + 20+ bech32 chars.
   - **calendar**: a file with mime `text/calendar` or a name ending `.ics`, or
     `ld_types` has `Event`.
   - **recipe**: `ld_types` has `Recipe`.
   - **status**: the web URL's host (lowercase, `www.`/`m.` dropped) is one of
     `open.spotify.com`, `music.apple.com`, `youtube.com`, `youtu.be`,
     `music.youtube.com`, `soundcloud.com`, `tidal.com`, `wavlake.com`,
     `fountain.fm`, or ends in `.bandcamp.com`.
   - **media**: a file whose mime starts `image/` or `video/`.
   - **pdf**: a file with mime `application/pdf` or name ending `.pdf`.
3. Build the list in this order, skipping anything already in it:
   1. pay → `pay`
   2. profile → `profile`
   3. calendar → `calendar`
   4. selection not blank → `highlight`
   5. media → `upload`, `media_post`
   6. pdf → `private_copy`
   7. recipe → `recipe`
   8. status → `status`
   9. web URL → `bookmark`, `article_clip`, `highlight`, `private_copy`, `dm`, `label`
   10. no web URL, `text` not blank → `highlight`, `dm`
   11. any file that is not media → `dm`

The share surface shows only actions that are ready (`NVShareActionAvailability`
/ `ShareActionAvailability`). In phase 1 that is `highlight` and `upload`.
Phase 2 lanes add their action there; nobody else edits the classifier.

## 4. Accounts snapshot

`<root>/SharePortal/accounts.json` (Android: `filesDir/share_portal/accounts.json`),
written by the app, read by the share surface for the "post as" picker:

```json
{ "v": 1, "active": "npub1…", "accounts": [ { "npub": "npub1…", "name": "Logen", "picture": "https://…" } ] }
```

npub, display name and picture URL only. No key, no signer kind.

## 5. Opening the app

- iOS: a share extension cannot open its app. It leaves a local notification
  (id `nv.share.portal`) whose tap opens `nostrvault://shareportal`; opening the
  app any other way also claims the queue.
- Android: the share activity is our own, so after queueing it offers
  **Open now**, which starts the app with `nostrvault://shareportal`.
- The share surface never publishes. Every action ends on a review card in the
  app with an explicit button.

## 6. Lane D: Pay or zap, Send privately

**Pay target.** `PayShareTarget.find(url, text, selection)` (`SharePortalKit/PayShareTarget.swift`,
`shareportal/PayShareTarget.kt`) uses the classifier's own pay patterns: the
first bolt11, else the first LNURL, else the whole trimmed `text` when it is a
lightning address. Token lowercased, `lightning:` dropped. `recipientNpub` is
set only when the share names exactly one npub. A zap is offered only when the
target is an address equal to that npub's own profile `lud16`. Fixture:
`pay-target-cases.json`.

**Money rules.** The share surface shows the target and sets no amount. The
review card pays only after its confirm; refuses an invoice with no amount or
past its expiry (checked again at pay time); refuses an LNURL invoice whose
msat differs from the amount asked (LUD-06); and records each pay share's
attempt by intent id outside the queue (iOS `UserDefaults`, Android
`SharedPreferences` `share_portal_pay`), so once a wallet call for an LNURL or
zap has started that share can never pay again, even after the app is killed.
A bolt11 may be retried (one payment hash cannot settle twice).

**Recent private recipients.** `<root>/SharePortal/contacts.json` (Android:
`filesDir/share_portal/contacts.json`), written by the app only after a
private send from a share, read by the share surface:

```json
{ "v": 1, "recent": { "npub1<account>": [ { "npub": "npub1…", "name": "Bee", "picture": "https://…" } ] } }
```

Newest first, at most 8 per account, accounts no longer on the device are
dropped on each write. npub, name and picture only. The sheet's pick is a
suggestion (`form.to`); the review card shows the recipient and the exact text
and sends only on its button, as the share's account only. Text only: files
are not sent privately yet. Fixture: `contacts-cases.json`.

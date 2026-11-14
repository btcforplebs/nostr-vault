# Napplets P4: Feed, Thread and Profile as the Reader napplet, and Compose on its own

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P4). Local only: nothing published to a catalog, nothing deployed.

## What changes for the user

With the napplet switch on (Apps page, `?shell=1`):

- **Feed** (`#/feed`), **a thread** (`#/thread/<id>`) and **someone else's profile** (`#/profile/<pubkey>`) are the
  Reader napplet (`napplets/reader/index.html`). It is one element in the phone layout, so it stays mounted as you move
  between them; on desktop it replaces the Feed list.
- **Post** and **Reply** open the Compose napplet (`napplets/compose/index.html`) in a sheet.
- Your own profile, Search, Notifications, the Vault and Settings stay as they are.

Switch off: every old screen, unchanged (checked: classic feed rows come back, no Reader frame).

## How it works

- **Reader:** feed of the people you follow (kinds 1 and 6, 40 a page, Older notes), a live "N new" pill, threads
  (NIP-10 marked and positional tags, replies under the note they answer, 4 levels deep), profiles (kind 0 + notes),
  Like (kind 7, signed by the shell), @mentions, note links, hashtags. Pictures are bytes from the shell (its IP
  rules), loaded once in view, 4 at a time. Video says "plays in the classic view for now" (P5).
- **Compose:** a note or a reply (NIP-10 root/reply/p tags, hashtags as `t`), a draft kept per note answered in its
  own storage until sent. When sent it emits `nv.compose.sent` (the Reader shows it at once) and `nv.compose.done`
  (the shell closes the sheet).
- **Shell side** (`src/napplet/ReaderPane.jsx`, `reader-intents.js`): mounts the Reader, answers its intents:
  `napplet:compose/new|reply` → mounts Compose; `napplet:link/open` → a new tab, http(s) only, no credentials,
  `noopener,noreferrer` (the bus now has shell-answered handlers, `deliver`). The shell opens a thread or profile in
  the Reader with `napplet:note/open` / `napplet:profile/open`.
- Both are first-party (built in, matched by hash): the grant and signing rules are unchanged. Reads go through
  `outbox` (the vault first, then relays, block-filtered); neither napplet has a network or a key.

## Not in P4 yet (the classic screens still have them)

Video and audio playback (P5), zaps, reposts and quotes, bookmarks, the note menu (mute, block, report, delete),
NIP-30 custom emoji and content warnings in notes, the send delay with Undo, emoji and media in Compose, a thread
or profile in the desktop's right pane, and the feed modes other than Following.

## Checked

- `npm test`: 12 new (napplet-reader.test.mjs runs the napplets' own pure blocks as shipped: tokenizer and
  nostr: decoding, NIP-10 root/parent, reply tags, note template, thread rows, link checks, the bus intents).
  Mutation: letting any scheme through `linkTarget` turns 2 tests red. `feed-ceiling-anchor.test.mjs` times out
  on its own on clean master too (timing), not from this change.
- Real app, headless Chrome, vite dev, throwaway keys, a fake relay that answers filters and records what is sent:
  feed of 3 notes on the Reader's own origin, pictures through the shell, Like → one kind 7 (e, p, k), a link →
  exactly one `window.open(url, "_blank", "noopener,noreferrer")`, thread with its reply, Reply → Compose with
  "Replying to", Post → one kind 1 with root, reply, both p tags and `t spring`, the sheet closes and the reply
  shows in the thread, profile with about + notes, a live note → "1 new" → shown, `#/thread/<id>` opens in the
  Reader, switch off → classic feed. 2 events published in total, both to the fake relay.
- The run caught two bugs before merge: the hidden "N new" pill still drew an empty orange shape, and mentions lost
  their "@" once the name loaded.

# Napplet gaps, Reader group: zaps, reposts, quotes, the note menu, Undo, media in Compose

From docs/napplets/P8_CLEANUP.md. Behind the napplet switch; nothing on by default, published or deployed.

## What the Reader can do now

Each note has these actions: Reply, **Repost** (⟲), **Quote** (❝), Like, **Zap** (⚡) and **⋯**.

- **Repost:** the classic repost (`repostWithUndo`). It counts down with Undo in the pill, then sends kind 6.
- **Quote:** Compose opens in quote mode. The note it makes is byte for byte the classic composer's (`quoteOf`: the
  nevent line, a `q` tag and the author tagged).
- **Zap:** the classic amount picker (`AmountPicker`, `zapWithFeedback`). If you can't zap, it says why: no wallet,
  a read-only sign-in, or no lightning address.
- **⋯:** the classic items and dialogs: Copy link, Copy text, Bookmark, then Delete post (on yours) or Report and
  Block / Unblock (on someone else's). A deleted note leaves the Reader at once.
- **Quoted notes** (`nostr:note` / `nevent`) show as a card with the author and text; a tap opens it.
- **Compose:**
  - **＋ Photo** uploads through the shell (NAP-UPLOAD to your media servers) and adds the link and a NIP-92 `imeta`.
  - Reply tags are now `net/actions.js replyTags` ported whole (a test checks they match).

## How the shell does it

- **Send Delay with Undo for every napplet** (`publish-delay.js`, dispatch.js, shell-deps.js `delay`): before the
  shell signs kind 1, 6, 16 or 1111 for a napplet, it waits the user's Send Delay with the classic pill and Undo.
  Nothing is signed until the countdown ends. `created_at` is stamped when it goes.
  - Compose's sheet steps aside while the countdown runs (it's a modal dialog, which would block the pill's Undo),
    and comes back with the text intact on Undo.
- **Repost, Zap and ⋯ are shell-answered intents** (`napplet:note/repost|zap|menu`). The napplet hands over the note
  and the shell runs its own flow, so the napplet never signs a repost, a zap request, a block list, a report or a
  deletion.
  - The note must carry a valid signature (`reader-intents.js actionNote`, or the signed kind 1 inside a kind 6), so
    a napplet can't make the shell act on a note it made up.
- **Found while testing:** nostr-tools' `verifyEvent` caches "verified" on the event object under a symbol, and a
  spread copy keeps it, so an edited copy of a verified event passes unchecked. `actionNote` and shell-deps `verify`
  now check a plain JSON copy. Over the napplet's port the symbol never survives (structured clone drops it); this
  closes the in-process path too.

## Checked

- `npm test`: 2380 pass. New: `napplet-reader-actions.test.mjs` (delay kinds and pills; Undo means nothing signed;
  reactions not delayed; forged and symbol-carrying notes refused; repost/zap/⋯ only for signed notes; the Reader's
  controls). Compose's reply tags, quotes and imeta are checked against the classic functions.
- **Real app** (headless Chrome, throwaway keys, fake relay and Blossom, Send Delay 5 s):
  - The quote card shows "Ann Gap · Ann's original thought.".
  - Repost then Undo: 0 kind 6. Repost: one kind 6 with the right e and p, and Ann's note as its content.
  - Quote then Undo: "Undone…", the text kept, 0 kind 1. Quote: one kind 1, `q` and `nevent` naming Ann's note, and
    the sheet closed.
  - Photo: uploaded, the note carries the link and `imeta`.
  - Zap with no wallet: "Zap Ann Gap · Connect a wallet…".
  - ⋯ on Ann's note: Copy link, Copy text, Bookmark, Report note…, Block Ann Gap…, Cancel.
  - ⋯ Delete on my own note: one kind 5 naming it, and the note is gone from the feed.
  - Published in all: 6, 1, 1, 5.
- **Caught before merge:**
  - Undo was unreachable behind the Compose sheet (a quote went out un-undoable)
  - picking Delete closed the whole menu, the delete dialog with it
  - the sheets showed npubs, not names
  - the nostr-tools cache issue above

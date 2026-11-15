# Step 2b: the full composer in the new Feed

Plan: OUTBOX/NV_WEB_ONE_PLAN.md step 2 (part 2 of 2; part 1 is STEP2A_BESIDE.md).

- **Post, Reply and Quote open the site's full composer** on the desktop (`ReaderPane fullCompose`): the same
  dialog as the classic desktop (`#/compose`, `#/compose?reply|quote=<id>`), over the feed, which stays as it was.
  So the new Feed gets everything the classic composer has: @mentions (follows first), emoji and custom emoji,
  several photos and videos with ALT (picked, dropped or pasted), the live preview, drafts per note, the Send Delay
  with Undo, "Save as draft?" on Cancel, and Article, Recipe, Poll and Highlight.
- **Shell-answered,** like Repost, Zap and the menu (`reader-intents.js`): `napplet:compose/new` needs nothing,
  `reply` and `quote` need a signed event (a made-up note is refused). The composer signs with your signer as it
  always has; the Compose napplet isn't mounted on the desktop. Without `fullCompose` (no desktop shell) the Compose
  napplet answers as before.
- **The sent note shows at once:** the composer fires `nv:note-sent` once a relay has it; each ReaderPane passes it
  to its Reader as inc `nv.compose.sent`, the topic the Compose napplet used.

Why not grow the Compose napplet: the classic composer is ~2,000 lines across six kinds with its own tests; a second
copy in a napplet would drift. Compose is your own writing and signing, like keys and money, so the site's own screen
fits. The Compose napplet stays for a shell without the dialog.

Checked: test/napplet-full-compose.test.mjs (3), full web-vault suite 2520/2520; Chrome + WebKit at 1440x900,
throwaway keys + fake relay: Reply -> dialog with "Replying to", @Ann picker, preview, posted kind 1 with root e,
p, nostr:npub and t tags, dialog closes; Post -> dialog with Note | Article | Recipe | Poll | Highlight; a new note
shows in the Reader at once (red with the listener removed).

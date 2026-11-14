# Napplets P7: Messages as a napplet, NAP-DM in the shell on our own DM stack

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P7). Local only: nothing published or deployed.

## What changes for the user

With the napplet switch on, **Messages** (`#/messages`) and **a conversation** (`#/dm/<pubkey>`) are the Messages
napplet (`napplets/messages/index.html`, `src/napplet/MessagesPane.jsx`). It has:

- Inbox and Requests, split the same way as the classic page (strangers go to Requests), with unread counts and the
  last message
- a conversation: day dividers, older pages, live messages, Enter to send, failed sends marked "Not sent"
- New, from an npub, nprofile or hex key

On a phone it wears the Vault menu, as the classic page does. The classic signer, AUTH and "Open more" lines stay
above it: they are about your signer, which the napplet never sees.

Switch off: the classic Messages and Conversation screens.

## NAP-DM in the shell (`src/napplet/dm-dispatch.js`)

This is the NAP-DM draft's wire (`dm.status`, `dm.conversations`, `dm.messages`, `dm.send`, `dm.subscribe` /
`dm.unsubscribe`, `dm.message` pushed), answered from the classic DM state (`net/dms.js`):

- **What stays in the shell:** keys, decryption (NIP-17 and old NIP-04 reads), sealing and gift-wrapping a send,
  NIP-42 AUTH to inboxes, and the sealed cache. A napplet gets text, a sender, a time and a status. It never sees an
  event, a seal, a wrap or a key.
- **What a napplet can do:**
  - **Send:** one recipient (direct; no groups yet), through `sendMessage`, which does what Send does on the classic
    page. A blocked person can't be messaged.
  - **Read:** blocked people stay out of the list. A conversation with someone blocked shows only your own messages,
    as the classic page does. Reading a conversation's first page marks it read.
  - **Live:** only messages that arrive after it subscribed are pushed. Pending bubbles are never pushed. At most 4
    subscriptions.
- **Decision 2 (unchanged):** DMs are vault-private. An outside napplet without the private-data grant gets
  `available: false` and nothing else. With the grant, it is **asked before every send** and shown who it goes to and
  the text. Ours is the Messages screen itself, so it isn't asked.
- **Our extensions** on a conversation: `request` (Requests vs Inbox) and `last` (the preview). The shell also nudges
  its own napplet with `napplet:dm/refresh` when names arrive, and opens a conversation with `napplet:dm/open`.

## Not in P7 yet

- Photos in messages (the classic composer can attach one)
- message search
- a name for a brand-new conversation that has no messages yet (it shows the key until there are some)
- group DMs

## Checked

- `npm test`: 2372 pass, 9 new (`napplet-messages.test.mjs`). Mutation: dropping the send ask, the blocked check, or
  the private-data gate each fails a test. Two older tests that used `dm` as the example of a missing domain now use
  `llm`.
- **Real app** (headless Chrome, vite dev, throwaway keys, real NIP-17 gift wraps in a fake relay; the browser signer
  does NIP-44 with the throwaway key):
  - Inbox shows "Ann Example" with "And a second one." and 2 unread. Requests shows "Bob Stranger".
  - The thread shows both of Ann's messages.
  - Send "Hello Ann, from the napplet." sent 2 wraps. Ann's opens with Ann's key to exactly that text, from me, and
    the outer wrap isn't signed by me. Nothing else was published.
  - A live message from Ann shows in the open thread. New from Cleo's npub opens a thread. `#/dm/<bob>` opens Bob's.
  - The napplet frame has no `window.nostr`. Switch off → the classic page.
- **Caught before merge:**
  - a `<form>` send was silently blocked by the frame's sandbox (no allow-forms)
  - names never loaded: the DM state's Map changes in place, so a memo on it never re-ran
  - the thread header scrolled off under the Vault menu
  - the phone page was missing the Vault menu

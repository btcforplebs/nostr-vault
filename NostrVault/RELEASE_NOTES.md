# NostrVault v2.7.0 (Build 15) Release Notes

A new look and a lot of new surface. The filing-cabinet icon is gone — the app now wears the lit arch in Sunset Orange, as a proper adaptive icon and as the silhouette you see in your notification shade. Behind it the app has a real visual system for the first time: one elevation ramp, named colours instead of hardcoded ones, and animations that honour Reduce Motion. This release also adds home-screen widgets, long-form Articles, a Recipes feed, and Live streams with chat and zapping. The Global feed no longer shows the raw firehose to brand-new accounts.

## Security

*   **The Global Feed Showed Everything to New Accounts**: The spam filter is built from your follow graph, and an empty graph — exactly what a new account has — let everybody through. Global now shows only accounts in your graph, and the graph is seeded from the app's own starter packs so a new account has one within seconds of first launch.

## New

*   **A New App Icon**: The lit arch in Sunset Orange, as an adaptive icon, with a themed monochrome layer so notifications show the brand instead of a generic dot.
*   **A Consistent Look**: One elevation ramp and one set of named colours behind every screen — card and page contrast used to be inverted — plus one animation vocabulary with Reduce Motion support.
*   **Home-Screen Widgets**.
*   **A Threaded Feed**: The feed's view button now cycles expanded, condensed and threaded. Threaded gathers a conversation into one card with its replies on a rail; tap a reply to open it in place with its action bar, tap again to go to the thread. Each feed remembers its own layout.
*   **Articles**: Long-form posts from the people you follow, drawn as articles with a reader.
*   **Recipes**: A feed of cooking posts from zapcooking and nostrcooking, live from relays.
*   **Live Streams**: Only the streams actually running, with chat, zapping, report and block.
*   **Scan a Signer's QR Code**: Connect a remote signer with the camera instead of typing a bunker string, including during setup.
*   **Taps From Outside the App** open the right screen, and Groups is reachable.

## Removed

*   **The Ecash Wallet**: Ecash is cash held at a mint you have to trust, and the mint this app shipped against was drained and shut down. Rather than keep a feature carrying that risk, it is gone — along with its mint setting, its step in setup, and the Sats widget that showed its balance. Lightning and Nostr Wallet Connect are untouched. **If you are holding ecash in an older version, move it out before you update**; the wallet screen is the only place it can be spent from.

## Bug Fixes

*   **Threads Stuck on "Loading the Start of This Thread"**: The start of a thread usually arrived — the feed just never looked again. It does now, and it stops throwing away the notes it fetched.
*   **Discovery Now Comes From the People You Follow**: It used to rank whoever the app happened to have seen, all tied, in arbitrary order. It now counts who your follows follow, the same way the Apple apps do.
*   **Search Read the Feed, Not Your Relay**: In relay mode, search looked through whatever the feed happened to have loaded instead of asking your own relay, so anything not currently in memory was invisible to it. It now queries the relay.
*   **Quoted Posts**: A quoted post now draws as a card in the feed, on the focused note and on the relay tab, with quoted articles resolved.
*   **Zap Amounts**: Read from the invoice, since receipts do not carry them — and an invoice with no amount no longer reads as 1 BTC in live chat.
*   **Live Streams**: The live feed no longer crashes on its first real run, and the chat composer no longer sits behind the tab bar.
*   **Tap Targets**: The note action row is a full 48dp tall with no dead gaps between buttons.
*   **Search Results Can Be Acted On**: Reply, repost, like and zap from a result instead of buttons that draw nothing.
*   **Report and Block From the Feed**.
*   **Engagement Counts Are Shown**: The card was already being handed them.
*   **Drafts**: A swipe asks before it deletes, and the Drafts screen is the drafts screen.
*   **Text Size**: The setting does something now.
*   **Names and Avatars** no longer stay as fallbacks in feed rows, and a media link stops printing above its own thumbnail.
*   **Media Uploads**: A failed signature is retried instead of failing the post.
*   **Paying an Invoice**: Confirms first, and shows the amount before you approve it.
*   **A Fresh Clone Could Not Build the App At All**.

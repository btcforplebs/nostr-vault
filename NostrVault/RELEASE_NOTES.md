# NostrVault v3.0.0 (Build 15) Release Notes

A new look and a lot of new surface. The filing-cabinet icon is gone — the app now wears the lit arch in Sunset Orange, as a proper adaptive icon and as the silhouette you see in your notification shade. Behind it the app has a real visual system for the first time: one elevation ramp, named colours instead of hardcoded ones, and animations that honour Reduce Motion. This release also adds home-screen widgets, long-form Articles, a Recipes feed, and Live streams with chat and zapping. The Global feed no longer shows the raw firehose to brand-new accounts.

## Security

*   **The Global Feed Showed Everything to New Accounts**: The spam filter is built from your follow graph, and an empty graph — exactly what a new account has — let everybody through. Global now shows only accounts in your graph, and the graph is seeded from the app's own starter packs so a new account has one within seconds of first launch.

## New

*   **A New App Icon**: The lit arch in Sunset Orange, as an adaptive icon, with a themed monochrome layer so notifications show the brand instead of a generic dot.
*   **A Consistent Look**: One elevation ramp and one set of named colours behind every screen — card and page contrast used to be inverted — plus one animation vocabulary with Reduce Motion support.
*   **Home-Screen Widgets**.
*   **Articles**: Long-form posts from the people you follow, drawn as articles with a reader.
*   **Recipes**: A feed of cooking posts from zapcooking and nostrcooking, live from relays.
*   **Live Streams**: Only the streams actually running, with chat, zapping, report and block.
*   **Scan a Signer's QR Code**: Connect a remote signer with the camera instead of typing a bunker string, including during setup.
*   **Taps From Outside the App** open the right screen, and Groups is reachable.

## Bug Fixes

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

# Nostr Vault v2.7.0 Build 15 (macOS / iOS) Release Notes

A new look and a lot of new surface. The filing-cabinet icon is gone — every platform now wears the lit arch in Sunset Orange, and behind it the app has a real visual system for the first time: consistent elevation, semantic colours, and one set of animations that honours Reduce Motion. This release also brings home-screen widgets, a proper two-column iPad layout, and three new feeds: Articles, Recipes, and Live streams with chat and zaps. Two things that were quietly unsafe are fixed — revealing your private key could skip authentication entirely, and the Global feed showed the raw firehose to brand-new accounts.

## Security

*   **Revealing Your Private Key Could Skip Authentication**: If Face ID, Touch ID and a passcode were all unavailable — or the authentication system returned any error — the app revealed your key anyway instead of refusing. It now reveals only after authentication actually succeeds.
*   **The Global Feed Showed Everything to New Accounts**: The spam filter is built from your follow graph, and an empty graph — exactly what a new account has — let everybody through. That firehose measured about two thirds spam. Global now shows only accounts in your graph, and the graph is seeded from the app's own starter packs so a new account has one within seconds of first launch.

## New

*   **A New App Icon**: The lit arch in Sunset Orange, on the Mac, the iPhone, the iPad, the widgets, and the small icons in the relay's own web pages.
*   **A Consistent Look**: Cards, sheets and pages were each assembled by hand from hardcoded values. There is now one elevation ramp and one set of named colours behind every screen, and one animation vocabulary that respects Reduce Motion.
*   **Home-Screen Widgets**: Vault Pulse, Feed Glance, Quick Actions, Sats, Mosaic and Lock Screen sizes, all tappable straight into the right screen.
*   **A Real iPad Layout**: List and detail as genuine columns for both the feed and the relay, with a divider you can drag — not a phone layout stretched wide.
*   **A Threaded Feed**: The feed's view button now cycles expanded, condensed and threaded. Threaded gathers a conversation into one card with its replies on a rail; tap a reply to open it in place with its action bar, tap again to go to the thread. Each feed remembers its own layout.
*   **Articles**: Long-form posts from the people you follow, drawn as articles with a reader, instead of a wall of raw text.
*   **Recipes**: A feed of cooking posts from zapcooking and nostrcooking, live from relays.
*   **Live Streams**: Only the streams actually running, with chat and zapping while you watch.
*   **A GIF Keyboard**: In the composer, backed by getyarn and Tenor, with captions that stay readable over bright frames and a layout that packs tall and wide GIFs without gaps.
*   **Selectable Notification Sounds**.
*   **Scan a Signer's QR Code**: Connect a remote signer with the camera instead of typing a bunker string.
*   **A macOS Status Panel**: The menu bar item is now a panel of its own, separate from the main window.
*   **A Tidier Media Tab**: Date sections, a sort menu, and filters that stop resetting themselves.
*   **Invoice Amounts Up Front**: The wallet shows what an invoice is worth before you pay it.

## Removed

*   **The Ecash Wallet**: Ecash is cash held at a mint you have to trust, and the mint this app shipped against was drained and shut down. Rather than keep a feature carrying that risk, it is gone — along with its mint setting, its step in setup, and the Sats widget that showed its balance. Lightning and Nostr Wallet Connect are untouched. **If you are holding ecash in an older version, move it out before you update**; the wallet screen is the only place it can be spent from.

## Bug Fixes

*   **Threads Stuck on "Loading the Start of This Thread"**: The start of a thread usually arrived — the feed just never looked again. It does now, and it stops throwing away the notes it fetched.
*   **Profiles Missed Older Notes and Showed Them Out of Order**: A profile now pages through someone's whole history, in order.
*   **Discovery Picked People at Random at the Cut-Off**: Ties are broken consistently, a follow list seen on three relays counts once, and accounts that follow more than 200 people get their whole network counted.
*   **Too Many Notifications**: Your phone wakes the app in the background several times an hour, and each wake announced "N more new items while you were away" as though you had just come back. That summary now waits for a real absence — two hours out of the app — and says it once. "New notes in your feed" was a separate stream that obeyed no setting at all, not even the master notification switch; it is now its own switch in Settings › Notifications and it is **off**. And the "N more new items" count now leaves out the notification types you have switched off, which it could never do before, because a single number cannot be filtered after the fact.
*   **Clicking a Notification Did Nothing (macOS)**: No notification of any kind responded to a click — not a DM, a mention, a zap, a reaction or a repost — because the Mac app never registered to receive them. It also meant a message arriving while Nostr Vault was the app you were looking at never appeared at all. Clicking one now opens what it is about, including from the menu bar with no window open.
*   **Search Only Looked at Part of Your Relay**: It read whatever the feed happened to have loaded rather than asking your relay, and when it did ask, it asked one place and stopped at the first page. It now searches your whole relay, and finds a post by its author as well as its text.
*   **The iPad Sidebar Was Blue**: Feed, Search, Profile, Media, Relay and Settings all drew in the iOS system colour instead of the app's own.
*   **Quoted Posts Said "Quote"**: A quoted post now draws as a card everywhere it appears, including reposts of quote-posts and quoted articles.
*   **Local Video Stopped Playing After a Reinstall**: iOS moves the app's storage on every install, which left every local video pointing at a folder that no longer existed. Local playback now survives reinstalls.
*   **Link Previews**: Two links to the same site no longer share one preview, and a preview card follows its own link.
*   **macOS Windows and Notifications**: A tapped notification opens the note; the window stops throwing away your tab after a minute in another app; the composer survives a cold start; ⌘N works and there is a visible Post button again; the Blossom dashboard is reachable and opens properly.
*   **The Menu Bar Panel's Avatar Could Blow Out the Dropdown (macOS)**: Your account picture could render at the wrong size, unclipped, pushing the panel's footer open and covering most of the dropdown.
*   **Keyboard and Pointer**: Every control that only answered a swipe or a tap now answers a pointer and the keyboard too.
*   **"While You Were Away"**: Only says that when you actually were.
*   **Live Chat**: The composer no longer hides behind the tab bar, an invoice with no amount no longer reads as 1 BTC, and stream audio resumes after a notification sound interrupts it.
*   **Media Uploads**: A momentary failure no longer abandons an upload or loses a post.
*   **Widgets**: Feed Glance loads avatars and shows posts rather than replies; Mosaic tiles fill their cell instead of blowing it open.
*   **Onboarding**: Invisible checkboxes, an empty Initial Follows step, and a launch screen claiming you follow nobody.
*   **Confirmation Before Irreversible Actions**, with the consequence spelled out.
*   **Silent Dead Ends**: Screens that failed quietly and sat empty now say what went wrong.

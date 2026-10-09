# Nostr Vault v2.7.2 Build 19 (macOS / iOS) Release Notes

Music, hashtags, highlights, and direct messages that finally reach every device you own. This release adds a Wavlake music player that keeps playing while you browse, tappable hashtags, a full action bar in the article reader with NIP-84 highlights, and diVine video posting. Replies to anything that isn't a plain note now go out as NIP-22 comments, so other clients thread them correctly. Three things that were quietly unsafe are fixed: a crafted profile name could plant a fake link in a note, a note full of links could make your phone call out to hundreds of hosts, and an early Follow tap could wipe your whole follow list.

Coming from the last GitHub download (2.7.0, build 15)? 2.7.1 and 2.7.2 brought a built-in Lightning wallet, Sign In With Clave, a Web of Trust switch and language filter for Global, and a security pass on fetched notes and zap receipts. See [CHANGELOG.md](../CHANGELOG.md) for everything.

## Security

*   **A Mention Could Plant a Fake Link (iOS)**: A profile name wasn't escaped before it went into the link that makes a mention tappable. A crafted display name could break out of that link and put an attacker's link elsewhere in the note, just by being mentioned. Names are now escaped.
*   **A Note Could Make Your Phone Call Out to Hundreds of Hosts**: Every link in a note got its own preview card, and each card fetches its page. A note with hundreds of links meant hundreds of requests from your device. Previews now stop at 3 per note; the rest stay as text.
*   **An Early Follow Tap Could Wipe Your Follow List**: Follow and Unfollow wait until your follow list has loaded, but a timeout or error could count as "loaded". A tap in that window replaced your follow list everywhere with a list of one. Now only a real, signed list (or every relay agreeing there is none) counts, and an early tap waits instead of firing.
*   **Setup Accepted an npub That Didn't Match Your Key**: A hand-edited npub could be saved next to a different nsec, and a one-character typo in an npub was accepted as a different person. The npub is now derived from the pasted nsec, and a typed one must pass its checksum.
*   **Highlights Could Be Forged or Flooded**: Every highlight is now signature-checked, length-capped, and refused if dated more than 10 minutes in the future.

## New

*   **Music**: A Wavlake music feed with Trending, Artists, Following and search. It keeps playing in the background with lock-screen, Control Center and Mac Now Playing controls. Artist and album pages, an Up Next queue, shuffle and repeat, AirPlay. A Wavlake link in a post shows a play card, and sharing a song mentions the artist's Nostr profile so they're notified.
*   **Hashtags**: A `#tag` in a post is tappable and opens a live feed of everything carrying that tag, from everyone or just people you follow.
*   **Article Reader Actions and Highlights**: Like, comment, zap, highlight and share under the byline and at the end of the piece. Select a passage to highlight it, with an optional thought. Other people's highlights show inline, with a count you can tap to see who.
*   **Post diVines, Articles and Recipes**: The Post button writes what the feed in front of you shows. In diVines (formerly Reels) you can record up to 6 seconds or pick a video, trimmed to loop cleanly. In Articles and Recipes it opens a long-form editor.
*   **Replies Follow the Threads Spec**: Answering an article, video, highlight or a repost of one now sends a NIP-22 comment, which other clients thread correctly. Replying to a plain note still sends a normal reply. Threads gain a "Quotes & highlights" section.
*   **Live Streams Play From the Feed (iOS)**: A quoted stream or a zap.stream, shosho or njump link plays inline, with an ENDED pill once it's over.
*   **Cleaner Note Text**: Image and link URLs are hidden from note text, with one preview card per link, and a domain-only card when a site has no preview.
*   **iPad Split View in Portrait**: Feed, Relay, Search and Profile show the list and the note side by side in portrait too.
*   **Text Length in Compact and Threaded View**: Choose how many lines a note shows in Settings.
*   **GIF Search From nostr.build**: The GIF keyboard searches nostr.build, which licenses its GIFs for this use.

## Removed

*   **getyarn.io**: Removed from the GIF keyboard in every build. There is no permission to use it.
*   **The "Post as Comment" Switch**: The reply type is now chosen automatically.

## Bug Fixes

*   **Sent DMs Went Missing on Your Other Devices**: Your copy of a sent message could land on relays no device reads DMs from. There is now one DM inbox list for every device, with your Mac relay first, and messages stranded by earlier builds are fetched back once. A private Mac address is never published.
*   **Blocked People Still Showed Up**: Blocking didn't refresh the feed, and reposts, replies and thread context from a blocked person slipped through. They're now filtered everywhere the moment you block.
*   **Photo Posts Waited Behind a Remote Signer**: With a remote signer, a photo post could sit for 90 seconds behind an unanswered request after returning to the app. Upload signing no longer waits in that line.
*   **DM Alerts**: No alert for your own sent messages or for a chat you already have open; tapping an alert opens the chat; the message box clears after sending.
*   **Zaps Given**: The list fetches sent zaps from your feed relays again, survives a refresh, and shows the note you actually zapped.
*   **Reposts Showed the Wrong Time**: A repost now shows when the original note was written.
*   **The Feed Ran Hot While Scrolling (iOS)**: Less work on the main thread while notes stream in, and the feed picker menu no longer stutters.
*   **Banners and the Zap Strike Hid Behind Sheets (iOS)**: Both now draw above any open sheet.
*   **"Contacts Still Loading" Could Stick Forever**: A Follow tap made before your list loads is now applied once it does.
*   **Remote Signer Sessions**: Each signer keeps its own session, so switching accounts no longer reconnects from scratch, and your relay sign-in always goes to your own signer.
*   **Your Media Tab Showed Reposted Media**: Only your own uploads appear there now.
*   **Web of Trust**: Changing the depth rebuilds the graph, the graph saves at every depth, and a slow relay no longer drops lists already received.
*   **GIFs Beside Thread Lines**: They animate and fill the square instead of sitting still and letterboxed.
*   **Post Countdown**: Edit and Undo on the countdown pill take taps again (iOS).

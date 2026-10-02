# NostrVault v2.7.2 (Build 18) Release Notes

A smoother, faster feed on everyday phones, and the Android app catching up with the iPhone. Scrolling on a 4 GB phone no longer stalls while posts and threads load. The feed preloads what is coming, shows photos at their real size with a soft preview, and keeps your place. New in this release: a Followers view, Web of Trust and language filters on Global, a Lightning wallet with history and lightning addresses, and one-tap sign-in with Clave.

## Faster

*   **Smooth Scrolling on Low-RAM Phones**: The feed was re-sorting up to 10,000 notes on the main thread every time a relay sent posts, and in threaded mode it regrouped the whole feed each time a reply's parent arrived. That work now happens in the background, so the list keeps moving. New posts wait until you stop scrolling before they are added, only the row that changed redraws, GIFs use the phone's hardware decoder, and the app's own code is precompiled at install. On a 4 GB test phone: no missed frames in 5,388, where before the list froze for 20 seconds at a time.
*   **The Feed Loads Ahead of You**: The next posts load before you reach them. Photos open at their real size with a blurred preview while they load, and quoted and earlier posts hold their space instead of pushing the feed down.
*   **Fewer Connections**: Lookups share one connection per relay instead of opening a new one each time, and a relay that refuses is left alone for two minutes.

## New

*   **Followers**: The Relay tab has a Followers view: who followed you recently, who came back, and everyone, with a red dot for new follows since you last looked. The Relay tab bar is now Notes · Likes · Zaps · Followers.
*   **Global Filters**: Global shows your Web of Trust by default; the shield switches to Everyone. A language button lets you pick which languages to see.
*   **Lightning Wallet**: Payment history, and send to lightning addresses and LNURLs as well as invoices, with the amount checked before you pay.
*   **Sign in With Clave**: One tap opens Clave, you approve, and you are back connected. The signer session also stays up while you approve, instead of dying when you switch apps.
*   **Comments**: NIP-22 comments (kind 1111) show up in threads, and you answer a comment with a comment.
*   **Zaps**: The bolt flies from your avatar to the zap button and lands with a lightning strike and a haptic crack.
*   **Photo Zoom**: Photos zoom out of their spot in the feed and swipe back into it. The viewer has Save.
*   **Media Tab Backup Badge**: Every tile shows whether it is backed up to your Blossom servers.
*   **One Feed Button**: Like the iPhone: an icon with a status dot, tap for the feed list.

## Bug Fixes

*   **Settings Apply Themselves**: Changing a setting the relay reads at start now restarts the relay for you, only when it would actually start differently. No more "restart to apply".
*   **Posts With Photos Are Not Lost**: A post was cancelled when no outside Blossom server accepted its media, even though the photo was saved on your phone. It now waits and sends when a server is reachable.
*   **Notification Taps** land on the post in the Relay tab.
*   **Threads**: The start of a thread is looked for on the relays that have it, threaded cards show the newest replies, the thread lines sit beside profile pictures, and a quote is no longer treated as a reply.
*   **Keep Your Place** when switching between expanded, condensed and threaded layouts.
*   **Old Notes Show the Year**, instead of "57w".
*   **Quoting a Repost** cites the original post, and relay picks in the composer attach as previews.
*   **The Top Bar** folds away with the bottom bar as you scroll, and the New Posts button folds with it.

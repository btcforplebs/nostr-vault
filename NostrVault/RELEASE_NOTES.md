# Nostr Vault v2.7.2 (Build 20) Release Notes

The Android app now matches the iPhone: same tabs, same wording, same feed, thread and Relay tab. New in this release: Wavlake music with background play, a Marketplace where you can buy and sell, translation of posts in other languages done on your phone, a hashtag feed, an article reader with highlights, and more reliable direct messages.

## New

*   **Music**: Wavlake music plays in the background, with shuffle, repeat, a queue and artist pages. MP3s shared in posts play from a card.
*   **Marketplace**: A Marketplace feed, a Shop tab on profiles, Sell a listing, and Message seller.
*   **Translate**: Posts in another language get a Translate button. Translation runs on your phone (ML Kit); the text is not sent anywhere.
*   **Hashtags**: Tap a hashtag to open a live feed for it.
*   **Articles**: The reader shows highlights and lets you add your own, comment on them, and react, zap or comment on the article. Profiles have Articles, diVines and Music tabs.
*   **Post From Any Feed**: Post diVines, articles and recipes from their own feeds.
*   **GIFs**: A nostr.build GIF picker in the composer.
*   **Search**: Filters, tappable links, and people in your Web of Trust listed right after the people you follow, in Search and in @mentions.
*   **Event Info**: Every post has an Event Info panel with the relays it came from, its details and actions.
*   **Relay Tab**: Likes Given and Zaps Given, count sheets, search, a compact layout, Whitelisted, load more, and tap the tab to jump to the top.
*   **Media Tab**: Upload several files at once, paste, sort, dates, and a grid menu.
*   **Widgets and Icons**: A Mosaic media widget, widgets you can configure, avatars in the feed widget, and a choice of app icon.
*   **Live Streams**: Streams play inside posts, pop out to a moving mini player, rejoin after a drop, and live chat takes pictures from your Blossom servers.
*   **Nostr Vault Badge**: Posts sent from Nostr Vault carry a small glowing badge.
*   **Text Lines**: Settings chooses how many lines of text Compact and Threaded views show.
*   **Signers**: Pair a signer with a nostrconnect:// link, and switch signer accounts without logging in again.

## Direct Messages

*   **Safer**: Message signatures are checked, and a forged sender is rejected.
*   **New Accounts Get Messages**: A new account can be messaged straight away, and messages arrive live.
*   **One Inbox**: One message list across all your devices, and messages you sent from another app are caught up once.
*   **Alerts**: Notifications show the message and open the chat; your own sends do not notify you. With notifications off, a banner shows inside the app. Photos show in the conversation.

## Changed

*   **One Feed Rule**: Following, Global and the shield work the same way in every feed. Everyone is a crossed-out shield.
*   **Notifications Come From Your Web of Trust**, and zap notifications name the person who zapped you.
*   **Replies From Anyone**: Replies to your own posts are kept even when they come from outside your network.
*   **Confirmations** before you delete or remove something.
*   **Group chats (NIP-29) are removed.**

## Bug Fixes

*   **Global and Discovery Empty**: The Web of Trust list was read and saved wrongly, which emptied Global and Discovery.
*   **Blocked People** stay out of every feed.
*   **Following** reads the people you follow from their own relays and keeps bare reposts.
*   **Photo Posts** no longer wait behind a signer request nobody answered, and "Approve in your signer" clears when the signer answers.
*   **Big Follow Lists** can be signed through a remote signer.
*   **Saving Your Profile** keeps your other fields, such as your banner.
*   **Follow** taps made while your list is still loading are applied once it loads.
*   **Reposts** show the original post time, nprofile links open the right profile, link URLs are hidden behind one card per link, and a post is sent from the account that was active when you tapped Post.

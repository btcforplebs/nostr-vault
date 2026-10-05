package com.nostrvault.ui.screens.settings

/**
 * The words behind each setting's (i) button.
 *
 * Keys match `SettingsHelp.swift` on iOS and macOS — change a string in one and
 * change it in the other, so the apps never describe a setting differently.
 * Keep each entry to one or two plain sentences.
 */
enum class SettingsHelp(val key: String, val title: String, val text: String) {
    RELAY_STATUS(
        "relay.status",
        "Your Vault Relay",
        "The relay on this device stores your notes and media locally.",
    ),
    ACCOUNT_ACCOUNTS(
        "account.accounts",
        "Accounts",
        "Add multiple accounts and switch between them anytime.",
    ),
    ACCOUNT_SIGNING(
        "account.signing",
        "Signing",
        "Sign with a key on this device, or approve posts from a separate signer app.",
    ),
    ACCOUNT_REVEAL_KEY(
        "account.revealKey",
        "Reveal Key",
        "Shows your secret key after verifying it's you.",
    ),
    ACCOUNT_PUBLISH_INBOX(
        "account.publishInbox",
        "Publish Inbox Relay",
        "Tells other apps to deliver your messages to this relay.",
    ),
    ACCOUNT_BLOCKED(
        "account.blocked",
        "Blocked",
        "Hides blocked accounts from your feed. For your main account, also blocks them from posting to your relay.",
    ),
    ACCOUNT_SLOWED(
        "account.slowed",
        "Slowed Down",
        "Limits how many posts from one account show at once (1–20).",
    ),
    ACCOUNT_FOLLOWING_BACKUP(
        "account.followingBackup",
        "Following Backup",
        "Saves snapshots of your follow list as it changes, and can restore an older one.",
    ),
    WALLET_NWC(
        "wallet.nwc",
        "Wallet Connect",
        "Connects an outside wallet so you can send zaps.",
    ),
    WALLET_DEFAULT_ZAP(
        "wallet.defaultZap",
        "Default Zap",
        "Sets the sats amount used when you zap with one tap.",
    ),
    WALLET_BITCOIN(
        "wallet.bitcoin",
        "Bitcoin Address",
        "Generates a Bitcoin address from your Nostr key.",
    ),
    FEED_REPOSTS(
        "feed.reposts",
        "Reposts",
        "Show reposts in your feed.",
    ),
    FEED_REPLIES(
        "feed.replies",
        "Replies",
        "Show replies in your feed.",
    ),
    FEED_AUTO_LOAD(
        "feed.autoLoad",
        "Auto-Load",
        "Adds new posts to your feed as they arrive, instead of waiting for you to tap.",
    ),
    FEED_RELAYS(
        "feed.relays",
        "Feed Relays",
        "Relays your feed pulls posts from. Separate from your own relay.",
    ),
    FEED_SEARCH_RELAYS(
        "feed.searchRelays",
        "Search Relays",
        "Relays used for global search on this device.",
    ),
    DISPLAY_TEXT_SIZE(
        "display.textSize",
        "Text Size",
        "Adjusts how large text appears throughout the app.",
    ),
    DISPLAY_TAB_BAR_ANIMATION(
        "display.tabBarAnimation",
        "Tab Bar Animation",
        "Keeps the bottom tab bar full size instead of shrinking as you scroll.",
    ),
    DISPLAY_NEW_POSTS_PILL(
        "display.newPostsPill",
        "New Posts Pill",
        "Shows a pill with the number of new posts waiting above your feed. Turned off, pull down to refresh to load them.",
    ),
    DISPLAY_ZAPS_ONLY(
        "display.zapsOnly",
        "Zaps Only",
        "Hides likes and reactions, and turns off their notifications.",
    ),
    DISPLAY_DEFAULT_REACTION(
        "display.defaultReaction",
        "Default Reaction",
        "Sets which emoji is used for one-tap reactions.",
    ),
    MEDIA_AUTOPLAY(
        "media.autoplay",
        "Autoplay Videos",
        "Plays videos automatically as you scroll.",
    ),
    MEDIA_DISABLE_CACHE(
        "media.disableCache",
        "Media Cache",
        "Stops saving media locally, so it re-downloads each time.",
    ),
    MEDIA_PREFETCH_AVATARS(
        "media.prefetchAvatars",
        "Prefetch Profile Pictures",
        "Loads profile pictures ahead of time for smoother scrolling.",
    ),
    MEDIA_CACHE_T_T_L(
        "media.cacheTTL",
        "Cache Lifetime",
        "How long downloaded media is kept before it's cleared.",
    ),
    MEDIA_CLEAR_CACHE(
        "media.clearCache",
        "Clear Media Cache",
        "Deletes locally stored media now to free up space.",
    ),
    NOTIFY_ENABLE(
        "notify.enable",
        "Notifications",
        "Turns on notifications, made on this device by your relay — no outside push server involved.",
    ),
    NOTIFY_FEED_NOTES(
        "notify.feedNotes",
        "New Notes",
        "Notifies you when new notes appear in your feed.",
    ),
    NOTIFY_PER_ACCOUNT(
        "notify.perAccount",
        "Alerts per Account",
        "Choose which alerts (mentions, replies, DMs, zaps, reactions, reposts) each account gets.",
    ),
    SHARE_DM_RELAYS(
        "share.dmRelays",
        "DM Relays",
        "Relays your encrypted DMs are sent to and read from.",
    ),
    SHARE_BROADCAST(
        "share.broadcast",
        "Broadcast",
        "Copies your notes to public relays so more people can find them.",
    ),
    SHARE_MEDIA_SERVERS(
        "share.mediaServers",
        "Media Servers",
        "Extra servers that keep copies of your media.",
    ),
    SHARE_AUTO_MIRROR(
        "share.autoMirror",
        "Auto-Mirror Media",
        "Downloads your own media from those servers so it works offline.",
    ),
    SHARE_FIPS(
        "share.fips",
        "FIPS Address",
        "Publishes an address so others can find your media directly.",
    ),
    RELAY_SYNC(
        "relay.sync",
        "Sync",
        "Address of your relay on a Mac or server. Notes posted there appear here too.",
    ),
    RELAY_DOMAIN(
        "relay.domain",
        "Domain",
        "Public address for your relay. Leave blank to keep it local-only.",
    ),
    RELAY_PORT(
        "relay.port",
        "Port",
        "Network port your relay uses. Default is 3355.",
    ),
    RELAY_WOT_DEPTH(
        "relay.wotDepth",
        "Trust Depth",
        "How many follows away someone can be and still reach your inbox. Lower is more private.",
    ),
    RELAY_MIN_FOLLOWERS(
        "relay.minFollowers",
        "Minimum Followers",
        "Minimum followers someone needs before they can reach your inbox.",
    ),
    RELAY_WOT_REFRESH(
        "relay.wotRefresh",
        "Trust Refresh",
        "How often your trust list is recalculated.",
    ),
    RELAY_RATE_LIMITS(
        "relay.rateLimits",
        "Rate Limits",
        "Limits on events and connections per minute, to block spam.",
    ),
    RELAY_IMPORT(
        "relay.import",
        "Import",
        "Pulls in your past notes and mentions from other relays, starting at a chosen date.",
    ),
    RELAY_BACKUP(
        "relay.backup",
        "Backup & Restore",
        "Saves or restores your notes and media as a file. Briefly pauses the relay.",
    ),
    RELAY_AUTO_START(
        "relay.autoStart",
        "Auto-Start",
        "Starts your relay automatically when the device turns on.",
    ),
    RELAY_EXTERNAL(
        "relay.external",
        "External Relay",
        "Uses another app's relay instead of the built-in one. Pauses notifications and broadcasting.",
    ),
    ADV_POW(
        "adv.pow",
        "Proof of Work",
        "Adds extra computation to your posts to discourage spam. Slower to send, harder to spam.",
    ),
    ADV_DATABASE(
        "adv.database",
        "Database",
        "Shows which storage engine your relay uses. View only.",
    ),
    ADV_LOG_LEVEL(
        "adv.logLevel",
        "Log Level",
        "How much detail your relay writes to its logs. Changing it restarts the relay automatically.",
    ),
    ADV_FACTORY_RESET(
        "adv.factoryReset",
        "Factory Reset",
        "Stops your relay and permanently deletes all its data and settings.",
    );
}

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.7.0 (15) — macOS / iOS / Android] - 2026-09-XX

> **A new mark, and a surface to put it on.** The filing cabinet is gone: every platform now wears the lit arch in Sunset Orange, down to the Android notification silhouette and the icons in the relay's own web pages. Behind it, the app finally has a visual system — an elevation ramp where there was none, semantic colour tokens instead of hardcoded values, and one motion vocabulary that honours Reduce Motion everywhere. On top of that: home-screen widgets, a real two-column iPad layout, and three new feeds — Articles, Recipes and Live streams with chat and zaps. A biometric bypass that could reveal your signing key without authentication is fixed, and the Global feed no longer fails open to the raw firehose.

### Security
- **Biometric Key Reveal Could Be Bypassed (iOS)**: Revealing your private key called through to the reveal handler in the `else` branch when device-owner authentication was unavailable — no passcode or biometry enrolled, or any `LAContext` error — so the nsec was shown with no authentication at all. It now reveals only on a successful evaluation and fails closed otherwise.
- **The Global Feed Failed Open**: The Web of Trust filter admitted everyone when the trust graph was empty, which is exactly the state a brand-new account is in — the raw firehose, measured at roughly two thirds spam. Global now admits only authors actually in the graph, and the graph is seeded (see below) so "empty" means "not built yet" rather than "this person has no friends". The Global media grid carried the same line and is fixed with it.
- **New Accounts Were Sent to Popular First**: Popular ranks raw engagement from open relays and was the first screen a new user ever saw. They now land somewhere that reflects their own follows.
- **Private Key File Permissions (FIPS)**: Closed the window between creating the nsec file and restricting it.

### Added
- **A Threaded Feed (macOS / iOS)**: The feed's view control now cycles expanded -> condensed -> threaded instead of toggling two layouts. Threaded gathers a conversation — root note and every reply the feed is holding — into one card with an indented reply rail, folding past three replies so a long argument can't own the timeline. Tapping any line opens the thread at that note. It is stored per feed, so Following can stay expanded while Global runs threaded, and picking it turns the Replies filter on, because a threaded feed with replies hidden is just the layout you left.
- **The Lit Arch**: A new app icon across macOS, iOS, iPadOS, the widget extension and Android — including a proper adaptive icon and a themed/monochrome layer, so the Android notification mark is the brand rather than a generic dot. The relay's web UI icons, the website and the docs logo now match.
- **A Surface Ramp and Semantic Colour Tokens**: The app had no elevation system — cards, sheets and pages were assembled from hardcoded values, and on Android card-vs-page contrast was inverted. There is now one ramp, adopted on all three platforms, with duplicate hardcoded colours swept onto tokens.
- **One Motion Vocabulary, With Reduce Motion**: Animations are named by role rather than duplicated per call site, and Reduce Motion is honoured everywhere, on Android too.
- **Home-Screen Widgets (iOS/iPadOS)**: Vault Pulse, Feed Glance, Quick Actions, Sats, Mosaic and Lock Screen families, fed by a shared snapshot the app publishes, with taps routing into the right screen. Android gets home-screen widgets as well.
- **A Real iPad Layout**: List and detail as actual columns for both feed and relay, with a divider you can drag to size them, instead of a phone layout stretched wide.
- **Articles**: Long-form posts from your follows, drawn as articles rather than walls of raw text, with a reader — on iOS, macOS and Android.
- **Recipes**: A feed of zapcooking / nostrcooking posts, live from relays, Following by default with Global behind the same warning the media grid uses.
- **Live Streams (NIP-53)**: Only the streams actually running, with report and block, plus live chat and zapping while you watch — iOS and Android.
- **A GIF Keyboard in the Composer**: Backed by getyarn.io **and Tenor** on macOS and iOS, with its own visual identity, captions that stay legible over bright frames, and a waterfall layout so tall and wide GIFs do not leave holes in the grid.
- **Selectable Notification Sounds**.
- **Scan a Signer's Bunker QR**: Connect a remote signer by camera instead of typing a bunker string, during setup as well — iOS and Android.
- **A macOS Status Panel**: The menu bar item is now a status panel in its own right, separate from the main window.
- **Media Tab, Organised**: Date sections, a sort menu, and filters that stop resetting themselves.
- **Invoice Amounts Before You Pay**: The wallet shows what an invoice is worth first; Android also confirms before paying.
- **Trust Graph Seeding**: An account that follows nobody now seeds its Web of Trust from the starter packs the app already ships, so the first launch has a graph rather than nothing. One list, two consumers — the follow step offers it and the trust graph is seeded from it.
- **Route Taps From Outside the App (Android)**, and Groups is reachable.

### Changed
- **One Condensed Note Row**: The condensed look had been written four times — the feed's compact row, a thread's ancestors, its replies and its focused note — and the copies had drifted apart on avatar size, line limits and card chrome. They are now one `CondensedNoteLine` component, so the feed and the thread view finally read as the same app, and a condensed thread is one card of lines instead of a stack of boxes. Thread grouping is pure logic with unit tests behind it.
- **Popular Is Collected, Not Queried**: Engagement is gathered continuously instead of firing a burst of queries the moment you open the tab, and scoring counts distinct reactors rather than reaction events.
- **One Definition of a Note's Overflow Menu (Android)**, instead of each screen growing its own.
- **Blossom Signs Once Per Blob**: One upload authorisation per blob rather than per request.
- **Android Avatar Prefetch**: Stopped asking for every follow in one breath.
- **GIF Search on Submit**: Searches when you submit rather than on every keystroke, and reveals clips in steps.

### Removed
- **The Cashu Ecash Wallet**: Removed on all three platforms — the wallet, its mint setting, its step in the setup wizard and the Sats widget that displayed its balance. Ecash is a bearer instrument held at a mint you have to trust, and the mint this app shipped against was drained and shut down; rather than leave a feature carrying that risk, it is gone. Lightning and Nostr Wallet Connect are untouched. **If you hold ecash in a previous version, move it out before updating** — the wallet screen is the only place it can be spent from.
- **The Push Infrastructure**: Notifications have been generated on-device from the embedded relay since 2.5, and nothing registered for remote push. The FastAPI/APNs forwarder, the orphaned notification service extension and the `aps-environment` entitlement are gone — scaffolding for a path no code took.
- **Unreachable Screens**: Wired up or deleted, rather than left drawing nothing.

### Fixed
- **Notifications Repeated on Every Background Wake**: iOS grants the app several background wakes an hour, and each one ran a catch-up round ending with "N more new items while you were away" — nothing remembered that the same line had just been said. A summary now requires a real absence (two hours out of the foreground) and fires once per absence. Separately, "N new notes in your feed" fired from that same wake, checked no preference at all — not even the master notification switch — and counted a backfilled older note as news. It is now its own switch in Settings › Notifications, **off by default**, obeys the master switch, and counts by post time against a watermark that advances when you are told or when you open the app. The "N more new items" summary now also honours the notification types you have switched off: it is a single number, so a reaction counted inside it could never be filtered out afterwards — the relay is told which kinds you want before it counts.
- **Clicking a Notification Did Nothing (macOS)**: macOS never set a notification-centre delegate, so *no* notification type responded to a click — DM, mention, zap, reaction or repost. It also meant a message arriving while Nostr Vault was the active app was invisible, since macOS suppresses notifications for the frontmost app unless the app asks for them. Clicking a notification now raises the app and opens what it is about, including from the menu bar with no window open.
- **Search Missed Most of Your Own Relay**: Relay-mode search read the feed cache already loaded in memory rather than querying the local relay — fixed on both iOS/macOS and Android. On iOS and macOS it also asked one route and stopped at the first page; it now searches every route on your relay, pages through the results, and finishes on EOSE, with matches found on a note's text and on its author and text matches ranked first.
- **The iPad Sidebar Was the Wrong Colour**: The compact layout tints its tab bar and the split-view sidebar never did, so every sidebar row — Feed, Search, Profile, Media, Relay, Settings — drew in iOS system blue while the rest of the app was Sunset Orange.
- **Quoted Notes Drew the Word "Quote"**: Quoted posts now render as cards wherever they appear — feed, focused note, relay tab, reposts of quote-posts — on iOS, macOS and Android, with quoted articles resolved too.
- **Local Video Died After an iOS Reinstall**: iOS moves the data container on every install and carries `tmp/` with it, leaving playback symlinks pointing into dead containers; a dangling link reports "does not exist", so every attempt to recreate it failed and the fallback ladder ran dry. Local video now survives reinstalls and plays through hard links.
- **Link Previews**: Two links from the same site no longer share one preview, and a card follows its own URL.
- **Notification Taps and Window Behaviour (macOS)**: Tapped notifications, quoted notes and parent previews open the note; the window stops discarding your tab after a minute in another app; Compose survives a cold start; ⌘N and a visible Post entry point work again; the Blossom dashboard is reachable and no longer opens as a split view.
- **The Menu Bar Panel's Account Avatar Could Blow Out the Dropdown (macOS)**: `AvatarView` sized every layer with `.frame()` but nothing clipped the composed result, and a few call sites built it at its 40pt default size before wrapping a smaller box around it with the same non-clipping `.frame()` — so the avatar could render unclipped at the larger size, pushing the panel's footer open and covering most of the dropdown.
- **Pointer and Keyboard Paths (macOS)**: Every swipe- or touch-only control has one.
- **"While You Were Away" Meant It**: The catch-up summary only says that when you were actually away.
- **Zap Amounts Read From the Invoice (Android)**: Receipts do not carry the amount; an amountless invoice also no longer reads as 1 BTC in live chat.
- **Live Chat**: The composer no longer sits behind the tab bar or scrolls off screen, the app no longer crashes on the first real run of the live feed, chat is fetched from the relays that actually carry it, and stream audio resumes after a notification sound interrupts it.
- **Blossom Uploads**: A transient preparation failure no longer abandons the upload, a failed signature is retried rather than failing the post, and the upload path's diagnostics go to the log file where someone can read them.
- **Widgets**: Feed Glance loads avatars and shows posts rather than replies; Mosaic reads Blossom off disk instead of through the Media tab's cache, and its tiles fill their cell instead of blowing it open.
- **Names and Avatars Stuck as Fallbacks (Android)**, and media links no longer print above their own thumbnail.
- **Tap Targets and Actions (Android)**: 48dp-tall, gap-filling targets on the note action row; search results can be replied to, reposted, liked and zapped; you can report and block from the feed; the engagement counts the card was already being handed are shown; drafts confirm before a swipe deletes them and the Drafts screen is the drafts screen; the Text Size setting does something.
- **Onboarding**: The unselected account checkbox is visible, malformed npubs are rejected before reaching a contact list, `starter_packs.json` ships so the Initial Follows step is not empty, and the launch screen stops claiming you follow nobody.
- **51 Missing Groups String Keys**, and one string-catalogue key for all three Startup Error dialogs.
- **Confirmation Before Irreversible Actions**, saying what is at stake.
- **Failures That Set Dead State** are surfaced instead of leaving a screen silently empty, including a parent-note skeleton that never cleared.
- **Concurrent Mac Relay Syncs** no longer stomp each other.
- **Builds**: Go relay changes were silently missing from incremental builds; the notification sound is in both app targets and stays there; a fresh clone could not build the Android app at all; rebuilt Go binaries and Xcode user state are no longer tracked.

## [2.6.0 (14) — macOS / iOS / Android] - 2026-07-26

> **Sync, Zap Integrity & Protocol Correctness**: Catch-up sync ran every 60 seconds and rebuilt everything from scratch each round — pegging the Mac relay at 100% CPU after about a day and firing a notification a minute. Zap totals were spoofable by anyone who could reach your relays, and are now validated. NIP-42 authentication was broken on the macOS and Android local relays, silently rejecting every gated read. The Android relay could not start *at all* on Android 10–13. Plus posting with media no longer fails on the first attempt, and the macOS app can finally be installed on a Mac other than the one that built it.

### Security
- **Zap Totals Were Spoofable**: A kind-9735 zap receipt is an ordinary Nostr event — anyone able to reach a relay the app queried could publish one claiming any amount, against any note or profile. Both apps displayed and counted every receipt they saw with no validation at all, so every zap total and zap notification could be faked. Receipts are now checked against the recipient's LNURL provider: the pubkey that actually published the receipt must be the one that provider declares as authorized. Validation fails open only when that genuinely can't be determined (no Lightning address, network failure, or a provider that doesn't advertise one), so this tightens security without rejecting legitimate zaps.
- **Private DM Send Times Leaked (Android)**: NIP-17 seals and gift wraps were stamped with the true current time instead of the randomized timestamp the spec calls for, so anyone observing those events on a relay could tell exactly when a private message was sent. Android now applies the same jitter iOS already did.

### Changed
- **Catch-Up Sync No Longer Runs Every Minute**: The default interval moves from 60 seconds to 900, and is clamped to a minimum of 300 everywhere it can be loaded, so an old saved setting can't reinstate the old behaviour. See the CPU fix below for why this mattered so much.
- **One Version Number Across All Platforms**: macOS, iOS and Android had drifted onto separate tracks — 2.6.0 (11), 1.1.1 (11) and 1.2.0 (5) — so the same release carried three different names and a build number meant something different on each. All three now report **2.6.0 (14)**. Android moves from versionCode 5 to 14 (still increasing, so updates install over the previous build as normal).
- **Default Relay & Mirror Lists**: `relay.damus.io` was dropped from every default list — it had begun refusing our sync queries outright and rate-limiting the connection, and being in every fallback list meant every platform hammered it from first launch. Two defunct default Blossom mirrors are also now stripped from saved configuration on load. Relays and mirrors you configured yourself are untouched.
- **Lower macOS Background Memory**: The relay now hands memory back to the operating system as soon as the app goes to the background, rather than waiting for whatever sync or import happens to run next — on an idle relay that could be an hour. Steady-state footprint measured ~24% lower.
- **macOS Builds Are Distributable**: Every macOS build previously produced was signed in a way that let it run only on the machine that built it; on any other Mac it was terminated at launch with no explanation and no crash report. Builds are now Developer ID signed so they run anywhere. Unless notarized, a downloaded copy still needs its quarantine flag cleared once.

### Fixed
- **Mac Relay at 100% CPU After a Day**: Catch-up sync rebuilt the full comparison vector for every relay and every store on every 60-second round, re-downloaded the entire backlog it had already rejected, re-probed relays that deterministically refuse the query, and re-uploaded events certain relays acknowledge but never actually store. Once the databases grew enough that a round took longer than its own interval, rounds ran back-to-back forever. The vector is now built once per round and reused, rejected events are remembered instead of re-fetched, refusing relays are cached for 24 hours, and each loop restarts its timer after finishing so a long round can never chain into the next.
- **A Notification Every Minute**: The same treadmill fired a fresh "N new items" summary on each round. Separately on iOS, the "Catching up" summary was triggered by routine background resyncs — feed reconnects, thread pull-to-refresh, vault load — rather than only when actually returning after being away.
- **Posting With Media Failed on the First Try**: Uploads nearly always failed once and succeeded on retry. The old default mirrors had gone dead, leaving posts dependent on the Mac relay mirror, which was asleep on first contact and only woken *by* the failed attempt. Mirrors are now warmed when the composer opens, the upload pass retries once after 10 seconds, and dead defaults are removed. Android also no longer embeds unreachable local URLs in a note when every mirror fails — it reports the failure instead.
- **Authentication Broken on Local Relay (macOS & Android)**: The relay validated NIP-42 authentication against a `wss://` address while macOS and Android actually serve the local relay over plain `ws://`, and used an empty hostname when no public domain was configured. Authentication therefore always failed, and every read requiring it was silently rejected. iOS was unaffected because it enables local TLS.
- **Profile Notes Fetched From the Wrong Relays**: Loading someone's notes queried their *read* relays rather than the *write* relays they actually publish to, so profiles could appear emptier than they are. A guard was also added so a late-arriving stale relay list can't overwrite a fresher one.
- **Reposting Long-Form Articles**: Reposts were always sent as kind 6, which the spec reserves for reposting plain notes — reposting an article produced an event most clients ignore. Articles now use kind 16 with the original kind named. Android reposts were also missing the relay hint and original author tag.
- **Replies Not Notifying Everyone in a Thread (Android)**: Replies only tagged the immediate parent's author, so everyone else in the conversation was left out.
- **Replies Vanishing From Their Own Threads**: Once replies correctly tagged every participant, any short reply in a thread with seven or more people tripped the mention-spam filter and silently disappeared — including replies you posted yourself.
- **Blocking Someone Didn't Take Effect Until Restart**: Blocking correctly hid content from every view immediately, but the relay itself was never told, so it kept importing and notifying about that person for the rest of the session — visible as notifications for content nothing would display.
- **Notifications and the Activity Dot for Old Backlog**: Catching up on old events could light the activity indicator and fire notifications as though they were new. The age limit that already existed was only being applied in one of the several places that trigger them. The dot also fired for events that aren't notification-worthy at all, such as replying to your own note.
- **Multi-Account Corruption From Background Publishing**: Routine background publishes signed as a non-active account by briefly mutating the shared active-account setting. Every observer saw that as a real account switch, triggering snapshot save/restore and wiping loaded events for no reason.
- **Multi-Relay Signer Connections (iOS)**: A `bunker://` URI listing several relays had all but the first silently discarded during setup, so reconnects had no fallback if that one became unreachable.
- **Android Relay Never Started on Android 10–13**: The foreground service declared a type that only exists on Android 14+, so on Android 10 through 13 the system rejected the start request. The error was caught and turned into a normal-looking "offline" state, meaning the relay silently never ran on those versions and nothing indicated why. The service now requests a type the running system actually understands.
- **Silent Video Failures (iOS)**: When every source for a video failed, the feed showed a black rectangle instead of falling back to its thumbnail, full-screen showed black, and there was no error message or retry anywhere — the state that drove those views was never actually being set. Failures are now reported, the feed falls back to its thumbnail, and "Try Again" works.
- **Interface Stall When Playing Cached Video (iOS)**: Verifying a cached video's integrity — reading and hashing up to 64 MB — ran on the main thread every time a player was created, so scrolling past cached videos could visibly hitch. That work now happens off the main thread, as it already did on Android.
- **Video Audio Interrupted While in Picture-in-Picture (iOS)**: Scrolling the feed while a video played full-screen or in PiP handed the audio session to the muted feed player, interrupting the video you were actually watching.
- **Android Relay Never Started on Android 10–13**: The foreground service declared a type that only exists on Android 14+, so on Android 10 through 13 the system rejected the start request. The error was caught and turned into a normal-looking "offline" state, meaning the relay silently never ran on those versions and nothing indicated why. The service now requests a type the running system actually understands.
- **Silent Video Failures (iOS)**: When every source for a video failed, the feed showed a black rectangle instead of falling back to its thumbnail, full-screen showed black, and there was no error message or retry anywhere — the state that drove those views was never actually being set. Failures are now reported, the feed falls back to its thumbnail, and "Try Again" works.
- **Interface Stall When Playing Cached Video (iOS)**: Verifying a cached video's integrity — reading and hashing up to 64 MB — ran on the main thread every time a player was created, so scrolling past cached videos could visibly hitch. That work now happens off the main thread, as it already did on Android.
- **Video Audio Interrupted While in Picture-in-Picture (iOS)**: Scrolling the feed while a video played full-screen or in PiP handed the audio session to the muted feed player, interrupting the video you were actually watching.
- **Video Stuck Streaming After One Bad Copy (iOS)**: If a locally cached video failed to play once, that video streamed from the network for the rest of the session even after the bad copy was discarded and a good one downloaded.
- **Stale Values in Android Dashboard & Feed Settings**: The cache location, cache duration, feed relay list, and autoplay toggle read their values in a way that never refreshed, so those screens could show outdated settings after a change.
- **A Single Bad Setting Could Prevent Startup**: If any numeric or true/false value in the relay's environment file was malformed or blank — twenty settings qualified, including the relay port — the app terminated during startup with no error, no crash report, and no indication of the cause. Bad values now fall back to their default and log which setting was at fault.
- **Android Release Build Was Broken**: The Android app had not compiled from a clean checkout since 2026-07-16; a relay-list cleanup left an incomplete statement behind. Also cleared every remaining compiler warning on both platforms.

## [2.6.0 (11) macOS / 1.1.1 (11) iOS / 1.2.0 (5) Android] - 2026-07-06

> **On-Device Notifications & Picture-in-Picture**: Notifications no longer depend on any remote push server — they're generated entirely on-device from your own relay, with correct per-account attribution on multi-account setups and a consolidated "N new notifications" summary after catching up from being away. Video now supports Picture-in-Picture on iOS and Android. Plus a Web of Trust self-heal fix that was the root cause of silently-dropped replies and reactions.

### Added
- **Picture-in-Picture Video (iOS + Android)**: Full-screen video keeps playing in a system PiP window when you swipe home or tap the PiP button. New unified full-screen control rail (play/pause, elapsed/duration, scrubber, mute, PiP) auto-hides after 3s of inactivity. Android's full-screen viewer now lives in the activity window instead of a `Dialog` so PiP can actually capture it; iOS's `PiPManager` retains the player past view dismissal so playback doesn't glitch when the viewer closes.
- **Catch-Up Notification Summary**: Returning to the app after being away and catching up via Mac Relay Sync now shows a single "N new notifications" summary instead of one push per event — mirrors the same batching the relay's own live catch-up already used.
- **Mac Relay Sync Status (Dashboard + Settings)**: New status widgets showing last-sync time and manual Sync Now / Full Resync / Reset controls.

### Changed
- **No More Remote Push Server**: Removed all APNs/remote push-server registration code. Every notification — mentions, replies, DMs, zaps, reactions, reposts — is generated entirely on-device from the embedded relay's own event stream. Nothing about your notification activity is ever visible to us, Apple, or Google.
- **Per-Account Notification Attribution**: On devices with more than one whitelisted account, notifications now resolve preferences — and which account a tap switches to — against the account the event was actually tagged for, instead of guessing from whichever account happens to be active in the UI.
- **Message Composer Recipient Chip**: Tapping a search result when starting a new message now visibly shows the selected recipient (previously nothing appeared to happen, even though the recipient actually registered).
- **Settings**: "Push Notifications" renamed to "Notifications" throughout, since there's no push server involved anymore.

### Fixed
- **Stale Web of Trust Cache**: A Web of Trust snapshot computed during a past follow-list incident could get stuck and silently reject real replies/reactions as "not in WoT" for days, since the cache's TTL far outlives how long a mobile app process stays alive. The cache now checks its own age against the refresh interval at boot and refreshes in the background when due, instead of relying solely on an in-process timer that rarely gets 24 continuous hours to fire.
- **Missing Notifications from Mac Relay Sync**: Events that only ever reached the phone via Mac Relay Sync's catch-up (as opposed to the live relay subscription) were imported silently — no notification, no relay-activity indicator. The local relay's inbox/chat storage path now runs the same notification logic as the live subscription path.
- **Mac Relay Sync Could Take Down the Local Relay**: Mac Relay Sync had no minimum gap between opportunistic sync rounds, so repeated triggers (e.g. from feed reconnects) could fire back-to-back and overwhelm the local relay's own connections badly enough that it stopped responding — including to your own post attempts. Added the same minimum-gap throttle the relay's own catch-up sync already used.
- **Mac Relay Sync `/private` and `/chat` Catch-Up**: These endpoints require NIP-42 authentication that Mac Relay Sync never performed, so every catch-up attempt against them silently timed out after 60 seconds without transferring anything. Now authenticates before querying.
- **Xcode Incremental Build Could Ship a Stale Relay**: The Go relay archive's build script phases were configured in a way that let Xcode's build system skip rebuilding them entirely on incremental builds, with no error — meaning a real Go-side change could ship without actually being in the binary. Fixed the phase configuration so it always re-checks (and only recompiles when the source actually changed).

## [2.5.1 (10) macOS / 1.1.1 (10) iOS] - 2026-06-17

> **Zaps Only Mode, @-mention Autocomplete & Feed Reliability**: New Appearance setting that strips likes/reactions from the app so zaps are the only engagement; inline @-mention autocomplete in the composer; tap-to-swipe full-screen note media; aspect-ratio-aware feed photos and videos; a feed cold-start reconciler that fixes "relay connected but feed empty" and reduces the need to pull-to-refresh; crash-safe drafts; and fixes for mention accuracy, draft re-sync, and follow-list freshness.

### Added
- **Zaps Only Mode**: New Settings > Appearance toggle (default off) that removes likes and reactions throughout the app — feed action bars, engagement counts, the Relay "Likes" tab, and reaction push notifications are all hidden/disabled, making zaps the only way to engage and the primary notification signal. Backed by `HavenConfig.zapsOnlyMode`; toggling it re-registers push preferences so the reaction-push override is applied/lifted immediately, and the Likes view auto-routes to Notes when enabled.
- **@-mention Autocomplete (iOS)**: Typing `@` in the composer opens an inline picker that searches people you follow, participants in the current thread, and — via NIP-50 relay search — anyone else. Selections display as readable `@name` tokens, convert to `nostr:` references on publish, and `p`-tag correctly.
- **Swipeable Full-Screen Note Media**: Tapping a photo in a note opens a full-screen pager that swipes across all of that note's images.
- **Media Tab Following/Global Toggle**: The media feed can be filtered between people you follow and global content.
- **Split Notes vs Engagement Filters**: The Relay/Viewer separates note-kind filters from engagement (reactions/zaps/reposts) filters.

### Changed
- **Feed Cold-Start Reliability**: Feed subscriptions are reconciled against relay-readiness and the follow set, fixing "relay connected but Following empty" and greatly reducing the need to pull-to-refresh for the latest posts.
- **Natural Aspect-Ratio Media**: Feed photos and videos size to their natural aspect ratio (with sensible height caps) instead of fixed frames.
- **Crash-Safe Drafts**: In-progress posts are persisted before sending and restored after an interruption; a draft is deleted only once its post actually broadcasts.
- **Relay Tab Sync**: Tagged replies and the owner's own notes are reliably surfaced; pull-to-refresh triggers an immediate network catch-up.
- **Notification Dot**: The relay-activity indicator now lights up only for others' inbound activity, never your own posts/blasts.
- **Immediate Unfollow**: Unfollowing an author immediately removes their notes from the feed.
- **Media Tab Scope**: Shows only your own content.
- **Performance**: Higher in-memory note/event caps for smoother long scroll-back; long-form bodies bounded separately; refreshed default relay list (dead relays dropped).
- **Settings**: Removed the editable Push Server URL field.

### Fixed
- **Mention Accuracy**: Two people sharing a display name no longer collide — each mention resolves to the correct pubkey (previously the inline `nostr:` reference could point at the wrong person). Disambiguated with a per-pubkey token suffix.
- **Draft Re-Sync**: Reopening the composer no longer re-saves and re-syncs an unchanged draft — the saved-content baseline now matches the editor's display form.
- **Orphaned Drafts**: Editing a pending post reuses its backing draft instead of leaving an orphan; `draftId` is now threaded through the edit flow.
- **Follow-List Freshness**: The contact list picks the newest kind-3 by `created_at` rather than the first relay to respond.

## [2.5.1 (7) macOS / 1.1.1 (7) iOS] - 2026-06-08

> **NIP-29 Group Chat, Async DM Sending, WoT Media Filtering & Outbox Relay Model**: NIP-29 relay-based group chat with browse/join/create/admin UI; DM sending is now fully async with optimistic UI; outbox relay model (NIP-65 write relays) improves relay list discovery; media tab filters by Web of Trust; FIPS overlay network Blossom publishing; event publishing reuses the existing feed socket; StatsService simplified to pure delta tracking; and broad thread-safety fixes.

### Added
- **Instant Cold-Launch Feed Restore**: Feed state is persisted to disk on app background/terminate and restored instantly on next cold launch — users see their previous feed immediately with a background top-up from relays, eliminating the blank-screen wait. New `persistCurrentSnapshot()` called from SceneDelegate, AppDelegate, and iOSAppDelegate lifecycle hooks; `startInitialLoad()` entry point in FeedView restores or falls back to a full refresh.
- **Audio Session Management**: New `AudioSessionManager` singleton configures iOS audio sessions so muted video autoplay (`.ambient` + `.mixWithOthers`) never interrupts background music, while unmuted/full-screen playback (`.playback`) properly takes over audio and ignores the hardware mute switch. Session transitions happen on mute/unmute toggle, full-screen entry/exit, and view disappear.
- **Per-Feed Compact Mode**: Compact/condensed view is now independently toggled per feed tab (Following defaults OFF, Discovery/Global/Popular/Media default ON) and stored in `feedCompactModes` dictionary keyed by `FeedMode.rawValue`. The global `useFeedCompactMode` remains as a fallback for feeds without an explicit override.
- **App Icon Picker (iOS)**: New "App Icon" section in Settings > Appearance with `AppIconPicker` view and `AppIconOption` enum. Lets users switch the home-screen icon via `UIApplication.setAlternateIconName`. Foundation for alternate icon variants.
- **External Event Injection**: Events from external relays (e.g. Mac relay sync) are now injected into the local relay via `FeedService.injectExternalEvent()` for cross-session persistence. Filtered to feed-relevant kinds (1, 6, 7, 30023, 9735) and deduplicated.
- **Proof of Work (NIP-13)**: Optional proof-of-work mining is now applied to notes, replies, reactions, reposts, and direct messages before signing. A new Go backend export `MineAndSignEventC` appends a `nonce` tag and SHA-256-hashes the serialized event until the target leading-zero-bit difficulty is met, then signs — with graceful fallback to plain signing after a 10M-attempt safety valve or on error. A new "Proof of Work" Settings section (`ProofOfWorkSettingsView`) exposes per-category enable toggles and difficulty steppers (8–32 bits), backed by `PowPreferences` (defaults: notes 16 bits, reactions/DMs 12 bits, all enabled). Swift `mineAndSignEvent` / `mineAndSignEventAsync` mine locally and fall back to NIP-46 remote signing (no PoW) when no local key is available; DM gift wraps mine PoW with their ephemeral key.
- **Global Search (NIP-50)**: SearchView gains a relay/global toggle. Global mode queries public NIP-50 search relays (`relay.nostr.band`, `relay.noswhere.com`) for notes (kind 1) and profiles (kind 0), deduplicates results across relays via a thread-safe `GlobalSearchCollector`, merges discovered profiles into the shared cache, and returns after a 4-second window. In-flight searches are cancelled on mode switch or cancel.
- **Profile "Tagged" Tab**: ProfileView adds a "Tagged" section listing kind 1/6/30023 notes from other users that mention, reply to, or tag the profile (`#p`), with its own infinite-scroll pagination and tagger-profile display.
- **Condensed Note View**: A persistent compact/condensed layout (32pt avatar, name · time, two-line content, thumbnail) is available in ViewerView via a toolbar toggle (persisted with `@AppStorage`) and applied to FeedView and NoteDetailView reply threads.
- **FIPS Blossom Publishing (macOS)**: New `FIPSDetectionService` detects whether nostr-vpn (nvpn) is running by reading its file-based IPC (`config.toml` + `daemon.state.json`). A new "FIPS" section in Blossom Settings lets users publish their `.fips` Blossom address in their server list (kind 10063). Address source options: owner npub, auto-detected from nostr-vpn, or custom npub. FIPS URL is appended last in the mirror list (clearnet-first per BUD-14). iOS shows VPN detection status and guidance for accessing `.fips` servers.
- **macOS Keyboard Shortcuts**: Cmd+1–6 switches between tabs (Feed, Search, Profile, Relay, Notes, Media), Cmd+, opens Settings, Cmd+N opens Compose.
- **Blossom Media Picker Filters**: The Blossom media picker sheet now has a segmented filter bar (All/Photo/Video/GIF) in the toolbar with empty-state messaging per filter type.
- **Broadcast Button in Thread View**: NoteDetailView toolbar gains a broadcast button to open the EventBroadcastSheet directly from a thread context.
- **Log Level Filter**: LogsView adds a segmented filter picker (All/Info+/Warn+/Errors) to filter displayed log entries by minimum severity. macOS header also shows an inline relay log level picker for the Go process.
- **Responsive Toolbar Menus**: FeedView toolbars use `ViewThatFits` — filters render as inline icon buttons when space permits, collapsing to a single overflow menu on narrow windows/screens. ViewerView and SearchView always render inline (no overflow fallback).
- **Video Shimmer Placeholder**: Inline feed videos now show an animated gradient shimmer with a centered video icon while thumbnails load, replacing the generic `ProgressView` spinner. Thumbnail appearance fades in with a 0.25s ease-out animation.
- **Outbox Relay Model (NIP-65 Write Relays)**: `NostrService` now parses write-side relay URLs from kind 10002 events alongside read relays, cached in `outboxRelays` with disk persistence (`outbox_relays.json`). Outbox URLs are used as hints when fetching a user's kind 10002/10050 metadata, improving discovery for users whose relay lists are hosted on their own write relays.
- **Counterpart DM Relay Inclusion**: `DMService.fetchExternalDMs()` now appends DM relays from conversation counterparts (up to 15 total), so messages published to the other party's preferred DM relays are fetched.
- **NIP-29 Group Chat**: Full relay-based group chat implementation. New `GroupService` manages WebSocket connections to NIP-29 group relays with NIP-42 AUTH, real-time message streaming (kinds 9/11/12), metadata parsing (kind 39000), and admin/member list tracking (kinds 39001/39002). New `GroupModels` defines `GroupIdentifier`, `GroupInfo`, `GroupMember`, `GroupMessage`, `GroupConversation`, and `JoinedGroup` types. Six new views: `GroupListView` (conversation list with unread badges), `GroupChatView` (iMessage-style chat with gradient bubbles, sender avatars, thread/reply kind badges, admin delete), `GroupBrowserView` (relay URL input, saved relay chips, browsable group list with join buttons), `GroupCreateView` (create form with name/about/privacy/closed toggles), `GroupInfoView` (group header, member list with role badges, admin actions, leave/delete), and `GroupEditView` (metadata editing for admins). DMInboxView gains a DMs/Groups segmented picker with context-aware toolbar buttons. Group relay URLs and joined groups persisted in `HavenConfig`; conversations cached per-account to disk. Supports optimistic message sending, account switching with full state teardown/rebuild, and 250ms UI throttling.

### Changed
- **Incremental Feed Row-Data Cache**: Profile updates, likes, zaps, and reposts now trigger targeted row-level cache updates (`reconcileRowDataCache`, `resolveRows`, per-signal handlers) instead of full-rebuild passes. Extracted `RowDataCacheObservers` ViewModifier keeps the main FeedView body within the Swift type-checker's budget. Dramatically reduces frame drops during profile-metadata streaming at boot.
- **Profile Update Signal**: New `ProfileUpdateSignal` struct on `NostrService` publishes a generation counter + affected pubkey set, so views can selectively refresh only changed rows. Fixes a long-standing bug where in-place profile updates (same pubkey, new name/avatar) never refreshed the feed because they don't change `profiles.count`.
- **Feed Scroll Performance**: `ScrollDirectionModifier` now guards redundant `feedScrollingDown` writes — the `onScrollGeometryChange` callback previously published `objectWillChange` on the shared FeedService every frame near the top of the feed (rubber-band bounce), re-rendering the tab bar and every feed row dozens of times per second.
- **Compose/Message Auto-Scroll**: ComposeView and MessageComposerView now wrap content in `ScrollViewReader` and auto-scroll to newly added attachments/images so they're immediately visible without manual scrolling.
- **Blossom Mirror Detection**: `FeedMediaViewer` now checks whether a blob's SHA-256 exists in the local Blossom store instead of matching URL hosts. Shared public CDN media (e.g. `cdn.satellite.earth`) is no longer falsely flagged as "mirrored" when the user has never actually backed it up.
- **Video Thumbnail Optimization**: Condensed/thumbnail contexts pass `allowFullDownload: false` to `generateThumbnail()` so previews extract frames via byte-range requests without downloading entire videos. Shows a video glyph fallback when frame extraction fails without a full download.
- **Notification Banner Padding**: All notification banners (error, zap, follow, media upload, post action, action toast) now apply top padding only when visible, preventing phantom spacing when no notifications are active.
- **Updated App Icon Assets**: Refreshed icon PNGs with reduced file sizes across all resolutions (e.g. 1024x1024 from 1.4MB to 832KB).
- **Orientation-Aware iPad Navigation**: iPad now switches between the sidebar (landscape) and the bottom tab bar (portrait) based on view geometry, instead of always using the sidebar.
- **Media Content-Type Preservation**: `downloadMedia()` now captures the server's HTTP `Content-Type` and prefers it over extension-based guessing — important for hash-based Blossom URLs that lack file extensions. `getMirroredLink()` returns the URL unchanged when it already points at a known mirror, and falls back to `MediaTypeDetector` for extension-less URLs.
- **User-Initiated Blossom Mirroring**: `BlossomService.downloadFromURL` gains a `mirrorToExternal` flag so the "Mirror to Blossom" action pushes the blob to all configured external mirrors (internal/batch pulls stay local-only). ViewerView's media list now shows per-item mirror counts (x/y).
- **Search & Discovery UI**: On iOS, result-type filters and the search-mode toggle moved into a glass toolbar. Trending hashtags and suggested profiles are now cached and refresh-throttled (5s) to stop UI thrashing as the feed streams events.
- **Thread & Compact Styling**: NoteDetailView compact replies use larger avatars (28pt), card-style parent notes, and stronger purple focus highlighting. Compact notes resolve mentions to plain `@name` text via the new `NostrContentFormatter.resolveMentionsPlainText()`, avoiding AttributedString/link overhead in dense layouts.
- **WoT Media Filtering**: The Media tab's "All" filter now shows only media from Web of Trust members (plus the owner's own) instead of every item on the relay. Applies to both note-sourced media and Blossom items. Falls back to showing everything if the WoT graph hasn't loaded yet. ViewerView observes `feedService.wotPubkeys` and refreshes automatically when WoT data arrives.
- **`wotPubkeys` Published**: `FeedService.wotPubkeys` is now `@Published private(set)` so views can reactively filter content by WoT membership.
- **Tagged Media Excluded**: Media from notes that merely `#p`-tag the owner is now filtered out across all media views, reducing spam from unsolicited mentions. The dedicated "Tagged" filter in ViewerView now returns no results.
- **Whitelisted Media Scope**: Whitelisted accounts now see only their own media in the relay media grid (the "tagged by" exemption was removed).
- **Event Publishing Reuses Feed Connection**: `NostrService.publishEvent()` now sends events through the existing feed relay socket (`FeedService.sendToLocalRelay`) instead of opening a temporary WebSocket for each publish — falling back to existing `clients[]` or a temporary client only as a last resort. Eliminates redundant TLS handshakes on every note/reaction/repost.
- **Event Broadcast Fetches from Outbox + Inbox**: `EventBroadcastSheet.fetchFullEvent()` queries both the relay's outbox (`/`) and inbox (`/inbox`) paths and checks `FeedService.rawEventCache` first, fixing broadcast failures for notes from other users stored only in the inbox relay.
- **Account Switch Reconnection**: `NostrService.resetForAccountSwitch()` now rebuilds WebSocket connections for the new account via `reconnectForActiveAccount()`, fixing the yellow→red relay indicator and empty Viewer tab after switching accounts. Stale Combine sinks from the previous account's clients are also cancelled to prevent phantom reconnection attempts.
- **Relay List Fetch Broadened**: `fetchRelayList()` now queries both kind 10002 and 10050 in a single subscription and re-fetches when DM relay data is missing for a pubkey, even if inbox relays are already cached.
- **Profile Update Persistence**: In-place profile edits from ProfileView now trigger `saveProfilesThrottled()` so changes survive app restarts without waiting for the next periodic save.
- **Async DM Sending (NIP-17 & NIP-04)**: `sendNIP17DM()` now updates the UI optimistically with a UUID placeholder, then creates both gift wraps concurrently (`async let`) and publishes via non-blocking `fireAndForgetPublish()` in a background Task. `publishToInbox()` reuses the persistent inbox WebSocket client (zero-latency fast path) instead of opening a new connection per message. `sendLegacyDM()` follows the same optimistic-then-background pattern. Incoming messages from the relay reconcile optimistic placeholders by matching content + sender within a 30-second window.
- **Profile Kind 0 Broadcast**: `publishEvent()` now broadcasts kind 0 (profile metadata) events directly to blastr relays via `broadcastRawEvent()`, since replaceable events don't trigger the Go relay's `StoreEvent` blast path.
- **StatsService Simplified**: Removed all WebSocket-based COUNT queries (`fetchCount`) and the associated retry/floor/baseline logic. Event count now uses pure delta tracking from `RelayProcessManager.eventsStored` against a persisted baseline, eliminating temporary WebSocket connections on every dashboard visit and after feed injection. Removed `feedInjectionComplete` observer.
- **MediaCacheService MainActor Safety**: `RelayProcessManager.addLog()` calls from background contexts are now dispatched to the main actor via `Task { @MainActor in }`, preventing potential threading violations.
- **WebSocket Message Dispatch**: `WebSocketClient.messageSubject.send()` is now dispatched to the main thread, preventing race conditions from concurrent non-main-thread sends to `PassthroughSubject`.
- **Task-Level TLS Challenge Handling**: `WebSocketClient` now implements the task-level `urlSession(_:task:didReceive:)` delegate — iOS delivers WebSocket auth challenges at the task level rather than the session level, fixing TLS certificate trust failures on some iOS versions.
- **LogStore Background Flush**: When the throttle timer isn't running (popover closed), `LogStore.enqueue()` schedules a one-shot flush so entries still appear when the Logs view is reopened.
- **Config/Service Error Logging**: `ConfigService`, `FollowingBackupService`, and `MediaCacheService` now route decode/save/cache errors through `RelayProcessManager.addLog()` (visible in System Logs) instead of silent `#if DEBUG` print statements.
- **RelayProcessManager Buffer Lock Safety**: Replaced manual lock/unlock pairs with `defer { bufferLock.unlock() }` in the stdout pipe handler, preventing potential deadlocks on early return.
- **NostrService OK Response Bounds Check**: Smart broadcast `OK` message parsing checks `json.count >= 3` before accessing array indices, preventing potential out-of-bounds crashes.
- **Log Level Picker Moved**: Relay log level picker moved from Advanced Settings to the LogsView header (macOS) for contextual access alongside the new filter controls.

### Fixed
- **Thread-Safe Event Deduplication (EXC_BAD_ACCESS)**: `seenEventIds` in `NostrService` is now guarded by `NSLock` via `markSeen`/`hasSeen`/`clearSeen` helpers. Eliminates random EXC_BAD_ACCESS crashes from concurrent non-atomic Set mutations between the background `processingQueue` and the main thread.
- **"Loading Notes…" Overlay Stuck Forever**: `fetchNotes()` now counts only subscriptions that are actually opened — skipped URLs (backing off, reconnecting, local relay not ready) no longer inflate `activeSubscriptionCount`. An 8-second watchdog timer (`armFetchWatchdog`) force-clears `isFetching` if subscription EOSEs never arrive.
- **NIP-42 AUTH Signing with Wrong Key**: `DMService` NIP-42 AUTH now passes `forceOwner: true` to `signEventAsync` so the local relay's owner key is always used regardless of the active browsing account.
- **Max Reconnect Slot Leak**: When a relay gives up after max reconnect attempts, its slot is now released from `activeSubscriptionCount` so a dead relay can no longer hold `isFetching` true permanently.
- **Go Relay File Descriptor Leak**: `initRelays` now defers `file.Close()` after copying downloaded relay data, preventing a descriptor leak.
- **Collapsed FAB Tint**: The collapsed iOS tab bar's floating action button now renders with explicit monochrome `foregroundStyle`/`tint` so the glyph color is consistent.
- **Video Shimmer Gradient Clamping**: `VideoShimmerPlaceholder` gradient stop locations are now clamped to `0...1` via `max(0, min(1, ...))`, preventing invalid gradient stops that could cause rendering artifacts when the animation phase overshoots.

### Removed
- **Relay Note Search Bar**: Removed the inline search bar and toggle for local relay notes in ViewerView; global search via SearchView supersedes it.
- **Dashboard Compact Stats Toggle**: Removed the compact-view toggle and compact stats layout from DashboardView — statistics now always render in the full layout.
- **Apple Sign In Identity Backup (Experimental)**: Removed incomplete Apple Sign In integration that was developed as a proof-of-concept for NIP-OAUTH-IDENTITY-BACKUP. Deleted `AppleSignInManager.swift`, `BackupCryptoService.swift`, and `iCloudKeychainService.swift` from codebase. NIP specification and reference implementation preserved in `/nips/` directory for future consideration pending community adoption. Feature was never released to users.
- **Lightning Balance in Profile**: Removed NWC lightning balance display from ProfileView — balance stat cell, inline sats text, `fetchLightningBalance()`, and associated state variables.
- **Log Level in Advanced Settings**: Moved to the LogsView header; no longer in the Advanced Settings section.

## [2.5.1 (6) macOS / 1.1.1 (6) iOS] - 2026-06-04

> **iOS Polish, Account Switching & Reliability Release**: Collapsible iOS tab bar with dynamic FAB, multi-account switcher, push notification settings UI, pure-Swift NIP-46 fallback, DM relay routing, macOS graceful shutdown, and font system standardization.

### Added
- **Collapsible iOS Tab Bar**: Bottom tab bar dynamically collapses when scrolling down the feed and expands when idle. A contextual floating action button appears in the collapsed state — compose button on the feed tab, relay dashboard on the relay tab. Tap the profile avatar to expand or access the account switcher. Smooth spring animations throughout.
- **iOS Account Switcher**: Multi-account management sheet accessible from the collapsed tab bar or iPad sidebar. Shows avatar, display name, and account type (Owner/Whitelisted) with colored rings. Tap to switch between accounts.
- **Push Notification Settings View**: New per-account notification preferences screen with toggles for global push notifications and granular per-account controls for mentions, replies, DMs, zaps, reactions, and reposts. Accessible from Settings.
- **Swift NIP-46 Handshake Fallback**: Pure-Swift NIP-46 connection path (`SwiftNIP46Handshake`) for iOS setup wizard when the Go-based relay pool subscription fails. Performs direct WebSocket handshake with `connect` + `get_public_key` RPC exchange, NIP-44 encryption, and 45-second timeout.
- **DM Relay Configuration**: Go backend now accepts a `DmRelays` field for DM-specific relay routing separate from note import relays. Subscriptions deduplicate across import and DM relay sets.
- **iOS Background Processing**: Added `processing` background mode so the relay stays alive when the app is backgrounded. `iOSAppDelegate` registers background tasks and restarts the relay on foreground if it crashed.
- **Settings Tab in iOS Sidebar**: New dedicated Settings tab (index 5) in the iPad sidebar navigation with embedded `SettingsView` in a navigation stack.

### Changed
- **Mac Relay Auto-Inclusion**: When a Mac relay is configured, it is now automatically included in feed relays, blastr relays, import relays, and Blossom mirrors. Previously, Import, Blastr, and Blossom Mirror required manual opt-in toggles; feed relays had no Mac relay integration at all. The Settings UI now shows all derived addresses as always-on indicators instead of toggles.
- **macOS Graceful Shutdown**: `AppDelegate.applicationWillTerminate()` now stops `NetworkSyncService` and `NIP46Service` before relay shutdown, and uses a semaphore to block app termination until the Go relay flushes databases (3-second timeout). Prevents data corruption from premature process exit.
- **NIP-46 Timeout Extensions**: Connect RPC timeout increased from 30s to 60s for slow networks. Added 30-second `GetPublicKey` timeout to prevent indefinite hangs. Enhanced logging with signer pubkey prefixes, request details, and success confirmation.
- **Font System Standardization**: New `.appSystem(size:weight:design:)` factory and convenience properties (`.appHeadline`, `.appSubheadline`, `.appCaption`, `.appCaption2`, `.appTitle2`) in `Theming.swift`. Replaces hardcoded `.system()` calls across MenuBarView, iOS tab bar, DraftPickerView, and other views, enabling text scale support via `config.textSizeScale`.
- **iOS Navigation Bar Cleanup**: Added `.toolbarBackground(.hidden, for: .navigationBar)` to SearchView, ProfileView, MediaTabView, and ViewerView in iPad sidebar for a seamless navigation experience.
- **DM Foreground Sync**: Replaced `MacRelaySyncService.syncIfConfigured()` with `DMService.syncOnForeground()` for targeted DM-only sync on iOS foreground transitions.
- **64-bit Only iOS**: Changed `UIRequiredDeviceCapabilities` from `armv7` to `arm64`, dropping 32-bit device support.
- **Legacy NIP-49 Logging**: Downgraded NIP-49 decryption errors from `.error` to `.debug` level, preventing spurious log noise during account import when testing legacy credentials.
- **NIP-46 Config Fallback**: When no `activeAccountNpub` exists (initial setup), NIP-46 detection now falls back to flat `signingMode`, `nip46SignerPubkey`, and `nip46BunkerURI` config fields.

### Fixed
- **NIP-46 Initial Account Setup**: Config fallback for NIP-46 detection when no active account exists prevents setup wizard failures during first account creation via bunker URI.

### Removed
- **MacRelaySyncService**: Dedicated Mac relay sync service deleted; functionality consolidated into `DMService.syncOnForeground()`.

## [2.5.1 (4) macOS / 1.1.1 (4) iOS] - 2026-06-02

> **Theme, Accessibility & Drafts Release**: Adds OLED dark theme with semantic color system overhaul, scalable text sizing, auto-saving compose drafts to the local relay, NIP-65 relay list publishing, profile picture prefetching, and multiple crash/race condition fixes.

### Added
- **Draft Auto-Save**: Compose content is automatically saved to the local relay as kind 31234 (NIP-37) parameterized replaceable events with a 1.5-second debounce. Drafts survive app crashes, accidental dismissals, and app restarts. A draft picker badge appears next to the Cancel button in the compose toolbar (iOS and macOS) when drafts exist, showing draft count and allowing tap-to-restore. Drafts preserve full reply/quote context (NIP-10 e-tags, q-tags, p-tags) and are deleted automatically when the post is published. New `DraftService` singleton handles save/fetch/delete operations on the `/private` relay endpoint.
- **NIP-65 Relay List Publishing**: New `publishRelayList(forNpub:)` method signs and posts kind 10002 events advertising the local relay as the account's inbox. On iOS, the Mac relay URL is also included. Per-account "Publish Inbox Relay" toggle in Settings under a new "Relay List (NIP-65)" section. Relay lists are automatically published for all enabled accounts on app launch.
- **OLED Dark Theme**: New `useOLED` config option with "OLED Dark Theme" toggle in Settings > Appearance. When enabled, all semantic platform colors (`platformWindowBackground`, `platformControlBackground`, `platformSecondaryGroupedBackground`, `platformTertiaryGroupedBackground`, `platformSeparator`) return pure black or near-black variants. Three new semantic colors added: `platformCardBackground`, `platformCardBorder`, `platformConsoleHeaderBackground`. DM bubbles adapt with darker fills and subtle border strokes.
- **Text Size Accessibility**: New `textSizeScale` config option (0.8x–1.6x) with a slider in Settings. `Font.appSystem(size:weight:design:)` factory in `Theming.swift` scales all text sizes by the configured factor. Applied across ComposeView, DMInboxView, DMThreadView, FeedView, MessageComposerView, NoteDetailView, and ProfileView.
- **Profile Picture Prefetch Service**: Background service that downloads profile pictures for all followed accounts once per day over Wi-Fi. Configurable via "Prefetch Profile Pictures" toggle in Settings > Advanced > Media.
- **Centralized Media Format Definitions**: New `SupportedMediaFormats.swift` provides a single source of truth for all supported media extensions, MIME-to-extension and extension-to-MIME lookup, and precompiled regex patterns. Replaces scattered inline definitions across AnimatedImage, FeedMediaView, FeedMediaViewer, MediaItem, NostrEvent, NostrService, and ComposeView.
- **iOS App Delegate**: New `iOSAppDelegate.swift` for push notification registration and lifecycle events. `HavenApp.swift` now conditionally uses `@UIApplicationDelegateAdaptor` on iOS.
- **Blossom Directory Watcher**: `BlossomDirectoryWatcher` uses `DispatchSource` to monitor the Blossom directory for filesystem changes (e.g., iPhone uploads to Mac relay), posting debounced `blossomDirectoryChanged` notifications for UI refresh.
- **MacOS "Notes" Sidebar Tab**: New sidebar tab showing `ViewerView` for browsing notes and media, separating it from the "Relay" tab which now shows `DashboardView`.

### Changed
- **Semantic Color System Overhaul**: Replaced 20+ hardcoded color values (`Color(red: 0.08, green: 0.08, blue: 0.1)`, `Color(red: 0.12, ...)`, `Color.white.opacity(0.04)`, etc.) with semantic platform color constants from `PlatformCompat.swift` across DashboardView, FeedView, FeedDashboardSheet, DMInboxView, DMThreadView, ProfileView, MessageComposerView, MenuBarView, CustomZapSheet, NoteDetailView, and SettingsView. All colors now support OLED mode.
- **WoT Cache-Aware Startup**: `LoadFromCache()` now returns a boolean indicating success. When the WoT cache is valid, `MarkReady()` is called immediately and the full network rebuild is skipped, making relay startup near-instant with a warm cache.
- **Blastr Broadcasting Moved Server-Side**: `postEvent()` no longer manually connects to each Blastr relay from Swift. The Go relay's `StoreEvent` handler triggers its own blast distribution, eliminating duplicate connections.
- **Event Broadcast Sheet Per-Relay Status**: Each relay in the broadcast sheet now shows a live status indicator — spinner while pending, green checkmark on success, red X on failure — with a summary showing "Broadcast to X/Y relays".
- **Build Script Source Change Detection**: Both `build_haven.sh` and `build_haven_ios.sh` now compute a SHA-256 checksum of Go source files; if unchanged, compilation is skipped entirely. The iOS script also factors in `PLATFORM_NAME` to rebuild when switching between simulator and device.
- **Video Attachment Loading**: `loadVideoItem()` rewritten from callback-based to `async/await`. Added a fallback path: if `ImportedVideoFile` transfer fails (HEVC transcoding, iCloud items), falls back to raw `Data` transfer written to a temp file. Video detection now scans all `supportedContentTypes` instead of just `.first`.
- **Blossom Upload Reliability**: Added `saveToLocalRelay(fileURL:...)` file-based variant for streaming large video uploads. Both upload paths now call `ensureRelayReady()` before uploading and include explicit `Content-Length` headers for BUD-02 compliance.
- **NoteDetailView Thread Navigation**: `focusedNote` falls back to `parentNotesCache` when the feed service doesn't have the note. Parent notes are cached so navigation within deeply nested threads works correctly.
- **MacOS Sidebar Reorganization**: Settings promoted to a proper sidebar tab (replacing gear icon button). Relay status indicator shows "Syncing" state during WoT sync.
- **SilentPaymentsKit Compiler Warnings**: Fixed 7 instances of `var` → `let` for immutable values, marked `ctx` as `nonisolated(unsafe)`, and suppressed unused variable warnings across 7 files.
- **`broadcastRawEvent()` Callbacks**: Now accepts an optional `onRelayResult` callback reporting per-relay success/failure with OK message parsing. Timeout increased from 2s to 10s.

### Fixed
- **NIP-46 Connection Race Condition**: `connect()` now sets `.connecting` state synchronously before the async task. `ensureConnected()` waits up to 30 seconds for an in-progress connection instead of starting a redundant one that tears down the active Go session.
- **NetworkSync Feedback Loops**: Events are deduplicated by ID (up to 10,000 entries) before injection into the local relay, preventing blast-back cycles.
- **StatsService Double-Resume Crash**: All Combine async continuations are guarded against double invocation with `guard !resumed` checks. Cancellable references are explicitly cancelled after use.
- **Relay Boot State Stuck on "Booting"**: `RelayProcessManager` now explicitly transitions to `.running` state when boot completes.
- **HEVC/iCloud Video Attachment Failures**: Videos that fail the `ImportedVideoFile` transfer path now fall back to a `Data`-based path, preventing silent attachment failures.
- **Blossom Uploads Before Relay Ready**: Upload functions now wait for the relay to be ready via `ensureRelayReady()`, preventing silent failures during startup.
- **Thread Navigation Losing Focus**: Clicking into parent notes in deeply nested threads no longer shows "note not found" — parent notes are cached and fallback resolution is used.

### Removed
- **EmojiPickerView**: Removed the custom emoji picker component (356 lines) with categories, search, and curated emoji lists.
- **Hardcoded Color Values**: All inline RGB color definitions throughout the codebase replaced by semantic platform color constants.
- **Swift-Side Blastr Broadcasting**: Manual WebSocket connections to Blastr relays from `NostrService.postEvent()` removed; the Go relay now handles distribution.
- **DM_PLAN.md**: Planning document removed (implementation complete).

## [2.5.1 (3) macOS / 1.1.1 (3) iOS] - 2026-06-02

> **Network Performance Release**: Reduces simultaneous TCP/WebSocket connections on app reopen from 12-15 to 2-3 in the first 500ms, targeting 5G/cellular usability.

### Changed
- **Deferred Auxiliary Feed Subscriptions**: Feed subscriptions now send only the primary content filter (kinds 1, 6, 30023) on initial relay connect. Auxiliary subscriptions (mentions, reactions, incoming/outgoing zaps) are deferred until after the primary EOSE arrives per-relay, preventing bandwidth starvation of feed content. Pagination calls continue to send all filters at once.
- **Staggered External Relay Connections**: Local relay connects immediately on feed subscribe; external relays stagger 200ms apart to avoid TCP/TLS handshake storms on cellular connections. Already-connected relays (warm resume) skip the stagger.
- **Extended Network Caching**: Discovery mode now caches the computed `extendedNetworkPubkeys` with a 1-hour TTL, skipping the 75-125+ REQ messages needed to recompute the web-of-trust graph on reopen. Cache is cleared on account switch and restored from disk snapshots.
- **Filtered Notes Change Suppression**: `recomputeFilteredNotes()` now compares the new ID list against the current one and skips the `@Published` assignment when the visible list hasn't changed, preventing unnecessary SwiftUI re-renders and scroll position resets from background buffer flushes.
- **Precomputed Parent-Is-Next Set**: `FeedService.parentIsNextNote` is now precomputed during filtering, eliminating per-row `Array(enumerated())` lookups in the view's `ForEach`.
- **Single-Assignment Batch Inserts**: Note batch inserts in `flushNotes()` now build the sorted/capped array locally and assign to `notes` once, reducing `objectWillChange` notifications from multiple mutations to a single publish.
- **Two-Phase Boot Status**: Relay boot now transitions through three visual states — yellow "BOOTING" while the Go process initializes, orange while Web of Trust graph syncs, and green "ONLINE" once inbox subscriptions are active. `RelayProcessManager.isWotSyncing` tracks the intermediate phase.
- **DashboardView Single Stats Refresh**: Dashboard `onAppear` now performs a single combined refresh (disk sizes + relay COUNT) when the relay is ready, instead of firing a disk-only refresh and a full relay refresh simultaneously. The `onChange(isBooting)` handler remains unchanged for post-boot refresh.
- **ProfileView Cache-Respecting Fetch**: Profile `onAppear` now calls `fetchMissingProfiles` without forcing a refetch, respecting the in-memory profile cache instead of opening 3 Blastr relay connections on every profile view appearance. Pull-to-refresh still force-fetches.

### Added
- **ensureRelayReady() Helper**: New async helper on `RelayProcessManager` that polls until the relay is running and no longer booting, with a configurable timeout (default 15s), preventing race conditions where services attempt relay operations before the process is ready.

### Removed
- **Metrics Timer**: Removed the 2-second repeating metrics timer from `RelayProcessManager` — `updateMetrics()` had an empty body and metrics were already tracked via relay log parsing in `collectStateChanges()`.
- **Warm-Up Relay Connections**: Removed `warmUpExternalRelays()` and the `warmClients` pool from `FeedService`. These pre-opened bare WebSocket connections to external relays during contact list loading, but `subscribeToAllRelays()` created its own connections immediately after, making the warm-up redundant.

## [2.5.1 (2) macOS / 1.1.1 (2) iOS] - 2026-06-01

### Added
- **Notes Tab in Mac Sidebar**: Added dedicated "Notes" tab to the macOS sidebar navigation, displaying the full ViewerView interface for browsing notes and media. Provides quick access to the complete notes viewer experience directly from the sidebar, positioned between Relay and Media tabs.
- **Blossom Directory Watcher**: New filesystem monitoring service (`BlossomDirectoryWatcher`) that detects when external devices (e.g., iPhone) upload media blobs to the Mac relay. Automatically triggers media grid refresh when new files appear in the blossom directory, with debounced notifications to prevent excessive reloads.
- **Network Sync Event Deduplication**: `NetworkSyncService` now tracks injected event IDs (up to 10,000) to prevent blast feedback loops where events are received back from blastr relays and re-injected into the local relay, causing infinite broadcast cycles.

### Changed
- **MenuBarView Navigation**: Enhanced sidebar tab structure with notes-specific navigation, integrating ViewerView with proper environment object configuration for relay manager, config service, and Nostr service.
- **Blastr Broadcasting Architecture**: Removed Swift-side blastr relay broadcasting from `NostrService.publishEvent()`. All blastr broadcasting now happens server-side in the Go relay's `StoreEvent` handler, eliminating the double-blast feedback loop where events were sent to blastr relays twice (once from Swift, once from Go).
- **ViewerView Blossom Auto-Reload**: Media grid now subscribes to `blossomDirectoryChanged` notifications and starts filesystem watcher on load, enabling real-time media grid updates when external devices upload to the relay.
- **ViewerView Media-Only Mode Guards**: Added guards to prevent notification-driven view mode changes when `ViewerView` is initialized in media-only mode (e.g., from MediaTabView), preventing accidental tab switches.

### Fixed
- **QuickTime MIME Type Detection**: Fixed file type detection order in `RelayProcessManager.detectMIMEType()` to check QuickTime (`qt  `) brand before HEVC brands. macOS screen recordings use HEVC in MOV containers and were incorrectly classified as `video/mp4` instead of `video/quicktime`.
- **Stats Service Race Conditions**: Fixed multiple race conditions in `StatsService.fetchKindCounts()` async continuation handling. Added proper `guard !resumed` checks and explicit cancellable cleanup to prevent double-resume crashes and dangling subscriptions.

### Removed
- **DM_PLAN.md**: Removed planning document (implementation complete).

## [2.5.2 macOS / 1.1.2 iOS] - 2026-06-01

> **Stability & Polish Release**: Seven-phase hardening pass covering debug log hygiene, race condition fixes, user-facing error notifications, delete confirmations, network resilience, accessibility, and a localization foundation for future translation support.

### Added
- **Error Notification Banner**: New `ErrorNotificationBanner` component surfaces errors that were previously swallowed silently — covers 7 failure paths across zap validation, relay connections, Cashu operations, and media uploads. Displayed as a top overlay on FeedView, ProfileView, and MenuBarView.
- **Delete Confirmation Dialog**: Deleting a post now shows a confirmation alert before broadcasting a kind 5 deletion event, preventing accidental deletions. Managed through `PendingPostManager`.
- **Like Rollback**: If a like event fails to publish to the relay, the optimistic UI update is rolled back and the heart icon reverts to its unliked state.
- **Localization Foundation (177 strings)**: Extracted 177 user-facing strings from `DMInboxView` (14 keys, `dm.*`), `FeedView` (45 keys, `feed.*`), and `SetupWizardView` (118 keys, `setup.*`) into `String(localized:)` calls with structured dot-notation keys. Created `Localizable.xcstrings` String Catalog with all English translations.
- **Accessibility Labels**: Added VoiceOver labels and values to interactive elements across 6 key views: FeedView, ProfileView, SetupWizardView, DMInboxView, DMThreadView, and ComposeView.

### Changed
- **Debug Log Gating**: All `print()` calls containing sensitive data (private keys, tokens, relay URLs, wallet state) are now wrapped in `#if DEBUG` blocks across all Service files, preventing information leakage in release builds.
- **Network Timeouts**: Added explicit `URLRequest` timeouts to external service calls (Mempool API, LNURL resolution, price fetches, Cashu mint operations) to prevent indefinite hangs on unreachable endpoints.
- **Async Thumbnail Generation**: Video thumbnail generation in feed grid cells moved off the main thread to prevent UI hitches during scroll.
- **Zap Invoice Validation**: `ZapService` now validates bolt11 invoice amounts before paying, rejecting invoices that don't match the requested zap amount.

### Fixed
- **Race Condition in Wallet Data**: Fixed a data race in `CashuService` where concurrent proof state checks could corrupt the in-memory proof set. Operations now serialize through an actor-isolated method.
- **FeedView Accessibility Crash**: Fixed `feedService.isRelayConnected` (nonexistent property) to use `feedService.connectionStatus` for the relay status accessibility value.
- **ViewerView macOS Build**: Wrapped iOS-only `relaySearchBar` reference in `#if os(iOS)` guard — `compactViewContent` is compiled for both platforms but `relaySearchBar` was only defined for iOS.
- **Localizable.xcstrings Not Bundled**: Added the String Catalog to both macOS and iOS targets in the Xcode project so `String(localized:)` calls resolve to English translations instead of showing raw key names.
- **ErrorNotificationBanner Not Compiled**: Added the new `ErrorNotificationBanner.swift` file to both Xcode target build phases (was created on disk but never referenced in the project).
- **LNURL Endpoint URL Fix**: Corrected malformed callback URL construction in `LNURLService` that could drop query parameters on some Lightning address providers.

## [2.5.1 macOS / 1.1.1 iOS] - 2026-06-01

> [!IMPORTANT]
> **Major Feature Release**: This version introduces **NIP-46 Remote Signing** (bunker URI support), a complete **Cashu Ecash Wallet** with NIP-60 relay-backed storage, **Link Preview Cards** for rich URL display in notes, **per-account Push Notification preferences**, and a new **Go-powered Feed Page** for web access to relay content.

### Added
- **NIP-46 Remote Signing (Bunker URI)**: Full support for connecting to remote Nostr signers via `bunker://` URIs. New `NIP46Service` handles WebSocket connections to remote signers with NIP-44 encrypted channels, auth challenge handling, reconnection with exponential backoff, and per-account bunker configuration storage in `HavenConfig`.
- **Cashu Ecash Wallet (NUT Protocol)**: Complete ecash wallet implementing Blind Diffie-Hellman key exchange via the existing secp256k1 backend. Supports depositing (Lightning to ecash via NUT-04 mint quotes), withdrawing (ecash to Lightning via NUT-05 melt), sending/receiving `cashuA` tokens (NUT-00/NUT-03 swap), and proof state checking (NUT-07). Wallet state stored on Nostr relays via NIP-60 (kind 37375 wallet events, kind 7375 unspent proof events, kind 7376 history events) with NIP-44 self-encryption. User-configurable mint URL in Settings. UI features a 4-card layout: balance card, mint info, Lightning Bridge card with segmented Fund/Cash Out picker, and Ecash Tokens card with segmented Send/Receive picker.
- **Ecash Wallet Recovery**: NIP-60 wallet events published to the Haven private relay endpoint (`/private`) for encrypted cross-device sync. On app reinstall or new device setup, tokens are automatically restored from the private relay. Manual "Restore from Relays" button available for on-demand recovery.
- **Link Preview Cards**: New `LinkPreviewService` fetches and caches OpenGraph metadata from URLs in notes, with memory and disk caching plus request coalescing. `LinkPreviewCard` component renders rich link previews (title, description, image) inline within feed notes.
- **Following List Backup & Recovery**: `FollowingBackupService` with automatic contact list snapshots (up to 50 per account). **Relay Recovery** scans for historical Kind 3 events with chronological display and delta badges (green/red) showing follow count changes. Per-user "Re-follow" buttons and full "Restore This List" action. Snapshots stored per-account in Application Support, persisting across reinstalls.
- **Per-Account Push Notification Preferences**: New `PushNotificationSettingsView` with granular toggles per event type (mentions, replies, DMs, zaps, reactions, reposts) and per-account configuration. Automatic re-registration when account list changes, with migration from legacy global notification prefs.
- **iOS Notification Service Extension**: `NotificationServiceExtension` target for background push processing, enabling rich notification content and reliable delivery when the app is not active.
- **Feed Page (Web)**: New Go-powered feed page (`feed_page.go` + `templates/feed.html`) serving recent relay notes as a rendered HTML page for web access to relay content.
- **Blossom Media Cache Service**: New `BlossomMediaCache` service for dedicated media item caching, separate from the general media cache.
- **Media Tab View**: Dedicated `MediaTabView` component for media-only feed display modes.
- **Custom Zap Sheet**: New `CustomZapSheet` component for customizable zap amounts and messages.
- **iOS Landscape Orientation**: Landscape orientation support for media viewers via `AppDelegate.allowLandscape` flag and per-window orientation masking.
- **Compose: Blossom Media Picker**: Add media from Blossom storage directly in the compose flow.
- **iOS Entitlements**: Added `HavenApp-iOS.entitlements` for push notification and background processing capabilities.

### Changed
- **Account Switching Architecture**: New `handleAccountSwitch()` method in `NostrService` performs clean teardown — sends CLOSE messages for active subscriptions, clears Viewer tab event state, resets fetch/subscription tracking, and clears reconnect backoff state. Prevents cross-account data leakage.
- **Feed Performance: Data-Driven FeedNoteRow**: `FeedNoteRow` no longer subscribes to any `ObservableObject`. Removed service subscriptions and replaced them with a pre-resolved `FeedNoteRowData` Equatable struct and a `FeedActions` environment key carrying mutation closures, enabling SwiftUI to skip re-rendering rows whose data hasn't changed.
- **Blossom Mirror Reliability**: External mirror uploads are now awaited (previously fire-and-forget) to prevent silent failures when iOS backgrounds the app mid-upload. Added `mirrorToExternal` parameter to `saveToLocalRelay()` (default `true`) to skip redundant external mirror uploads during bulk sync.
- **Push Server Multi-Account Registration**: Device registration now keys on the composite `(device_token, user_hex_pubkey)` pair instead of `device_token` alone, allowing a single device to register multiple Nostr accounts for independent push notifications.
- **Push Server nostr-sdk Migration**: Updated `NostrMonitor` to use the current nostr-sdk Python API (`fetch_events`, `RelayUrl.parse`, `Timestamp.from_secs`, `tags().to_vec()`) replacing deprecated `get_events_of` and `EventSource` methods.
- **Push Server Self-Notification Filter**: The push server now discards the event author from the affected-users set before sending notifications, preventing users from receiving push alerts for their own events.
- **Push Server Badge Reset**: Added endpoint for resetting notification badge counts.
- **Push Server Health Monitoring**: Added uptime tracking and enhanced logging with account hex prefix identification.
- **HavenConfig Model Extensions**: Added `autoplayVideos` (Bool, default true), `cacheTTLDays` (Int, default 7), Cashu mint URL configuration, NIP-46 signing mode and remote signer fields, and per-account notification preferences dictionary.
- **NostrService Config Observer**: Separated config observer (`configCancellable`) from general cancellables to preserve across account resets. Added `lastForegroundReconnectTime` tracking to prevent redundant refreshes.
- **Account Credential Fallback**: Removed automatic fallback to owner key for whitelisted accounts, ensuring proper credential isolation between accounts.
- **iOS AppDelegate**: Added `PendingNotificationAction` queuing system for deep linking before relay is ready, with `dispatchAction()` for replaying queued notifications after setup.
- **Dashboard: Storage Breakdown**: Added "Storage Used" and "Media Cache" breakdown actions with proper iOS Share Sheet integration (SwiftUI wrapper instead of direct `UIActivityViewController`).
- **Compose: Account Switcher**: Account switching available via avatar context menu in the compose view.

### Changed
- **Viewer Toolbar Consolidation (iOS)**: Merged the search button and content filter buttons into a single trailing toolbar item with a divider separator, reducing toolbar clutter.
- **README Features Documentation**: Expanded the README features section with categorized subsections (Core, Messaging, Payments, Feed & Content, Media, Social, Notifications, Infrastructure) covering all current capabilities.

### Fixed
- **Custom Zap Sheet Not Appearing**: Fixed long-press on the zap icon not opening the CustomZapSheet due to a SwiftUI gesture conflict — `Button` was intercepting the touch before `onLongPressGesture` could fire. Replaced `Button` with explicit `onTapGesture`/`onLongPressGesture` handlers in FeedView and ProfileView.
- **MirrorService iOS Build**: Added conditional `UIKit` import so MirrorService compiles on iOS where `UIApplication` is required for background task registration.
- **iOS Backup File Importer**: Consolidated duplicate `.fileImporter` modifiers into a single modifier with a state-driven import type, fixing potential SwiftUI presentation conflicts.
- **Feed Filter Immediate Recompute**: Toggling reposts or replies in the toolbar now immediately calls `recomputeFilteredNotes()` for instant visual feedback.

### Removed
- **DM_PLAN.md**: Removed planning document (no longer needed).

## [2.5.1 macOS / 1.1.1 iOS] - 2026-05-29

### Removed
- **On-Chain Zap Display**: Removed on-chain zap badges from feed items and note detail views, along with all `onchainZapEventIds` tracking and persistence in FeedService.
- **On-Chain Wallet Tab**: Removed the On-Chain tab from the Wallet view. The wallet now opens directly to Lightning with no tab picker.
- **Silent Payment Address Display**: Removed Silent Payment (`sp1...`) address derivation and display from profile views.
- **Silent Payment Scan Service**: Removed `SPScanService`, `SPStoredUTXO` model, and `SilentPaymentService` — no longer scanning for or tracking SP notifications via NIP-17 gift wraps.
- **On-Chain Profile Section**: Removed Bitcoin (Taproot) address display, balance fetching, on-chain stat cell, and the experimental/privacy warning banner from profile views.
- **On-Chain Toolbar Buttons**: Removed the Bitcoin on-chain wallet button from profile toolbars (iOS and macOS).
- **SilentPaymentsKit Usage**: Removed all `import SilentPaymentsKit` from app code (DMService, CashuService). The framework remains in the repo but is no longer referenced by the app.

> **Note:** Bitcoin sweep functionality remains available in Settings > Advanced.

## [2.5.1 macOS / 1.1.1 iOS] - 2026-05-28

### Added
- **Following List Backup & Recovery**: New "Following Backup" settings section with two recovery mechanisms. **Relay Recovery** scans local and external relays for all historical Kind 3 contact list events, displaying them chronologically with follow counts and delta badges (green/red) showing how each differs from the current list. Tapping a recovered event shows a diff with "No Longer Following" and "Added Since" sections, with per-user "Re-follow" buttons and a full "Restore This List" action that republishes the contact list to relays. **Automatic Snapshots** capture the contact list locally whenever it changes, retaining up to 50 per account, with the same diff and restore UI. Snapshots are stored per-account in Application Support and persist across app reinstalls.

### Changed
- **Account Switch Performance: Seed Contact Lists**: Cold-loading a new account now seeds the follow set from `FollowingBackupService`'s persisted disk snapshots and routes through the warm `topUpFromRelays()` path instead of the sequential `refresh()` chain, eliminating up to 50 seconds of spinner on first visit to an account.
- **Account Switch Performance: Disk Feed Snapshots**: Feed state (up to 200 notes, follow set, engagement stats) is now persisted to disk per-account via a new `DiskFeedSnapshot` struct, so switching accounts after app restart restores the cached feed instantly instead of cold-loading from relays. Snapshots expire after 7 days.
- **Account Switch Performance: Incremental View Updates**: Removed the `.id(activeAccountHexPubkey)` modifier from `FeedView` that was forcing a full teardown and rebuild of 50+ view nodes on every account switch. SwiftUI now diffs the feed list incrementally via `@Published` state changes. Scroll-to-top is handled by an explicit `.onChange` handler.
- **Feed Performance: Adaptive Flush Interval**: `BackgroundAccumulator` now uses a 0.2s flush interval during initial feed load (for faster content display) and 0.5s at steady-state (to reduce main-thread pressure).
- **Feed Performance: Smarter Engagement Dedup**: The `seenEngagementIds` set now evicts roughly half its entries when the 20K cap is hit, instead of clearing entirely, reducing the window where duplicate engagement events slip through.
- **Blossom Mirroring BUD-02 Compliance**: Unified all media import/mirror paths to use the spec-compliant BUD-02 `PUT /upload` endpoint with signed kind 24242 auth events. `downloadFromURL` and `downloadFromMirrors` previously wrote blobs directly to the filesystem, bypassing the local relay's upload API. Both now route through `saveToLocalRelay`, which performs a proper HTTP PUT with Nostr auth to the local relay. Added `mirrorToExternal` parameter to `saveToLocalRelay` (default `true`) to skip redundant external mirror uploads during bulk sync operations.

### Fixed
- **iOS Go Library Build Failure**: Fixed `cshared.go` import path for the `wot` package (`github.com/bitvora/haven` → `github.com/barrydeen/haven`) to match the local `go.mod` module declaration, resolving the "no required module provides package" error that prevented iOS builds.
- **iOS Feed Toolbar Circle Backgrounds**: Added `.buttonStyle(.plain)` to all iOS feed toolbar buttons (connection dot, media mode toggles, autoload/reposts/replies toggles) to prevent iOS from applying automatic circular button backgrounds that clashed with the app's theme color.

## [2.5.1 macOS / 1.1.1 iOS] - 2026-05-27

> [!IMPORTANT]
> **Cashu Ecash & DM Polish Release**: This version introduces a full **Cashu ecash wallet** with NIP-60 relay-backed storage, a thorough **DM UI overhaul** with gradient bubbles and unread indicators, a **120fps feed performance overhaul** that eliminates cascading SwiftUI re-renders for buttery-smooth ProMotion scrolling, and a new **Feed Dashboard** providing a centralized control panel for feed management.

### Added
- **Feed Dashboard**: Replaced the green connection dot's Relay Status sheet with a full Feed Dashboard. Matches the relay dashboard's dark console aesthetic with a pulsing connection indicator, 4-card statistics grid (feed notes, following count, pending posts, hidden/filtered count), tappable feed mode selector cards (Following/Discovery/Global/Media), content filter toggles (show reposts, show replies, auto-load new posts), noise filtering summary (blocked/blacklisted user counts, active spam filter), feed relay health list with per-relay connection status, and quick action buttons (refresh, force reload, load pending). Preserves Mac Relay Sync and Media Mirroring controls from the previous sheet.
- **Cashu Ecash Wallet**: Full Cashu (NUT protocol) ecash wallet accessible via a brown banknote icon on the profile toolbar. Implements Blind Diffie-Hellman key exchange using the existing secp256k1 backend from SilentPaymentsKit. Supports depositing (Lightning to ecash via NUT-04 mint quotes), withdrawing (ecash to Lightning via NUT-05 melt), sending/receiving cashuA tokens (NUT-00/NUT-03 swap), and proof state checking (NUT-07). Wallet state is stored on Nostr relays via NIP-60 (kind 37375 wallet events, kind 7375 unspent proof events, kind 7376 history events) with NIP-44 self-encryption for cross-device sync and backup. User-configurable mint URL in Settings. The wallet UI features a 4-card layout: balance card, mint info, a Lightning Bridge card with segmented Fund/Cash Out picker for seamless Lightning ↔ Ecash conversion, and an Ecash Tokens card with segmented Send/Receive picker for peer-to-peer token transfers.
- **Ecash Wallet Recovery**: NIP-60 wallet events are now published to the Haven private relay endpoint (`/private`) instead of the outbox relay, ensuring encrypted proof data persists on infrastructure you control. On app reinstall or new device setup, tokens are automatically restored from the private relay. A manual "Restore from Relays" button is available in the ecash balance card for on-demand recovery.
- **Search: npub Direct Lookup**: Typing or pasting an `npub1...` address in the search bar now instantly resolves it to a profile without a relay round-trip, using local Bech32 decoding. Also works in the DM Message Composer for sending DMs directly to an npub.
- **DM Inbox: Mark All as Read**: New checkmark button in the DM inbox toolbar (both iOS and macOS) to mark all conversations as read in one tap.
- **DM Inbox: Unread Indicators**: Conversation rows now show a purple dot badge on the avatar when unread messages are present, with bolder name text for unread conversations.
- **Profile: DM Unread Badge**: The DM/messages button on the profile toolbar now shows a red dot indicator when there are unread conversations.
- **Bitcoin Sweep Privacy Disclaimers**: Added two additional warning pages before the sweep flow with large-text warnings about not sending to hardware wallets or exchanges, explaining that on-chain links between Bitcoin and Nostr identity are permanent and irreversible.
- **Profile: Bitcoin Address Privacy Warning**: Added an "EXPERIMENTAL" badge and privacy warning above the Bitcoin address display, advising users to use Silent Payments for better privacy to avoid publicly linking Bitcoin activity to their Nostr identity.
- **iOS Export Share Sheet**: Dashboard JSONL and Blossom exports on iOS now use a proper SwiftUI `ShareSheet` wrapper instead of directly presenting UIActivityViewController, fixing potential presentation conflicts.
- **Push Notification Settings**: New dedicated settings view for configuring push notification preferences per event type (mentions, DMs, zaps, reactions) with per-account granularity.
- **iOS Notification Service Extension**: Added `NotificationServiceExtension` target for processing push notifications in the background, enabling rich notification content and reliable delivery when the app is not active.

### Changed
- **Feed Performance: Data-Driven FeedNoteRow**: `FeedNoteRow` no longer subscribes to any `ObservableObject`. Removed all four service subscriptions (`FeedService`, `NostrService`, `ConfigService`, `PendingPostManager`) and replaced them with a pre-resolved `FeedNoteRowData` Equatable struct and a `FeedActions` environment key carrying mutation closures. SwiftUI can now skip re-rendering rows whose data hasn't changed, eliminating the single biggest bottleneck for 120fps scrolling.
- **Feed Performance: Cached Filtered Notes**: Moved the per-frame O(n) inline filter from FeedView's body into a cached `filteredNotes` property on `FeedService`, recomputed only when notes, feed mode, or display config (showReposts/showReplies/blocked) actually change.
- **Feed Performance: NostrContentFormatter Caching**: Regex patterns (`npub`, `nprofile`, `note`, `nevent`) are now compiled once as static constants instead of per-call. Formatted `AttributedString` results are cached via `NSCache` so repeated renders of the same content are O(1).
- **Feed Performance: Equatable Models**: Added `Equatable` conformance to `FeedProfile` and `NoteStats`, enabling SwiftUI to skip unnecessary diffing and re-renders.
- **Feed: Infinite Scroll**: Replaced the manual "Show earlier" button with an automatic infinite scroll sentinel that triggers `loadMore()` when the user scrolls near the bottom.
- **Profile Feed: Infinite Scroll**: Profile note feeds now paginate automatically. Scrolling to the bottom sends a new relay subscription with an `until` timestamp cursor to fetch older notes.
- **Feed Actions DRY Factory**: All FeedNoteRow call sites (FeedView, NoteDetailView, ProfileView, MenuBarView) now use `FeedActions.make(feedService:nostrService:)` instead of duplicating ~70 lines of closure construction.
- **NIP-17 Gift Wrap Architecture**: Separated rumor p-tags (actual conversation participants) from the gift wrap recipient. `createGiftWrap` now takes explicit `rumorPTags` and `giftWrapRecipient` parameters, enabling self-copy gift wraps to correctly preserve conversation partner identity in the rumor layer. `unwrapGiftWrap` now returns rumor tags alongside content for proper counterparty resolution.
- **NIP-17 Sender Verification**: Added seal-to-rumor pubkey verification during gift wrap unwrapping — if the seal's pubkey doesn't match the rumor's pubkey, the message is rejected as a potential impersonation attempt.
- **DM Counterparty Resolution**: Self-copy messages now determine the conversation partner from the rumor's p-tags (finding the first pubkey that isn't the user's own) instead of relying on the gift wrap's outer p-tag, which always points to self for copies.
- **DM Inbox Empty State**: Redesigned with concentric purple gradient circles, dual-tone icon, and improved copy directing users to the compose button.
- **DM Thread UI Overhaul**: Message bubbles now use gradient backgrounds (purple gradient for sent, dark gray for received) with asymmetric corner radii (small radius on the sender's side). Input area redesigned with a pill-shaped text field, circular purple send button, and a compact inline protocol selector replacing the previous toggle buttons. Message width is now responsive (75% of container) instead of fixed at 280pt.
- **Message Composer UI Refresh**: Send action changed from an icon-only button to a "Send" capsule with paperplane icon. Cleaner text editor layout, improved image preview with floating X dismiss, and proper hit-testing on placeholder text.
- **Blossom Mirror Reliability**: External mirror uploads are now awaited (previously fire-and-forget) to prevent silent failures when iOS backgrounds the app mid-upload. Both `MirrorService` and `FeedMediaViewer` now request background execution time via `beginBackgroundTask` on iOS.
- **Blossom Download Timeout**: Increased from 30 seconds to 120 seconds to handle large video files that were timing out.
- **DM Conversation Row**: Increased message preview length from 50 to 60 characters. Improved avatar sizing (48pt to 52pt) and spacing.
- **DM NIP-04 Warning Banner**: Softer styling with reduced opacity and more concise copy.
- **NIP-10 Reply Threading**: Replies now construct proper root/reply e-tag markers with relay hints. When replying to a threaded conversation, the root event is identified from the parent's e-tags and tagged separately from the direct reply parent. Thread participant p-tags are accumulated and deduplicated.
- **NIP-25 Reaction Compliance**: Reaction events (kind 7) now include relay hints in e-tags and a `k` tag containing the reacted event's kind, per NIP-25 spec.
- **NIP-18 Quote Post Tags**: Quote `q` tags now include the relay hint and author pubkey as third and fourth entries per NIP-18.
- **Client Tag Scoping**: The client identification tag is now only appended to kind 1 text notes, no longer leaking into DMs, reactions, reposts, and other event kinds.
- **Repost Relay Hint Fallback**: NIP-18 repost e-tags now fall back to the local relay URL instead of an empty string when no feed or blastr relays are configured.
- **Cashu Wallet UI**: Redesigned from 6 separate cards to a compact 4-card layout with segmented pickers. "Lightning Bridge" card combines deposit/withdraw flows; "Ecash Tokens" card combines send/receive. Brown `banknote.fill` SF Symbol replaces the previous icon for a consistent toolbar appearance alongside Lightning and Bitcoin.
- **Profile Toolbar Wallet Icons**: Wallet quick-access buttons (Bitcoin, Lightning, Ecash) now use consistent 18pt sizing with increased spacing to prevent crowding on smaller screens.
- **NoteDetailView Action Bar**: Rewritten from VStack layout with `.subheadline` sizing to HStack capsule pills matching FeedNoteRow (14pt icon, 11pt monospaced count, 32pt height, capsule background). Share and broadcast buttons also received pill styling for visual consistency.
- **Toolbar Icon Size Unification**: Standardized icon sizes across all header toolbars — macOS feed header at 15pt `.semibold`, iOS nav bar toolbar at 16pt `.semibold`, MenuBar narrow header at 16pt `.medium`, note action bar pills at 14pt `.medium`.
- **ViewerView Connection Status**: Replaced the colored circle dot with an `antenna.radiowaves.left.and.right` icon matching the MenuBar relay status style, using the same status color scheme.
- **SilentPaymentsKit Public API**: Made all static methods on `Secp256k1` class public (previously package-internal) so the Cashu wallet can access the BDHKE cryptographic primitives.
- **Ecash NIP-60 Relay Routing**: NIP-60 wallet events (kinds 37375, 7375, 7376) are now published directly to the Haven private relay endpoint (`/private`) instead of the outbox relay root path, which is intended for public social notes. Recovery queries the private endpoint first, then falls back to blastr relays.
- **Ecash Info Sheet**: Rewritten to describe the three-layer payment stack (Lightning, Ecash, On-Chain), the relay-backed storage model using the Haven private endpoint, and practical recovery instructions. Beta banner updated to describe the relay-backed architecture.
- **Push Server Multi-Account Registration**: Device registration now keys on the composite `(device_token, user_hex_pubkey)` pair instead of `device_token` alone, allowing a single device to register multiple Nostr accounts for independent push notifications.
- **Push Server nostr-sdk Migration**: Updated `NostrMonitor` to use the current nostr-sdk Python API (`fetch_events`, `RelayUrl.parse`, `Timestamp.from_secs`, `tags().to_vec()`) replacing deprecated `get_events_of` and `EventSource` methods.
- **Push Server Self-Notification Filter**: The push server now discards the event author from the affected-users set before sending notifications, preventing users from receiving push alerts for their own events.

### Fixed
- **MirrorService iOS Build**: Added conditional `UIKit` import so MirrorService compiles on iOS where `UIApplication` is required for background task registration.
- **iOS Backup File Importer**: Consolidated duplicate `.fileImporter` modifiers (one for JSONL, one for Blossom) into a single modifier with a state-driven import type, fixing potential SwiftUI presentation conflicts when both were attached simultaneously.
- **Feed Filter Immediate Recompute**: Toggling reposts or replies in the toolbar now immediately calls `recomputeFilteredNotes()` for instant visual feedback, instead of waiting for the next SwiftUI render cycle to pick up the config change.

## [2.5.1 macOS / 1.1.1 iOS] - 2026-05-25

> [!IMPORTANT]
> **Feature Heavy Release**: This version introduces three flagship features — **NIP-17 Private Messaging**, an integrated **Bitcoin Wallet** (Lightning + On-Chain), and **Silent Payments (BIP-352)** for privacy-preserving Bitcoin receiving. Push notifications with deep linking are now live on iOS.

### Added
- **NIP-17 Private Direct Messaging**: Full end-to-end encrypted messaging using the NIP-17 gift wrap protocol with NIP-44 (ChaCha20 + HMAC-SHA256) encryption. Three-layer privacy model: rumor (kind 14) → seal (kind 13) → gift wrap (kind 1059) with ephemeral keypairs and randomized timestamps for metadata protection.
- **NIP-04 Legacy DM Support**: Backward-compatible support for legacy NIP-04 encrypted DMs with per-conversation protocol toggle. Orange warning badges indicate weaker NIP-04 messages within a thread.
- **DM Inbox View**: Full conversation list UI with unread count badges, avatar display, message previews, and relative timestamps. NIP-42 authenticated connection to local relay's `/chat` and `/inbox` endpoints.
- **DM Thread View**: Chat bubble interface with right-aligned (own) and left-aligned (counterparty) messages, day grouping, and real-time message arrival via WebSocket subscription.
- **Message Composer**: New conversation creation with user search, npub/hex input validation, and profile preview before sending.
- **DM Relay Routing**: Outgoing DMs are published to recipient's kind 10050 DM relay preferences, with fallback to kind 10002 read relays, ensuring delivery across the fragmented Nostr relay network.
- **Wallet View**: New dedicated Wallet tab with segmented Lightning and On-Chain sub-tabs, consolidating all payment functionality into a unified interface.
- **Lightning Wallet Tab**: Full NWC-powered Lightning wallet with real-time balance display, bolt11 invoice generation with QR codes, invoice payment with amount verification, and Lightning address display.
- **On-Chain Wallet Tab**: Taproot (BIP-341) address display with QR code, balance fetching from Mempool API, and sweep-to-external-wallet functionality with fee estimation.
- **Silent Payments (BIP-352) — Beta**: Privacy-preserving Bitcoin receiving integrated with Nostr. Single static `sp1...` address generates unlimited unique on-chain addresses. Uses sender notifications via NIP-17 gift wraps for instant detection without blockchain scanning.
- **Silent Payment Scan Service**: Listens for NIP-17 notifications containing `txid`, `tweak`, and `blockhash`. Fetches transaction outputs from Mempool API, verifies ownership via `SilentPaymentsKit`, and stores per-output spend keys in Keychain with hardware-backed security.
- **Silent Payment Sweep**: Sweep all discovered Silent Payment UTXOs to an external address with selectable fee rates (economy/1hr/30min/fast) and real-time fee estimates from Mempool API.
- **Silent Payment Address on Profiles**: Profile views now display the user's `sp1...` Silent Payment address (derived from their Nostr pubkey) with copy-to-clipboard support.
- **SPStoredUTXO Model**: Persistent UTXO tracking with transaction ID, output index, taproot key, amount, sender pubkey, BIP-352 label, and sweep status.
- **Push Notifications (APNs)**: Native iOS push notification support for DMs (kind 1059/4), mentions (kind 1), and zaps (kind 9735) with deep linking — tap a notification to jump directly to the relevant view.
- **Remote Push Server**: Optional Mac Mini APNs forwarding server support with device token registration for reliable notification delivery when the app is backgrounded.
- **NIP-44 C Bridge**: Added `EncryptNIP44C` and `DecryptNIP44C` exports to the Go C-shared library, enabling Swift to call Go's NIP-44 implementation for DM encryption.
- **Paste Media to Blossom**: New "Paste" button in the Media viewer toolbar that uploads clipboard content directly to Blossom storage. Supports pasting images (PNG, TIFF, JPEG) from the clipboard or pasting a URL to download and mirror the remote file — with upload progress notifications and error feedback.
- **Clipboard Read APIs**: Cross-platform `getString()`, `getImageData()`, and `hasImage()` clipboard utilities in `PlatformCompat` for paste functionality.
- **Blossom BUD-06 Preflight**: Before uploading to mirror servers, sends preflight requests to check acceptance, preventing wasted bandwidth on rejections.

### Changed
- **ProfileView Overhaul**: Added DM button, wallet quick-access links (Lightning and On-Chain), Silent Payment address display, and removed ZStack wrapper in favor of a cleaner ScrollView-first layout.
- **ViewerView DM Integration**: Messages tab integrated into the Viewer for macOS, providing quick access to the DM inbox alongside existing Notes/Likes/Zaps tabs.
- **MenuBarView**: Auto-starts DM service on appear, moves notification banners to top-level overlay, cleaner menu checkmarks.
- **iOS ContentView**: Auto-starts DM service, requests push notification permissions on launch, top-level notification banner overlay, improved iPad split view.
- **NWCService Extended**: Added `makeInvoice` and `getBalance` request types to support the Lightning wallet tab's receive and balance display features.
- **NostrService DM Relay Lists**: Now tracks kind 10050 (NIP-17 DM relay preferences) for outgoing DM routing with fallback chain to kind 10002 and default relays.
- **Web of Trust Cache TTL**: Extended from 24 hours to 72 hours to reduce relay load during WoT graph fetching.
- **ZapNotificationBanner Elevated**: Moved from individual view overlays (FeedView, NoteDetailView) to a single top-level overlay in the root container for consistent display.
- **Video Player Cache Eviction**: Players that fail to load are now evicted and recreated on retry, with improved MIME type handling for extensionless video files.

### Fixed
- **NoteDetailView Scroll Performance**: Removed conflicting z-index overlays that caused scroll jitter on iOS.
- **Feed Menu Icons**: Removed empty icon placeholders from feed mode menu items for cleaner presentation.
- **Video MIME Detection**: Videos without file extensions now use cached content type from the media service for correct playback initialization.

## [2.5.1 MacOS / 1.1.1 iOS] - 2026-05-25

### Added
- **Feed Media Grid Tab**: Added a dedicated "Media" feed mode with an Instagram-style 3-column grid layout displaying media-containing posts. Supports Following and Global sub-modes with tap-to-open full-screen swipeable carousel and long-press to view note details.
- **Copy Blossom Link Button**: Added a "Copy Link" button next to the "Mirrored to Blossom" badge in the media viewer, allowing quick clipboard copy of the local Blossom URL with animated confirmation feedback.
- **Shared Video Player Pool (`VideoPlayerCache`)**: Implemented a size-limited cache (up to 10 instances) of `AVPlayer` that dynamically fetches, plays, and evicts players based on LRU ordering, solving transition and playback initialization latency.
- **Premium Glassmorphic Video Scrubber & Playback Controls**: Built a custom, floating playback controls console utilizing `.ultraThinMaterial` pill borders. Includes standard seek scrubber, play/pause and mute/unmute buttons, and a monospace track timeline.
- **Hardware Keyboard Shortcuts**: Configured native system key bindings inside the media viewer (`Space` to toggle play/pause, `M` to toggle mute, and `Left`/`Right` arrow keys for 5-second skipping).
- **Conditional Tap Modifier (`onTapGestureIfSome`)**: Added a utility SwiftUI modifier enabling touch interactions to ignore unhandled taps, preventing child gesture conflict and allowing seamless underlying list scrolling.
- **NIP-18 Raw Event Cache**: Added an in-memory cache of raw event JSON strings (capped at 1,000 entries) in `FeedService` for proper NIP-18 repost embedding with full event signatures.
- **Video Thumbnail View**: Added `FeedVideoThumbnailView` for rendering static video thumbnails in grid cells instead of spinning up live players, using `MediaCacheService` cached thumbnails.

### Changed
- **Viewer Filter Buttons Moved to Navigation Bar (iOS)**: The content filter controls (All, My Notes, Tagged, Whitelisted on Notes; Liked/My Likes on Likes; Zapped/My Zaps on Zaps; Upload on Media) have been moved from the inline header area into the trailing navigation bar, matching the icon-button style of the Feed toolbar. Each tab shows contextual SF Symbol icon buttons that turn `havenPurple` when active.
- **Seamless Full-Screen Video Transition**: Integrated video player caching into both inline feed playback and the expanded media viewer to ensure the playing video seamlessly transitions to full-screen from its exact current frame without stopping or restarting.
- **iPad and Wide-Screen Optimization**: Upgraded full-screen video overlay so the floating controls console automatically centers and adjusts dynamically on wide-screen monitors or iPad canvases.
- **Note Feed Swipe Carousel Snapshotting**: Extracted static snapshotted data collections (`gridMediaSnapshot`) when launching the swipe-to-dismiss horizontal `TabView` viewer, preventing layout updates or feed list refreshes from stuttering or resetting the user's swiped view state.
- **Blossom Mirroring Scope Narrowed**: Limited media mirroring to only owner and whitelisted account media, removing the previously included followed accounts' media to reduce storage usage and mirroring time.
- **Thread Depth Collapse Threshold**: Reduced reply thread nesting depth from 5 to 3 levels before showing "Show N more replies" navigation links, improving readability on narrow mobile screens.
- **NIP-18 Repost Targeting**: Repost actions now correctly target the original kind 1 event when reposting a kind 6 repost, use the `rawEventCache` for embedding signed event JSON, and include relay hints in the `e` tag per spec.

### Fixed
- **Blossom Mirroring Spec Compliance**: Fixed standard HTTP Auth headers to use the correct `Nostr` prefix, decoded standard BUD-02 `BlobDescriptor` from server JSON responses for canonical paths, resolved self-signed SSL/TLS verification for localhost, and bypassed HTTPS enforcement for Tailscale/LAN environments.
- **NIP-18 Reposts**: Corrected kind 6 repost embedding to include stringified event JSON within `content` and set clean `e` and `p` tags without legacy root markers.
- **Account Switch Safety**: Discarded contact list queries and loading actions if an active profile shift happens during flight, preventing visual corruption/cross-talk.
- **Full-Screen Video Aspect Ratio**: Tapping a video in the feed now plays it at its native aspect ratio instead of being cropped/zoomed to fill the screen. Horizontal videos no longer appear blown up in the full-screen viewer. Fixed by introducing a `videoGravity` parameter on `InlinePlayerLayer` and using `.resizeAspect` (letterbox) inside `FullScreenVideoPlayer`, while the inline feed cards continue to use `.resizeAspectFill`.
- **Feed Video Loading Black Boxes**: Integrated smooth KVO observer overlays displaying video thumbnails on loading players, fading them out gracefully once the active frame starts rendering (`timeControlStatus == .playing`).
- **Grid Navigation Swipe & Tap Conflict**: Added `.allowsHitTesting(false)` overlays to native AVPlayer view instances, ensuring child layers do not swallow list gestures and letting taps/swipes fall through flawlessly to SwiftUI container controls.
- **Full-Screen Media Viewer Swiping**: Restructured the vertical drag-to-dismiss gesture in `FeedMediaViewer` to ignore horizontal drags when scale is `1.0`, enabling clean horizontal swipe page transitions between images and videos in the `TabView` carousel.
- **Video Swiping and Tap-to-Pause**: Disabled hit testing (`.allowsHitTesting(false)`) on the native video player layer inside `FullScreenVideoPlayer` and introduced a transparent tap-capturing overlay, allowing swipe gestures to bubble up natively to the page controller while keeping tap-to-pause functional.
- **Autoplay Prevention on Media Grids**: Modified media grid cell renderings (in both the Feed Media Tab and user profile grids) to disable autoplay for GIFs and videos when displayed as thumbnail items, resolving performance stutters.
- **Global Feed Sensitive Content Warning**: Overhauled warning flow to display a Sensitive Content Warning confirmation dialog every single time the user clicks or switches to the Global Media Feed, enforcing continuous compliance.
- **Horizontal Swipe Carousel Dismissal**: Fixed sheet presentation conflict in `FeedView` where horizontal swiping triggered immediate page dismiss-and-reappear animations, by transitioning the sheet container to be presented via a simple boolean `isShowingGridMediaViewer` rather than the active selection's identity.
- **Kind 6 Repost Reply Threading**: Fixed `NoteDetailView` to show replies for the original event when viewing a kind 6 repost, and corrected the real-time reply WebSocket subscription to target the original event ID.
- **Repost Status Indicator on Reposts**: The repost button now correctly checks the original event ID for kind 6 notes, preventing the green indicator from not appearing on already-reposted content.
- **Reply Count Grammar**: Fixed "Show N more replies" text to use singular "reply" when there is exactly one child reply.
- **macOS Player Layer Sizing**: Added `layout()` override to `PlayerNSView` to keep the `AVPlayerLayer` frame in sync with the view bounds during resizes.
- **Player Layer Memory Cleanup**: Added `dismantleNSView`/`dismantleUIView` to clear `AVPlayerLayer` player references when views are destroyed, preventing retain cycles.

## [2.5.0 MacOS / 1.1 iOS (Build 3)] - 2026-05-23

### Added
- **Bitcoin Taproot Address Derivation**: Implemented native BIP-341 key-path-only Taproot (P2TR) address derivation from the user's Nostr secp256k1 public key in `haven-go/bitcoin.go`. Uses `btcsuite/btcd` for all cryptographic operations — no external process required.
- **Bitcoin Sweep with On-chain PSBT**: Full Bitcoin sweep flow backed by the Go relay: fetches UTXOs from a self-hosted Mempool instance, constructs and signs a raw Taproot transaction via Schnorr signatures, and broadcasts it over the relay's HTTP bridge. The sweep uses key-path spending (BIP-341 `tapTweakHash`) for minimal transaction weight.
- **Bitcoin Sweep Disclaimer View**: Added `BitcoinSweepDisclaimerView` — a pre-sweep confirmation sheet that loads the wallet's spendable balance live from the Mempool API before the user can proceed, with a loading indicator and error state for failed fetches.
- **Bitcoin Price Service**: New `PriceService.swift` singleton that fetches the live BTC/USD spot price from the Mempool API and exposes it app-wide, used to display fiat-equivalent values in the sweep flow and elsewhere.
- **On-chain Zap Display**: Added `OnchainZapDisplay.swift` — a dedicated component for rendering on-chain (Taproot) zap receipts in the note detail and profile views, alongside existing Lightning zap display.
- **Search Tab (MacOS)**: Added a full **Search** tab to the MacOS Menu Bar sidebar, backed by `SearchView` — a multi-source search UI supporting users, notes, links, and hashtags, with a segmented source filter (`All / Haven Relay / Network`).
- **My Profile Quick-Access (MacOS)**: The MacOS sidebar footer now renders the owner's avatar using `AvatarView`, tapping it opens `ProfileView` in a sheet without navigating away from the current tab.
- **Emoji Picker Component**: Extracted a reusable `EmojiPickerView` component (available in both `Views/` and `Views/Components/`) for use in `ComposeView` and replies, with category tabs and search.
- **Feed Media View Component**: Extracted `FeedMediaView` into a standalone component under `Views/Components/` for better code reuse across the feed and note detail.
- **Autoload New Posts Toggle**: Added a `bolt.circle` / `bolt.circle.fill` toolbar button in the iOS Feed toolbar to toggle `autoLoadNewPosts` on/off without entering Settings.
- **Repost Toggle**: Added a dedicated `arrow.2.squarepath` toolbar button in the iOS Feed toolbar to quickly show/hide reposts inline.
- **Go Module: Bitcoin Dependencies**: Added `btcsuite/btcd`, `btcsuite/btcutil`, and `decred/dcrd/dcrec/secp256k1` to `haven-go/go.mod` / `go.sum` for the on-chain transaction layer.
- **C-Shared Bridge Export**: Exported the Bitcoin sweep and address derivation functions via `haven-go/cshared.go` so they are callable from Swift through the embedded `libhaven.a` bridge.
- **@mention Tagging in Compose**: Typing `@` while drafting a note now shows a live-filtered popup of followed users. Selecting a person inserts their `nostr:npub1…` mention token into the note body and automatically adds the corresponding `p` tag to the published event for proper Nostr mention routing.
- **NIP-89 App Handler Client Tagging**: Implemented automatic NIP-89 client identification tagging by default for all signed and published Nostr events. The tag dynamically identifies the target environment, tagging as `"Nostr Vault on iPadOS"` on iPadOS, `"Nostr Vault on iOS"` on iOS, and `"Nostr Vault on MacOS"` on MacOS.
- **Bidirectional Nostr Mute List Syncing (Kind 10000)**: Fully integrated Nostr Kind 10000 (Mute List) events. The app automatically fetches and merges remote mute lists on startup or profile fetch, and publishes signed Kind 10000 events to relays when blocking or unblocking an npub.
- **Per-Account Block Lists**: Replaced the global blacklisted npubs list with a namespaced dictionary `blockedNpubsPerAccount` in `HavenConfig` to track block lists individually per active profile.
- **Unified Blocked Accounts Settings Pane**: Added a new "Blocked" settings tab (`BlockedSettingsView`) displaying profile details, avatars, and search-to-block functionality for the active browsing account.
- **Natural Aspect-Preserving Media Layouts**: Replaced rigid and square/letterboxed constraints for photos and GIFs in `FeedMediaView` with high-fidelity, aspect-aware bounds (`.aspectRatio(contentMode: .fit)`).
- **Dual Landscape/Portrait Sizing Model**: Introduced an adaptive dual-height cap (`maxHeight: 400` / `portraitMaxHeight: 600`) so that portrait media can fill the available horizontal width naturally, while limiting extremely tall images to prevent feed drowning.
- **Dedicated Sub-components for Media Rendering**: Refactored `FeedMediaView` to use isolated `FeedPhotoView` and `FeedGIFView` helpers, streamlining asynchronous loading, animation state, and layout calculations.
- **Countdown Timers for User Actions**: Implemented dual countdown timers for both post creation and reposting. When a post is created, a 10-second countdown appears below it labeled "Post created - editing in Xs", giving users a window to edit or delete. When reposting, a 5-second countdown displays "Reposting in Xs" before the action is confirmed.
- **Repost Icon Status Indicator**: The repost button (`arrow.2.squarepath`) now lights up green with a subtle scale animation when a post has been reposted, providing visual feedback similar to the liked heart icon. Tracked via new `repostedEventIds: Set<String>` in `FeedService`.
- **iOS Floating "Liquid Glass" Tab Bar**: Replaced the native system bottom tab bar on iOS with a premium, floating "Liquid Glass" tab bar featuring a rounded capsule design, `.ultraThinMaterial` blur background, a soft drop shadow, a white reflective gradient stroke overlay, and spring scale micro-animations for active buttons.
- **Dynamic Profile Tab Avatar**: Upgraded the Profile navigation tab on iOS to display the active account's custom `AvatarView` instead of a static vector icon, dynamically updating in real-time when switching accounts.
- **Tab Bar Profile Fast-Switching**: Integrated the multi-account selector into a hold (context menu) gesture directly on the bottom bar's Profile tab item, enabling effortless account switching from anywhere in the app.
- **Real-Time Feed Reloading on Account Switch**: Configured `FeedService` to observe active Nostr identity shifts, automatically clearing feed caches, resetting relay subscriptions, and fetching the contact list for the newly selected account to refresh the following feed instantly.
- **App Renamed to Nostr Vault**: Completed front-facing rename from Haven to Nostr Vault. Updated `PRODUCT_NAME` in Xcode build settings (Debug + Release), all user-visible strings in `MenuBarView` ("Quit Nostr Vault", stale-process error, "Nostr Vault Relay" search tab label), the backup restore description in `SettingsView`, and both iOS privacy permission strings in `HavenApp-iOS/Info.plist`. Internal Go codebase, bundle identifiers, and Swift type names are unchanged.
- **iOS Note Detail Text Wrapping & Font Size Fix**: Resolved a visual layout bug on iOS where the parsed markdown text inside `NoteDetailView` would scale excessively large under custom Dynamic Type profiles and overflow the screen boundaries horizontally. Fixed by locking the system font size to a highly readable 16 pt with standard color/spacing, and applying `.fixedSize(horizontal: false, vertical: true)` to ensure correct text wrapping behavior within dynamic SwiftUI scroll containers.
- **macOS Video Opacity**: Fixed videos appearing transparent/see-through on macOS by setting `isOpaque = true` on the AVPlayerLayer backing layer in `InlinePlayerLayer`.
- **Blossom Storage Breakdown**: Added an interactive breakdown modal in the Dashboard that categorizes stored blobs by media type (Images, Videos, Audio, Other), showing both count and storage size per category.

### Changed
- **Bitcoin Sweep Refactored into Disclaimer+Action Pattern**: Replaced the old `BitcoinSweepView` with a two-step flow — `BitcoinSweepDisclaimerView` (balance confirmation) leading to the sweep action — triggered as a sheet from `SettingsView`. Removed all deprecated `BitcoinSweepView.swift` duplicates (`Views/`, `Views/Components/`, `HavenApp/` root).
- **Feed Toolbar Reorganized (iOS)**: The leading toolbar area now shows only the connection-status dot (enlarged to 12 pt, backed by a subtle circular background). The feed mode selector (`FeedMode` menu) was promoted to the `principal` (center) position for better visual hierarchy. The trailing area now hosts the autoload and repost toggles.
- **Connection Status Dot Elevated**: Connection dot now renders at 12 × 12 pt with an 80 % opacity shadow and a `Color.primary.opacity(0.08)` circular background, making it more legible on all backgrounds.
- **Consistent Dark Theme Colors**: Background colors across FeedView, MenuBarView, ProfileView, and relay status pages are now unified to `Color(red: 0.08, green: 0.08, blue: 0.1)` — eliminating visual inconsistency between sections.
- **ZapService Refactored**: Streamlined `ZapService.swift` (~100-line reduction), consolidating redundant payment-path branches and improving error propagation to the `ZapNotificationBanner`.
- **FeedService Major Overhaul**: Significant rewrite of `FeedService.swift` (308-line net change) improving subscription lifecycle management, deduplication, and engagement-stat flushing performance.
- **BlossomService Cleanup**: Tightened upload/download path resolution and improved local vs. remote URL detection in `BlossomService.swift`.
- **AnimatedImage Refactored**: Updated `AnimatedImage.swift` to use the new `FeedMediaView` component and improved GIF frame-timing logic to fix extra spacing that appeared above GIF content.
- **ComposeView Enriched**: `ComposeView.swift` gained emoji-picker integration, improved attachment preview layout, and reply context display.
- **NoteDetailView Improvements**: Enriched reply threading, added on-chain zap display, and improved real-time reply subscription handling.
- **ProfileView Overhaul**: Major refactor (~768 → full rewrite) with improved tab structure, zap/like history sections, and consistent dark background.
- **VideoPlayerView Enhanced**: Improved seek-bar behavior, playback state management, and extensionless file handling in `VideoPlayerView.swift`.
- **FeedMediaViewer Enhancements**: Improved swipe-to-dismiss gesture sensitivity and background dimming ramp in `FeedMediaViewer.swift`.
- **ViewerView Polished**: Cleaned up filter/tab transitions and improved Likes/Zaps sub-tab scroll behavior.
- **iOS ContentView (iPad)**: Minor layout fixes in `HavenApp-iOS/ContentView.swift` for sidebar state propagation.
- **HavenConfig Model Extended**: Added `autoLoadNewPosts` and `showReposts` boolean fields to `HavenConfig.swift` for the new toolbar toggles.
- **MediaItem Model**: Minor additions to `MediaItem.swift` for improved MIME / source tagging.
- **FeedProfile Model**: Small additions to `FeedProfile.swift` for search result rendering.
- **Settings UI Consolidation**: Merged "Identity" and "Access Control" configuration tabs into a single unified "Accounts" settings pane (`AccountsSettingsView`).
- **Implicit Account Whitelisting**: Added accounts (primary and secondary) are now implicitly whitelisted, eliminating the manual whitelisting step.
- **Primary Owner Block Sync to Relay**: Configured the primary Owner's personal block list to sync directly to the Go relay's `blacklisted_npubs.json` file for backend connection-level rejection.
- **Proactive Background Nostr Prefetching**: Overhauled threading performance by triggering asynchronous parent and quote note prefetching inside `FeedService.handleFeedMsgBackground`. Missing notes are fetched on background message processing immediately after events are parsed, dramatically speeding up scrolling loads for deep conversation trees.
- **NIP-45 COUNT Query Integration**: Refactored the relay event-counting mechanism in `NostrService` to use NIP-45 `COUNT` queries instead of `REQ` subscriptions. This resolves the issue where server-enforced event limit caps on standard subscriptions caused incorrect and capped event counts.
- **Unified Total Relay Events Stat**: Consolidated notes and reactions tracking on the dashboard into a single, comprehensive "Total Relay Events" metric, querying all event types with an empty filter payload.
- **Profile Switching UX**: Fixed unnecessary "Restart Required" banner that appeared when switching between profiles/accounts. The `activeAccountNpub` field is now excluded from the relay restart check, as it's an app-level preference, not a relay configuration change.
- **iOS Feed Header Cleanup**: Removed the legacy profile switcher dropdown from the top-left toolbar of the iOS feed view, leaving the connection status dot as a cleaner, dedicated indicator.
- **Improved Likes/Zaps Loading States**: Enhanced ViewerView with debounced settle states (1.5s) for likes and zaps lists to prevent spinner flashing during real-time updates. Prevents unnecessary UI thrashing when content has already been displayed.

### Fixed
- **GIF Spacing Bug**: Resolved unintended top padding above GIF content in `FeedNoteRow` / `feedMediaCarousel` by correcting the `AnimatedImage` frame modifier chain.
- **Bitcoin Sweep Balance Showing Zero**: Fixed `BitcoinSweepDisclaimerView` to correctly await the async Mempool balance fetch before rendering, so the displayed `balanceSats` is never stale.
- **Search Bar Keyboard Dismissal**: Added `@FocusState` management to the viewer/search inputs so tapping the list or the ✕ clear button properly dismisses the keyboard.
- **ZapNotifier Relay Integration**: Fixed `ZapNotificationBanner` to properly subscribe to the Haven relay's WebSocket for incoming zap receipts and update pill state (`Zapping… → Zapped! / Zap failed`) in real-time.
- **Carousel Image Swiping**: Fixed swipe gesture recognizer conflict in `FeedMediaView` carousels so horizontal swipes page between images without accidentally triggering vertical scroll.
- **Goofy Thread Spacing & Vertical Line Stretching**: Fixed a severe visual bug in `FeedView` / `FeedNoteRow` where reply rows containing photos or GIFs would stretch vertical layout boundaries and the thread connector line. Enforced rigid thread sizing (`width: 2, height: 14`) and applied `.fixedSize(horizontal: false, vertical: true)` on nested thread rows to ensure layout integrity.
- **LNURL Resolution for LUD-16 Addresses**: Fixed incorrect fallback that used a profile's NIP-05 identifier as a Lightning address when `lud16` was absent. NIP-05 and LUD-16 share the same `user@domain.com` format but resolve to completely different endpoints — this caused silent zap failures for any account whose NIP-05 domain doesn't also serve LNURL-pay.
- **LUD-06 (Raw LNURL) Zap Support**: Accounts that publish a raw bech32 `lnurl1…` string in the `lud06` metadata field (instead of a LUD-16 address) can now be zapped. `FeedProfile` stores `lud06`, `NostrService` parses it from Kind 0 metadata, and `LNURLService` decodes the bech32 payload to recover the HTTPS pay endpoint without a DNS lookup.
- **MacOS Compilation Fixes**: Resolved MacOS build errors by replacing unsupported `.tabViewStyle(.page(...))` with `.mediaTabViewStyleCompat()` in `NoteDetailView` and `FeedView`, and wrapping the iOS-only `.navigationBarTitleDisplayMode(.inline)` modifier in a platform-check preprocessor macro inside `BitcoinSweepDisclaimerView`.

## [2.4.0 macOS / 1.0 iOS (Build 7)] - 2026-05-19

### Added
- **Accent Theme Customization**: Introduced `AppTheme` enum with 6 preset accent colors (Haven Purple, Ocean Blue, Emerald Green, Sunset Orange, Rose Pink, Monochrome Slate) and added a dedicated "Appearance" Settings Tab supporting full dynamic theme-switching across iOS and macOS.
- **Universal iOS & iPad Layouts**: Integrated size-class checking (`@Environment(\.horizontalSizeClass)`) in the iOS ContentView to offer a professional sidebar-driven `iPadSidebarView` using `NavigationSplitView` alongside the standard tab-based layout for iPhone.
- **Engagement Feed Stats**: Enhanced `FeedService` to track, parse, and aggregate real-time engagement statistics (likes, replies, reposts) in background flushes, updating notes efficiently with real-time feedback.
- **Community Interaction Tabs (Likes & Zaps)**: Overhauled `ViewerView` with dedicated sub-tabs for "Likes" and "Zaps", enabling users to browse notes they liked/zapped, or see which of their own notes were zapped/liked, with beautiful stacked overlapping zapper/reactor avatars and satoshi totals.
- **Interactive Zap Notifications**: Built a floating `ZapNotificationBanner` overlay featuring animated, state-aware status pills (`ZapPill`) showing real-time feedback (Zapping..., Zapped!, Zap failed) with a pulsing lightning bolt.
- **Network Media Sync & Progress**: Enhanced the "Restore Media" wizard step to support segmented selection of either network sync from a remote Blossom server or local ZIP import, including a progress bar indicator during external Blossom media mirroring.

### Changed
- **Unified Feed Navigation**: Promoted the "Feed" view to the primary tab/view in both the Menu Bar and the iOS/iPad app, replacing the technical "Dashboard" tab as the central user workspace.
- **On-the-Fly Feed Controls**: Added interactive dropdown selectors to switch FeedModes (e.g. Following vs Global) directly from the iOS Navigation Bar and the macOS Menu Bar.
- **Smart Repost Fetching**: Added support for fetching parent/original note contents automatically for empty-content reposts.

## [2.4.0 macOS / 1.0 iOS (Build 6)] - 2026-05-19

### Stability
- **Relay lifecycle hardening**: Added 90-second watchdog timer for boot failures with auto-offer of "Force Restart". Added 5-second forced timeout to `stopRelay()` with state reset to idle.
- **Persist interaction state**: `likedEventIds` and `zappedEventIds` now persist to disk with throttled writes, surviving cold launches.
- **Error recovery UX**: Replaced status-message-only boot failures with actionable error sheets (Retry / Force Restart / Clear Locks) with clear explanations for port conflicts and database lock issues.

### UI/UX Polish
- **Empty state improvements**: Feed now distinguishes "Relay Starting..." from "No Following Feed" with contextual status messages and a Refresh Feed action.
- **Connection status refinement**: Expanded feed status dot to three states: green (live), orange (reconnecting), red (disconnected). Status dot is tappable to view relay details.
- **Navigation consistency**: Unified navigation with NavigationStack approach and gesture-based swipe-to-dismiss from ProfileView with drag threshold feedback.

### Code Quality
- **Split WebSocketClient.swift**: Extracted `NostrService.swift` (~1,250 lines) and `MediaCacheService.swift` (~530 lines) from the monolithic WebSocketClient, reducing it to ~460 lines.

## [2.4.0 macOS / 1.0 iOS (Build 5)] - 2026-03-11

### Added
- **Blossom Mirroring (macOS)**: Enabled the Blossom media mirroring service on macOS, allowing users to download their remote media to the local relay for offline access and faster loading.
- **Interactive Liked/Zapped States**: The Note Detail view now features persistent visual indicators for likes (red heart) and zaps (orange bolt) with spring animations when triggered.
- **Auto-Mirroring on Startup**: Introduced a setting to automatically mirror your own media from external servers whenever the relay starts, ensuring your local library is always in sync.
- **Media Swipe Gestures**: Implemented intuitive vertical swipe-to-dismiss gestures for full-screen media in both the Blossom media viewer and the note attachment viewer.
- **Gesture-Based Dimming**: Added interactive background opacity and media scaling that reacts to drag progress, providing visual depth and feedback during dismissal.
- **Unified Media Interaction**: Refactored viewer components to support consistent swiping and scaling for both image and video content.

### Changed
- **Real-time Replies**: The reply section in the Note Detail view now updates in real-time as new events arrive, providing a more dynamic and responsive threading experience.
- **Improved Feed Navigation**: Added an automatic "Scroll to Top" feature when switching filters or refreshing the feed.
- **Project Modernization**: Updated Xcode project settings to follow current Apple recommendations (LastUpgradeCheck 17.0).

### Fixed
- **Blossom Service Warnings**: Resolved compiler warnings regarding unused variables in the Blossom download pipeline.

## [2.4.0 macOS / 1.0 iOS (Build 3)] - 2026-03-03

### Fixed
- **Blossom Uploads Broken**: Removed redundant custom Blossom HTTP handlers that were intercepting requests before they reached the native `khatru/blossom` server. This was blocking standard BUD-02 `PUT /upload` requests and causing 400 errors from web clients.
- **Blossom CORS Errors**: Added proper CORS headers (`Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`) and `OPTIONS` preflight handling to resolve `XMLHttpRequest cannot load` errors when uploading media from web-based Nostr clients.
- **Blossom Downloads with File Extensions**: The khatru/blossom server now handles all GET requests natively, including URLs with file extensions (e.g., `/<sha256>.jpg`), fixing `Invalid SHA256 hash` errors when viewing media.
- **macOS Local Upload Protocol Mismatch**: Fixed `BlossomService` to use `http://` instead of `https://` for local Blossom uploads on macOS, since the Mac relay runs plain HTTP (Cloudflare handles TLS externally). The hardcoded `https://localhost:3355` URL was failing silently after TLS was disabled for the macOS C-shared relay.
- **Standardized Upload Endpoint**: Updated `BlossomService` to use the BUD-02 standard `PUT /upload` endpoint for all uploads (local and remote), replacing the non-standard `PUT /<sha256>` path.

### Added
- **Tailscale / LAN Network Support**: Expanded local network detection to recognize Tailscale IPs (`100.x.x.x`, `.ts.net`), as well as standard LAN ranges (`192.168.x`, `10.x`, `172.x`). This prevents the app from incorrectly forcing HTTPS or altering upload paths when connecting to your own relay over a local network.

## [2.4.0 macOS / 1.0 iOS (Build 2)] - 2026-03-03

### Added
- **iOS Support (1.0)**: Initial launch of the Haven iOS app with a unified codebase. Features include cross-platform support with shared services, views, and Go library builds.
- **C-Shared Library Architecture**: Embedded the Go relay as a static library (`libhaven.a`) directly linked into the Swift app. This improves reliability, simplifies process management (no more helper process), and enables universal (arm64 + x86_64) binary builds.
- **NIP-49 Private Key Encryption**: Added support for encrypting the Nostr private key (nsec) using a password (ncryptsec), with secure password storage in the system Keychain for automatic signing.
- **Nostr Zaps & NWC**: Full implementation of Nostr Zaps and Nostr Wallet Connect (NWC). Users can now send and receive lightning tips directly within the app, with real-time balance tracking.
- **Smart Inbox Broadcasting**: When replying or reacting to a note, Haven now automatically fetches the author's preferred relay configuration (Kind 10002) and broadcasts your response to their specific inbox relays, ensuring better delivery in a fragmented Nostr relay landscape.
- **Mac Relay Sync (iOS)**: A new background sync feature for iOS that allows the app to fetch missed notes from an always-on Mac Haven relay.
    - Added **Pull-to-Refresh** to the Feed, Viewer, and Note Detail views to manually trigger a Mac relay sync and catch missed notes.
    - Improved sync filter logic to include Kind 7 (Reactions), Kind 3 (Contacts), and direct mentions from strangers to ensure a complete timeline.


- **Direct Messaging (NIP-04)**: Initial support for NIP-04 private messaging and notifications.
- **UGC Reporting & Blocking**: Added user-generated content (UGC) reporting and blocking functionality to comply with App Store safety standards.
- **Web of Trust persistence**: WoT results are now cached locally, significantly speeding up relay startup by avoiding a full re-fetch of the Nostr network on every boot.
- **MIME Detection Pipeline**: Implemented a comprehensive MIME type detection system for the media viewer, improving support for extensionless Blossom items and note media.
- **Settings & Advanced Configuration**: 
    - Introduced dedicated tabs for **Access Control** (Whitelist/Blacklist), **Wallet** (Zaps), and **Logs**.
    - Added a **Factory Reset** option to clear all data and reset configurations.
    - Improved relay boot logs on the Dashboard for better transparency during startup (e.g., "Analyzing network connections"), and filtered out raw internal metadata like `total_keys=` to keep logs clean.
- **Privacy & Compliance**: Added a comprehensive Privacy Manifest (`PrivacyInfo.xcprivacy`) and export compliance declarations required for App Store distribution.


### Changed
- **Feed UI/UX Overhaul**:
    - Added **Pull-to-refresh** support for the timeline.
    - Added a floating **New Posts** indicator to jump to the top of the feed.
    - Improved threading UI with clear visual indicators for replies and parent notes.
    - Enhanced the Feed and Note details UI with **native grouped background colors**, replacing washed-out backgrounds and improving text contrast.
    - Increased feed limit to 500 events and optimized loading performance.
    - Unified media viewer with a source filter (Blossom vs. Cache).

- **Relay Process Management**: Replaced `os.Exit` with graceful connection handling during the import flow to prevent app crashes.
- **Bundle ID**: Updated macOS and iOS App Store bundle identifier to align with cross-platform identity (`com.havenapp.relay`).
- **Entitlements Tightened**: Hardened runtime and removed JIT and unsigned memory requirements for better security and App Store compliance.

### Fixed
- **App Transport Security**: Fixed HTTP media playback issues on macOS and iOS by properly configuring `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription`.
- **Feed Rendering**: Resolved issues with thread deduplication, pull-to-refresh animation logic, and missing non-owner posts.
- **Compose View Layout**: Fixed layout and styling of the Reply sheet on macOS to prevent content cropping.
- **Backup Verification**: Added checksum and integrity checks for `.zip` and `.jsonl` backups before restoration.
- **Sandbox Permissions**: Resolved "Operation not permitted" errors during database and media imports by using temporary directory staging.


## [2.3.0] - 2026-02-20

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, open **Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway**.

> [!NOTE]
> **Coming Soon**: The next release will move to a **C-shared relay architecture**, compiling the Go relay directly into the Swift app as a single process. This is required for App Store and TestFlight distribution. See [C_SHARED_RELAY.md](docs/C_SHARED_RELAY.md) for details on what's changing.

### Added
- **Audio Playback**: The media viewer now supports playing `.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, and `.ogg` audio files with a dedicated player UI featuring play/pause, seek controls, and a progress scrubber. Audio files are also detected via magic bytes (ID3, RIFF/WAVE) for extensionless Blossom items.
- **Blossom File Extensions**: Media exports now use a trust-but-verify system — querying the relay for MIME metadata and cross-checking against file magic bytes — to apply accurate file extensions. Supports virtually all file types via UTType, with magic-byte verification for JPEG, PNG, GIF, WebP, AVIF, HEIC, TIFF, BMP, MP4, MOV, WebM, MP3, WAV, FLAC, OGG, ZIP, APK, GZIP, and PDF. Additional fallback coverage for AAC, Opus, M4A, MKV, SVG, TAR, DOCX, XLSX, PPTX, and JAR.
- **Blossom Import**: Importing media automatically strips extensions to ensure compatibility with the relay.
- **Dashboard Quick Actions**: Added "Export JSONL" and "Export Blossom" buttons directly to the Dashboard for easier backups.
- **Import Button Rename**: Clarified the "Import" button on the Dashboard to "Import Notes".
- **Media Tab Filter**: Added a source filter to the Media Tab, allowing users to toggle between "Blossom" (local/uploaded) and "Cache" (captured from notes) media.
- **Dynamic Search Bar**: The search bar is now context-aware, appearing only in "Notes" mode and being replaced by the source filter in "Media" mode.
- **Whitelist & Blacklist Management**: Moved to a dedicated "Access Control" tab in Settings, with multi-npub support and corresponding config fields written to JSON.
- **DB Engine Selection**: Added a database engine step to the Setup Wizard allowing users to choose between storage backends.
- **JSONL Export/Import**: Replaced the old cloud-only backup UI with local JSONL export and import via native save/open panels in Settings.
- **Automatic Lock Recovery**: When a database lock is detected, the app now force-kills stale processes, clears lock files, and restarts the relay automatically.
- **"Fix & Restart" Button**: Replaced the multi-step "open Terminal and run pkill" error overlay with a one-click Retry button that handles cleanup automatically.
- **Backup Restore from Setup Wizard**: Users can now restore from a `.zip` or `.jsonl` backup during initial setup, with port conflict detection and retry support.
- **Setup Wizard: Blossom Media Restore**: Added Blossom media import as a dedicated setup wizard step (previously only available in Settings).
- **Floating Menu Bar Arrow**: After setup completion, a floating animated purple arrow with a glow effect points at the menu bar relay icon with a "Your relay lives here" label, helping new users locate the app.
- **C-Shared Relay Architecture** *(in development on `feat/c-shared-relay`)*: The Go relay is now compiled as a static C library (`libhaven.a`) and linked directly into the Swift app — making HAVEN a single-process application. This eliminates child process management, orphaned processes, and PID tracking. Required for App Store / TestFlight distribution.
- **Upstream Sync**: Pulled latest upstream changes from `bitvora/haven` into `haven-go/`.
- **Project Documentation**: Added `docs/RELEASE_PROCESS.md` (step-by-step release guide), `docs/C_SHARED_RELAY.md` (architecture overview of the c-shared approach), and `docs/upstream-sync.md` (subtree sync instructions).

### Changed
- **Dashboard Relays Hidden by Default**: The relay list on the Dashboard is now collapsed by default to reduce visual clutter, toggled via the existing eye icon.
- **Dashboard Layout**: Improved vertical spacing so the Dashboard fills the window height.
- **Setup Wizard: Split Import/Restore into Dedicated Steps**: The single "Import Your Data" step has been split into three independent, skippable steps: "Import from Relays" (pull notes from external relays), "Restore Notes" (restore JSONL backup), and "Restore Media" (restore Blossom media).
- **Setup Window Sizing**: Fixed inconsistent window sizes between the initial launch popup and the menu bar "Start Setup" flow. Both now open at 600x700.
- **Application Performance**: Optimized UI responsiveness by caching regex patterns and moving heavy computations off the main thread.
- **Relay Error Handling**: Improved relay error popups by removing the ineffective "Fix and Restart" option and providing clearer instructions for the "pkill" command.
- **Setup Wizard Overhaul**: Rewrote the setup flow with ScrollView support, a new identity step with inline whitelist editing, and a dedicated database engine step.
- **Backup Settings Simplified**: Removed AWS and GCP backup providers; streamlined to S3-compatible only for cloud backups.
- **Welcome Window**: The pre-setup menu bar view now shows a simple "Start Setup" prompt that opens the wizard in a dedicated window, rather than embedding the full wizard inline.
- **Process Startup**: `state = .booting` is now set immediately and synchronously before any async work, preventing a race where two relay processes could launch simultaneously.
- **Shutdown Reliability**: `stopRelay()` now waits up to 5 seconds for the process to exit and escalates to SIGKILL if SIGTERM is ignored. App termination wait increased from 0.2s to 1.0s.

### Fixed
- **Priority Inversions**: Resolved runtime priority inversion warnings in image loading by making `ImageDownsampler.downsample` async with `.utility` priority, and updating call sites in `AnimatedImage.swift` and `ViewerView.swift`.
- **Sandbox Permissions**: Resolved "Operation not permitted" errors during backup and import by using temporary directories for zip/unzip operations.
- **Improved Backup Reliability**: Replaced direct file archiving with a safer two-step process to avoid permission issues.
- **Dashboard UI**: Fixed an issue where export status messages could persist indefinitely.
- **Database Lock Boot Loop**: Fixed a critical race condition where two haven processes could start simultaneously, causing them to fight over database locks and loop forever.
- **Inactivity Timer**: Replaced broken `Timer`-based implementation (which couldn't mutate SwiftUI struct state) with a proper `Task.sleep` approach that correctly resets to the dashboard tab.
- **Import Log Parsing**: Added a byte-level log buffer (`processBufferedOutput`) to handle multibyte characters and incomplete lines during note import, preventing hangs.
- **Duplicate readabilityHandler**: Removed a dead first pipe handler in `importNotes` that was immediately overwritten by a second one.
- **Settings Save Leak**: Added `onDisappear` cancellation of the debounced save task in SettingsView.

### Known Issues
- This release is not eligible for App Store distribution. The following changes are in progress on `feat/c-shared-relay`:
  - Embed the Go relay as a C-shared library (replacing the separate helper process) for full App Sandbox compliance
  - Remove disallowed entitlements (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`)
  - Add required Privacy Manifest (`PrivacyInfo.xcprivacy`)
  - Replace blanket `NSAllowsArbitraryLoads` with `NSAllowsLocalNetworking`
  - Add `ITSAppUsesNonExemptEncryption` declaration

## [2.2.1] - 2026-02-07

### Added
- **Web of Trust Improvements**: Added configurable WoT Depth and Minimum Followers settings in the Advanced tab.
- **WoT Refresh Control**: Introduced a configurable refresh interval for the Web of Trust network (1h, 12h, 24h, 7d).

### Changed
- **macOS Sandbox Optimization**: Implemented a 256KB userspace buffer workaround to bypass the macOS Sandbox `sendfile` bug, improving media streaming stability.
- **Relay URL Generation**: Centralized and improved relay URL generation to handle local and remote connections more reliably.

### Fixed
- **WoT Pruning**: Improved WoT pruning logic and logging for better transparency.
- **Thread Safety**: Refined thread-safety in the relay backend and standardized internal benchmarks.

## [2.2.0] - 2026-01-30

### Added
- **Video Playback Overhaul**: Rewritten interaction with local media to handle extensionless files (Blossom) using a smart symlinking strategy.
- **Media Viewer Sorting**: Media items are now strictly sorted by Nostr event timestamp (newest first).
- **Backend Refactor**: Extracted Web of Trust functionality into a dedicated package (`haven-go/wot`) with lockless refresh support.
- **Handshake Support**: Added `User-Agent: Haven/1.0` header to resolve connection issues with specific relays.

### Fixed
- **Thumbnail Generation**: Resolved decoding errors for extensionless video files by adding settled-state detection.
- **Layout Stability**: Fixed layout constraint warnings and UI "crunch" errors in the video player controls.

## [2.1.1] - 2026-01-25

### Changed
- **Repo Restructuring**: Separated logic into `haven-go/` (backend) and `HavenApp/` (Swift UI) for better transparency and easier auditing.
- **Verifiable Builds**: Standardized documentation for building the Go backend from source.

### Fixed
- **Sandbox Media streaming**: Initial implementation of the userspace buffer fix for the macOS Sandbox bug.

## [2.1.0] - 2026-01-22

### Added
- **Pop-out Viewer Window**: Ability to pop out the viewer into an independent, multi-tasking friendly window.
- **Automated Maintenance**: Intelligent detection and automatic resolution of database locks during startup.
- **Welcome Window**: A new guided experience for new users on first launch.

### Changed
- **Swift 6 Readiness**: Addressed strict concurrency violations and compiled with `SWIFT_STRICT_CONCURRENCY=complete`.
- **Media Layout**: Overhauled media scaling in the grid and full-screen viewer to prevent distortion.

### Fixed
- **SSL/TLS Handshake**: Resolved issues where local media would fail to load due to certificate/handshake errors.
- **Image Crashes**: Fixed crashes related to downsampling high-resolution images.

## [2.0.0] - 2026-01-20

### Added
- **Media Caching System**: Improved media loading performance and reduced redundant network fetches.
- **Real-time Statistics**: Added a dashboard to monitor relay performance and event counts.
- **Hardened Runtime**: Enabled macOS Hardened Runtime and configured proper entitlements for increased security.

### Fixed
- **CPU Optimization**: Significant reduction in CPU usage during relay startup and synchronization.
- **Import Reliability**: Improved reliability of data import and pre-import cleanup processes.

## [1.2.0] - 2026-01-19

### Added
- **Initial Native Release**: First native macOS desktop application for the Haven protocol.
- **Universal Binary**: Support for both Apple Silicon and Intel Macs.
- **Setup Wizard**: Guided flow for initial relay configuration.
- **Integrated Blossom**: Built-in Blossom media server for hosting images and videos.
- **Cloud Backups**: Integrated support for S3, AWS, and GCP backups.

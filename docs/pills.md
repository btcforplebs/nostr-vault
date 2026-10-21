# Pills and on-screen notifications

Every short message the app puts over the screen (a notification, a toast, a
"New Posts" count, a filter note, an error) follows this one rule, on iPhone,
iPad, Mac and Android. If a new pill does not fit a level below, ask in nv-ui
before adding a new kind.

## One lane

All pills live in **one lane**, top-centre, just under the navigation bar:

| Platform | Host | Top of the lane |
|---|---|---|
| iPhone / iPad | `AppBannerStack` in the banner window (`HavenApp-iOS/SceneDelegate.swift`), above sheets | nav bar + 4 pt (48 pt iPhone, 54 pt iPad) |
| Mac | `PillLaneStack` overlay on the main window (`MenuBarView`) | 4 pt |
| Android | `NotificationOverlay` in `MainActivity`, above the full-screen media viewer | status bar + 64 dp |

Nothing else draws a pill in that band. A screen that has its own pill (the
Feed's New Posts, the WoT rebuild pill) keeps drawing it, but as a level-4
pill: it hides while the lane shows anything (see below).

## Four levels

The most important level wins. At most **two** pills show at once: the two
most important, newest first within a level. A held-back pill draws when a
place frees up, if its lifetime has not run out; once it has, it is gone.

An arrival from the relay (mention, reply, DM, zap, like, repost, follow) is
filed quietly in Notification Center when it was not read: it drew for less
than 1.5 s in total before it timed out, was pushed out, or lost its surface
(the app went to the background, the Mac window closed or went to the
Dock). A filed DM carries the generic title and line, never the sender or
the text. Rules and tests: `NotificationPolicy.filesPill`.

One event is one entry. A pill that was read or tapped removes the APNs push
for the same event (`event_id`) from Notification Center, and the badge
clears. An unread pill is not filed when that push is already there.

| Level | What | Examples | Size | Lifetime |
|---|---|---|---|---|
| 1 Error | Something failed | Like failed, upload failed, signer didn't answer | Regular | Error: until tapped. Warning: 5 s |
| 2 Result | Something you did finished, or something arrived for you | Posted (Undo/Edit), Zapped, Followed (Undo), Uploaded, mention / DM / reply | Regular | 3 s; 5 s with Undo; while sending/pending |
| 3 Feedback | What a button you just tapped did | Auto-load · on, Reposts · hidden, Liked, Link copied | Small | 2 s. A new one **replaces** the old one; never stacks |
| 4 Ambient | Background info about the screen | N New Posts, WoT rebuild progress, import running | Regular (tappable) / Small | While true, but **hidden while levels 1–3 show anything** |

A level-3 pill steps aside (is not shown) while two level 1–2 pills are up.

## Colour means one thing

| Tone | Colour | Use |
|---|---|---|
| Error | red | level 1 errors only |
| Warning | orange | level 1 warnings only |
| Success | green | a result that went through |
| Accent | app purple | in progress, on, the app's own pills (New Posts) |
| Neutral | grey | off, hidden, undone, pending |

No other colours (no per-type blue/teal/pink pills, no gradients, no black).
Icons carry the type; colour carries the outcome.

## Two sizes

- **Regular** — anything you can tap (Undo, Edit, open the mention, load New
  Posts) and every level 1–2 pill: 13 pt bold, 10 × 20 pt padding, icon 12 pt.
  Buttons inside: 13 pt bold, at least 44 pt tall to tap.
- **Small** — information only, never takes taps: 12 pt semibold, 6 × 14 pt
  padding, icon 11 pt.

Both: solid capsule, white text, shadow black 40 % / radius 8 / y 4, 6 pt
between pills, 16 pt side margins, `Motion.pillTransition` in and out.

## Phone and Mac notifications while the app is open

While the app is in front, the system banner does **not** show. The same
event shows once, as a level-2 pill in the lane (tap opens it). The system
banner is only for when the app is in the background.

- "In front": iOS, the scene is active. Mac, the app is active **and** the
  main window is open and visible (not in the Dock, not fully covered). A
  menu bar app with no window still banners. Pills already up are filed by
  the read rule only when the iOS app goes to the background, not when
  Control Center or an alert covers it.
- A system alert that reaches the open app is listed in Notification Center
  (`[.list]`), never dropped (`[]`). A relay alert filed just as the app went
  to the background also becomes its pill.
- An APNs push draws no pill of its own. The relay marker for the same event
  draws it, after every check (push off, per-type settings, blocks, Web of
  Trust). A push with no matching relay marker is list-only.
- With push notifications off, only DMs show while the app is open. Other
  types are dropped before routing.

## Coming back: the return pill

The one pill outside the lane. When the app comes back from the background
(iOS: the scene enters the foreground, including a cold launch, but not
Control Center or an alert going away; Mac: the app becomes active), the
arrivals the relay catches up on do **not** each get a level-2 pill and a
sound. They are gathered into **one** pill with **one** sound:

- Counts by kind, in this order: mentions (quotes count), replies, zaps,
  DMs, reactions, reposts, new followers. Three kinds at most, then
  "+N more" (`ReturnSummary`). One event counts once.
- iPhone and iPad with the tab bar: at the bottom, over the tab bar and the
  mini player, its arrow pointing down at the Vault tab. The floating
  button (Post) moves up clear of it and settles back when it goes. The tab
  bar unfolds so the Vault tab is there to point at.
- iPad sidebar and Mac window: beside the sidebar, level with the Vault row
  (the Mac's Notes row), arrow pointing left.
- Accent tone, regular size. Tap opens the Vault on its "Vault" list.
- Gathering stops 12 s after the return if nothing came, otherwise 6 s after
  the last arrival, and never later than 30 s after the return. The pill
  shows at least 6 s. After that, arrivals get the ordinary top pill.
- An event created before the return came in while you were away, however
  late the relay hands it over: for up to 5 minutes after the return it
  joins the pill, silently, bringing it back if it had gone.
  Rules and tests: `ReturnWindow`.

While the app is in front, nothing changes: each arrival is its own top pill.

## Not pills

Use these instead of a pill, never alongside one:

- Android `Toast`, Material `Snackbar`: not used. Use the lane.
- Inline captions in a viewer ("Saved to Photos"): use the lane.
- Static controls and chips that are always there are not pills.

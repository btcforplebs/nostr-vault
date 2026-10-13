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
| Android | `NotificationOverlay` in `NavGraph` | status bar + 64 dp |

Nothing else draws a pill in that band. A screen that has its own pill (the
Feed's New Posts, the WoT rebuild pill) keeps drawing it, but as a level-4
pill: it hides while the lane shows anything (see below).

## Four levels

The most important level wins. At most **two** pills show at once: the two
most important, newest first within a level. A held-back pill draws when a
place frees up, if its lifetime has not run out; once it has, it is gone.

An arrival from the relay (mention, reply, DM, zap, like, repost, follow) is
filed quietly in Notification Center when it was not read: it timed out or
was pushed out after drawing for less than 1.5 s in total, or its surface
went away while it was up (the app left the front, or the Mac window
closed). A filed DM carries the generic line, never its text. Rules and
tests: `NotificationPolicy.filesPill`.

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
  main window is open. A menu bar app with no window still banners.
- A system alert that reaches the open app is listed in Notification Center
  (`[.list]`), never dropped (`[]`). A relay alert filed just as the app went
  to the background also becomes its pill.
- An APNs push draws no pill of its own. The relay marker for the same event
  draws it, after every check (push off, per-type settings, blocks, Web of
  Trust).
- With push notifications off, only DMs show while the app is open. Other
  types are dropped before routing.

## Not pills

Use these instead of a pill, never alongside one:

- Android `Toast`, Material `Snackbar`: not used. Use the lane.
- Inline captions in a viewer ("Saved to Photos"): use the lane.
- Static controls and chips that are always there are not pills.

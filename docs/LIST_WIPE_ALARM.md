# List wipe alarm

When a new version of one of your lists reaches your vault and looks like
another app clobbered it, Nostr Vault warns you. It sends a notification and
shows a banner with one tap to **Recover** (restore the version from before)
or **Merge** (List backups › Merge). Nothing is ever reverted or published
until you tap. This follows up Lazarus, the Recover a List work (Logen go,
2026-11-04).

This file is the rule. It is implemented the same way by iPhone/Mac
(`ListWipeAlarmRule.swift`), Android (`ListWipeAlarmRule.kt`) and the web app
(`net/list-wipe-alarm.js`). All three are tested against
`HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/ListAlarm/alarm-cases.json`.
`reference.py` beside that file generated the fixtures; when the prose and the
fixtures disagree, the fixtures win.

## Where it runs

- **Detection is in the apps**, over the versions the vault keeps at `/lists`
  (haven-go `list_history.go`). It is the same pattern as the existing shrink
  rule and wipe banner. The vault already files every version that arrives on
  every path. The apps add the parts only they know: which versions Nostr
  Vault signed itself, and which alarms you dismissed.
- **The watcher.** When the in-process vault files a new version of an owner's
  list, it logs `🔔NOTIFY|type=listversion|kind=…|author=…|id=…|recipient=…|preview=`.
  iPhone/Mac and Android re-read that list's history and run the rule. If it
  alarms, they post a notification and show the banner. These markers never
  count as unread and never go through the inbox notification path. The apps
  also run the rule when the app comes to the front. The web app runs it when
  it loads and every 5 minutes while it is open, and shows the banner only.

## The rule

Inputs:
- one list's versions, newest first (`V0` is the new one);
- `own`, the ids of list events Nostr Vault signed on this device;
- `dismissed`, the ids whose alarm the person closed with "Keep the new list".

Terms:
- `items(v)`: the existing shrink rule's items, meaning every tag except
  `d title name description image alt client`, keyed by name and value. For a
  profile (kind 0), its filled-in string fields.
- `clobbered(a, b)`: `b` is a clobber of `a`. With `n = |items(a)|` and
  `kept = |items(a) ∩ items(b)|`, it is true when:
  - `n > 0` and `b` has no items (an emptied list); or
  - `n ≥ 10` and `kept·2 < n`. This counts by **which** entries survive, so a
    same-size list with other entries (a swap) counts.
  - For kinds `10000 10003 30000 30003` (an encrypted part the apps don't open
    for this), also when the content went from non-empty to empty, or from
    ≥ 1000 characters to under half its length.

When the rule alarms:
1. No alarm when `V0.id` is in `own` or in `dismissed`, or when there is only
   one version.
2. **Trigger:** some `i` in `1…min(5, count−1)` has `clobbered(Vi, V0)`, and no
   `j` in `1…i−1` has `clobbered(Vi, Vj)`. If an earlier step already
   clobbered `Vi`, that step was the alarm and this version is not a new one.
   This catches a list drained step by step (40 → 20 → 10 → 5) within five
   versions.
3. **The version offered back (`before`):** among `V1…Vk`, the one with the
   most items that `V0` clobbered. Ties go to the longer content. `k` is the
   lookback (5), or the newest version in `own` if that comes first: a version
   Nostr Vault signed is the owner's own choice, and nothing older than it is
   offered.
4. **Worth an alarm:** `before` holds ≥ 3 items, or it is an encrypted kind
   with ≥ 1000 characters of content. Emptying a list of one or two items is an
   edit.
5. **`how`**, for the wording:
   - `emptied`: `V0` has no items (and, for an encrypted kind, no content);
   - otherwise `drained`: the trigger `i > 1`;
   - otherwise `swapped`: `before` held ≥ 10 items, fewer than half were kept,
     and `V0` is at least half its size;
   - otherwise `shrank`.
6. **`client`:** the value of `V0`'s first `client` tag, trimmed and cut to 60
   characters, or none.

The alarm carries `before`, `after` (= `V0`), `how`, `from = |items(before)|`,
`to = |items(V0)|`, `lost = |items(before) − items(V0)|` and `client`.

## What the person sees

- **Banner (Vault dashboard):** "Your follows went from 412 to 3 on 4 Nov,
  changed by Amethyst." or "… by an app that didn't name itself." The wording
  follows `how` (emptied, swapped for other entries, drained, shrank). Buttons:
  **Recover** (the existing restore confirm page, which shows what comes back
  and what goes), **Merge** (for the kinds List backups can merge) and **Keep
  the new list** (dismiss).
- **Notification**, once per `after` id: "Your follows lost 409 entries",
  "Changed by Amethyst. Tap to recover them." Tapping it opens the Vault
  dashboard, where the banner is.
- Never: an automatic restore, a publish without a tap, or an alarm for a
  version in `own`.

## Known limits

- `own` is per device. A big cut you make in Nostr Vault on your Mac can alarm
  on your phone, and the banner then says to tap "Keep the new list" if it was
  you. A false alarm is the safe side.
- Lists under 10 items are only judged when emptied. By count, an edit and a
  wipe of a short list look the same (the merge rule makes the same call).
- An encrypted part is judged by length only.

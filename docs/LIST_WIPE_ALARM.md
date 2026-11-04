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
  also run the rule for every account when the app comes to the front, which
  catches a clobber that synced in while the phone was offline (the marker is
  skipped for old versions). Notifications go out once per `after` id and only
  while that version is under 48 hours old. Older alarms show only as the
  banner, so an upgrade doesn't set off a burst of notifications. The web app runs it when
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

**Judging one version** (`judge(k)`, where `Vk` is the version and the
versions after it in the list are older):
1. **Trigger:** some `i` in `k+1…min(k+5, count−1)` has `clobbered(Vi, Vk)`,
   and no `j` in `k+1…i−1` has `clobbered(Vi, Vj)`. If an earlier step already
   clobbered `Vi`, that step is the clobber, not `Vk`. This catches a list
   drained step by step (40 → 20 → 10 → 5) within five versions.
2. **The version offered back (`before`):** among `Vk+1…Vm`, the one with the
   most items that `Vk` clobbered. Ties go to the longer content. `m` is the
   end of the lookback, or the newest version in `own` older than `Vk` if that
   comes first: a version Nostr Vault signed is the owner's own choice, and
   nothing older than it is offered.
3. **Worth an alarm:** `before` holds ≥ 3 items, or it is an encrypted kind
   with ≥ 1000 characters of content. Emptying a list of one or two items is an
   edit.
4. **`how`**, for the wording:
   - `emptied`: `Vk` has no items (and, for an encrypted kind, no content);
   - otherwise `drained`: the trigger `i > k+1`;
   - otherwise `swapped`: `before` held ≥ 10 items, fewer than half were kept,
     and `Vk` is at least half its size;
   - otherwise `shrank`.
5. **`client`:** `Vk`'s first `client` tag value with control and format
   characters removed (Unicode categories Cc and Cf, which includes the bidi
   controls). It is then trimmed and cut to 60 code points. It is none if
   nothing is left. `claims_nostr_vault` is true when that name contains
   "nostr vault" in any case. Because `Vk` is not in `own`, this device did not
   make it.

**The list's alarm.** The alarm **sticks**: a later save does not erase it
(Tron, #1635). Look at `k = 0, 1, …` up to the vault's newest 20 versions and
skip every `Vk` in `own`. The first `Vk` that `judge(k)` alarms on decides:
- `Vk` is in `dismissed` (Keep the new list): no alarm;
- a newer version `V0…Vk−1` holds `before` again (every public item, and for an
  encrypted kind a content at least as long). That happens after a Recover, or
  when the list was rebuilt anywhere: no alarm;
- otherwise that is the alarm.

So wipe → one more save by the same app still alarms, and so does wipe → a
follow you add in Nostr Vault. The Recover offer stays the list from before
the wipe.

The alarm carries `before`, `after` (= `Vk`, the clobbering version), `how`,
`from = |items(before)|`, `to = |items(Vk)|`, `lost = |items(before) − items(Vk)|`,
`client` and `claims_nostr_vault`.

## What the person sees

- **Banner (Vault dashboard):** "Your follows went from 412 to 3 on 4 Nov,
  changed by Amethyst." or "… by an app that didn't name itself." If the name
  claims Nostr Vault: "… by an app calling itself Nostr Vault. This device
  didn't make that change." The wording
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

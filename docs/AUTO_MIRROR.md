# Auto-Mirror and Import media

Auto-Mirror copies your posted photos and videos into this device's vault, so
they stay with you when the servers that host them drop them. "Import media"
(Vault dashboard, Settings > Media servers > Mirror Now, the Mac relay
dashboard) runs the same import by hand. The Auto-Mirror switch is off on new
installs (`HavenConfig.autoMirrorMedia`).

One run has two halves:

1. **Your media servers.** Each server in your list (kind 10063) is asked
   for its file list (BUD-02 `/list`) for you and every whitelisted account.
   Files the vault doesn't have are downloaded.
2. **Your notes.** Every one of your notes in the vault is read, and the
   photo and video links in them are downloaded, wherever they are hosted.

Each file is checked against its SHA-256 and saved under that hash.

## The rules a run keeps

Agreed 2026-11-12, after an iPhone 18 asked its bunker for about 1,100
signatures in 25 minutes and saved nothing new.

| # | Rule | iPhone, iPad, Mac | Android |
|---|---|---|---|
| 1 | Never download a photo the vault already has. Its hash is known before the download: from a link named by its hash, from the note's `imeta` `x` (NIP-92), or from the link remembered by an earlier run. Two links known to give one file are downloaded once. A remembered link stays skipped, so a photo you deleted from the vault is not brought back. | `AutoMirrorLedger` (`automirror_saved.json` in the vault folder) | `AutoMirrorState` (`files/auto_mirror_links.json`, max 20,000) + `AutoMirrorRules.imetaHashes` |
| 2 | Few signatures. The server list is asked for with one signature per run. Your own account saves into its own vault without a signer. | Owner or keyless: list signature only, saves in-process. Another active account: one upload signature per group of up to 50 files (`AutoMirrorSigning`). | One signature for the whole run, shared by both halves (`RunSignature`). |
| 3 | At most one automatic run every 3 hours, counted from when a run **starts**, so a relaunch mid-run does not start another. A clock set back does not hold it off for good. | `AutoMirrorSchedule` with `VaultHistory.lastMediaImportStart` | `AutoMirrorRules.due`, `files/auto_mirror_start` |
| 4 | At most 200 downloads per run, both halves together. The rest come next run; rule 1 skips what this run saved. | `AutoMirrorRunLimit` | `RunLimits` (also stops starting downloads 55 min after the run signed, as its upload auth lasts an hour) |
| 5 | Tests for each rule. | `HavenApp/MediaLogicTests`: `AutoMirrorRulesTests`, `AutoMirrorLedgerTests` | `AutoMirrorRulesTest`, `AutoMirrorRunTest` |

Rule 3 applies to automatic runs only. Pressing Import media always runs, but
it counts as a start, so Auto-Mirror waits 3 hours after it. Rule 4 applies to
every run, by hand or automatic. On Apple, the setup wizard's one-time
"Mirror Media" step (server half only) is not capped, so a new device can
bring in everything on your servers at once.

A run started when the switch is on: on Apple at app launch, when the vault
is up, and each time the app comes back to the front (`AutoMirrorOnOpen`).
On Android at app launch and when the Media tab opens.

## Where a large backlog goes

With 200 per run and one automatic run every 3 hours, a device catches up at
up to 1,600 files a day. Pressing Import media again takes the next 200 at
once. The run's result line says how many are left, for example
"Mirrored 200 files; up to 450 more next run" (a file can be counted in both halves, so it is an upper bound).

## Not covered here

- Auto-Mirror does not push files to other devices. Moving in (mesh copy v2)
  and the home vault sender do that (`docs/MESH_COPY_V2_CONTRACT.md`).
- Copy to servers (Media servers page) is the push the other way, from the
  vault to your servers.

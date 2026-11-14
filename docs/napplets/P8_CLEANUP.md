# Napplets P8: clean-up, ready-to-publish files, and what's left before web 🏁

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P8). Local only. Logen's decision 3: nothing is published until the whole
build is done and he says so.

## Done in P8

- **One mount for the napplet screens.** The Media, WoT and Messages panes each had their own copy of the
  mount-and-wire code. They now share `src/napplet/usePaneNapplet.js`, which does the first-party grant, the bus,
  the napplet's intents registered once it can take them, the shell-answered intents, `onReady` and errors.
  ReaderPane keeps its own, because it runs two napplets (Reader and Compose).
- **One list of our napplets.** `src/napplet/first-party-list.js` holds each napplet's d tag, title, file, NAP
  domains, intents and summary. `first-party.js` adds the bytes for the app. Note Drafts now asks for only the three
  domains it uses.
- **Publishable files, built and unsent.** `node tools/napplet-release.mjs [out]` (default
  `web-vault/dist-napplets/`, gitignored) writes, for each napplet except the sample:
  - the exact `index.html` the app runs, with the WoT maths injected
  - an **unsigned** kind 35129 template (`d`, `x` = sha256, `title`, `summary`, `R` per domain, `i` per intent)
  - `RELEASE.md` with hashes and the remaining steps

  The tool can't sign or send, and a test checks that.

## Not done in P8, on purpose: deleting the classic screens

The plan keeps each old screen behind the switch for one release, and nothing has been released. Each napplet also
still lacks things its classic screen has (below), so deleting them now would take features away from users. Once
the gaps are closed and the switch has been on for a release, these go. Today that's 2,871 lines, plus the switch:
FeedScreen, ThreadScreen, PersonScreen, BlossomGallery, BlossomStats, WotScreen, WotGlobe, WotCard, WotList, WotMyWeb,
WotTopBar, MessagesScreen, ConversationScreen and MessagesTools. Some of their pieces are shared with other classic
screens; check what each import is still used by before deleting.

## What's left before web 🏁

**Logen's calls**
1. **WebRTC and the grant.** A napplet on its own origin can still send STUN through an about:blank child frame
   (P2). Should outside napplets get the private-data grant at all until browsers can block that?
2. **Turn the napplets on by default** for one release, with the classic screens behind the switch.
3. **A napplet host on the live site** (`NV_NAPPLET_HOST`: wildcard DNS, wildcard certificate, ideally a Public
   Suffix List domain). Without it, outside napplets won't open on nostrvault.app; only ours run there.
4. **Publish our napplets** (decision 3): the files are ready (`tools/napplet-release.mjs`). This needs the publishing
   account, Blossom upload and signing the 35129s.
5. **Deploy** the web build.

**Gaps to close before the classic screens can go**
- **Reader** (Feed, Thread, Profile):
  - not there yet: zaps, reposts and quotes, the note menu (mute, block, report, delete), custom emoji in notes,
    content warnings, the send delay with Undo
  - Compose has no media or emoji yet
  - feed modes other than Following; desktop's thread and profile right pane
- **Media:**
  - long video (it arrives whole before it plays; it needs ranges over `resource.bytes`)
  - the shim's 30 s timeout on large uploads and downloads
  - "Posted in N notes", file-note tiles, the stats panel
- **WoT:** See their web, and Follow/Unfollow on a card. Kind 3 is never signed for a napplet, so this needs a shell
  intent that asks first.
- **Messages:** photos, search, group DMs, and the name for a brand-new conversation.
- **Not part of this plan, stay classic:** your own profile (its editor), Search, Notifications, Settings, the Vault
  pages and the dashboard.

## Checked

- `npm test`: 2375 pass, 3 new (`napplet-release.test.mjs`): each built artifact hashes to its manifest's `x`, each
  template is unsigned and our own manifest parser accepts it, the WoT maths is in, the tool has no way to sign or
  send, and the three panes use the shared mount.
- **Real app** (headless Chrome, vite dev, throwaway keys, fake relay and Blossom), every napplet screen after the
  refactor:
  - Reader: the note shows, title "Following".
  - Media: 1 tile, its picture came as bytes through the shell.
  - WoT: "Everyone · 14, Following · 2, Vouched · 0, Further out · 12".
  - Messages: "Ann Smoke" with the last DM. `#/dm/<ann>` opens her thread.
  - Apps: lists Emoji and Note Drafts only.
  - 0 events published.

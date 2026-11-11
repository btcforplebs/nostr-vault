# Nostr Vault

Nostr Vault is a Nostr app that runs your own relay on your own device. Your notes, follows, messages and media are
kept on your phone or computer first, then sent to the relays and media servers you choose. The people you follow
decide who shows up in your feeds, and you decide what reaches each relay.

Website and user guide: [nostrvault.app](https://nostrvault.app) and [nostrvault.app/docs](https://nostrvault.app/docs/)

## Get it

| Platform | Where | Needs |
|---|---|---|
| iPhone and iPad | [App Store](https://apps.apple.com/us/app/nostr-vault/id6759681282) | iOS / iPadOS 17 or later |
| Mac | [Mac App Store](https://apps.apple.com/us/app/nostr-vault/id6759681282) | macOS 14 or later |
| Android | [Zapstore](https://zapstore.dev/apps/com.nostrvault.app), or the APK on [GitHub releases](https://github.com/btcforplebs/nostr-vault/releases/latest) | Android 8 or later |
| Web | [nostrvault.app/vault](https://nostrvault.app/vault/) | A modern browser, nothing to install |
| Linux box | [linux/README.md](linux/README.md) (one Docker container) | Raspberry Pi 4/5, mini PC or home server |

## What it does

- **Your own relay.** Every app carries a full Nostr relay (the Go relay from [Haven](https://github.com/bitvora/haven),
  built into the app as a library). Everything you post, receive and save is stored there first. On the web the
  same relay runs in the page as WebAssembly, so your notes stay in your browser, not on a server.
- **A pocket relay or a home relay.** On a phone the relay is a private backup and a megaphone: it keeps a complete
  copy and pushes your posts out, and nothing on the network can reach in. On a Mac that stays on, with a domain
  such as `relay.yourdomain.com`, it is a full public relay that your phone, your friends and other relays can read.
- **A private mesh between your devices.** Show a code on one device and scan it with the other, and they are linked
  over [FIPS](https://github.com/jmcorgan/fips), an encrypted peer-to-peer mesh. No public IP, port forwarding,
  domain or VPN needed. Your devices sync over it, a new phone can copy your whole vault across, and media can be
  read straight from your own devices. The protocol is written up in [docs/NIP-F1.md](docs/NIP-F1.md).
- **Web of trust, on by default.** Global feeds, search and notifications are filtered by the follow graph of the
  people you follow, so you see accounts your graph can vouch for instead of the raw firehose. You can see who
  vouches for anyone, drawn as a globe. Mute lists sync, and Report and Block are on every post.
- **Your media, kept by you.** Photos and videos are kept in your own media library and copied to the
  [Blossom](https://github.com/hzrd149/blossom) media servers you pick. The app runs its own Blossom server too.
- **Keys that never sit in plain text.** Your key is encrypted with NIP-49 and its password kept in the system
  keychain, or kept out of the app entirely with a NIP-46 remote signer (bunker). On the web, sign in with a
  NIP-07 extension or a bunker.
- **Everything else you expect.** Private messages (NIP-17, with NIP-04 for older apps), zaps through Nostr Wallet
  Connect, threads, articles, live streams, polls, marketplace listings, music and short videos. Notifications are
  made on the device from your own relay, with no push server.
- **Backups you hold.** Export your notes as JSONL and your media as files, and import them on another device.
  Every version of your follow list, mute list and bookmarks is kept, so a list another app wiped can come back.

## Repository layout

| Path | What it is |
|---|---|
| `HavenApp/` | iPhone, iPad and Mac app (SwiftUI). `project.yml` generates the Xcode project |
| `NostrVault/` | Android app (Kotlin, Jetpack Compose) |
| `haven-go/` | The relay, built as a library for every app (fork of [bitvora/haven](https://github.com/bitvora/haven)) |
| `fips-v2/`, `fips-v2-android/`, `fips-bridge/` | The FIPS mesh engine and its bindings (Rust) |
| `web-vault/` | The web app at nostrvault.app/vault |
| `web-relay/`, `web-relay-vault/` | The browser relay and its mesh side |
| `linux/` | The Docker image and installer for a Linux box |
| `website/` | nostrvault.app, including the user guide in `website/docs` |
| `docs/` | Protocol, contract and build notes |

## Build from source

You can build every app yourself and check that what you run is the code you read. The steps below are for macOS,
which the Apple apps need and the Android build script expects.

### Tools

- [Go](https://go.dev/dl/) 1.26 or later
- [Rust](https://rustup.rs) through rustup. The FIPS crates pin their toolchain in `rust-toolchain.toml`, and rustup
  fetches it on the first build
- Xcode 16 or later, for iPhone, iPad and Mac
- For Android: Android Studio with the Android SDK and NDK, JDK 17, and `cargo install cargo-ndk`
- For the web app: Node.js 22 or later
- Optional: [just](https://github.com/casey/just) for the shortcuts in `justfile`, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you add or move Swift files

```sh
git clone https://github.com/btcforplebs/nostr-vault.git
cd nostr-vault
```

### iPhone, iPad and Mac

```sh
open HavenApp/HavenApp.xcodeproj
```

Pick the `HavenApp-iOS` scheme for iPhone and iPad, or `HavenApp` for the Mac. Choose your own team under Signing &
Capabilities, then run. The build compiles the Go relay and the FIPS engine for you (the `build_haven*.sh` and
`build_fips_*.sh` scripts in `HavenApp/HavenApp/App/`). From the command line: `just ios-build` or `just macos-build`.

The GIF picker needs a nostr.build key. Without one the app still builds and the GIF button is hidden. To add one,
copy `HavenApp/Config/Secrets.xcconfig.example` to `HavenApp/Config/Secrets.xcconfig` (gitignored) and fill it in.

### Android

```sh
just android-build      # Go relay for each ABI, the FIPS engine, then the release APK
just android-install    # install it on a connected device with adb
```

Without a release keystore the APK is unsigned. To sign it, put `KEYSTORE_PATH`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`
and `KEY_PASSWORD` in `NostrVault/local.properties`. Debug and release builds share an app id but not a signing key,
so installing one over the other erases the keys stored on the phone. Use the same kind each time.

### Web app

```sh
cd web-vault
npm install
npm run dev       # local dev server
npm test
```

### Linux box

See [linux/README.md](linux/README.md) to install it or build the Docker image.

## Documentation

- [nostrvault.app/docs](https://nostrvault.app/docs/): the user guide
- [docs/NIP-F1.md](docs/NIP-F1.md): reaching a user's own relay and media over the FIPS mesh
- [CHANGELOG.md](CHANGELOG.md): version history

## Contributing

Issues and pull requests are welcome. Before you change code, read [AGENTS.md](AGENTS.md). It is short and covers
the file size limits, the generated Xcode project, and keeping the Apple and Android apps in step.

## Credits

Built on the relay by [bitvora](https://github.com/bitvora/haven) and the improvements by
[barrydeen](https://github.com/barrydeen/haven). The device mesh is [FIPS](https://github.com/jmcorgan/fips) by
jmcorgan; the apps build from a fork at [btcforplebs/fips](https://github.com/btcforplebs/fips).

3D objects (kind 33331) follow [arkin0x](https://github.com/arkin0x)'s SNO format,
[DECK-0003](https://github.com/arkin0x/cyberspace/blob/master/decks/DECK-0003-sno.md) of the Cyberspace protocol,
including its 256-colour palette. The web vault reads them with his [sno-core](https://github.com/arkin0x/sno-core),
used with his permission (`web-vault/src/vendor/sno-core`).

## License

[MIT](LICENSE)

# ⚙️ Divergence from Upstream

This fork introduces several architectural changes and features beyond the original [bitvora/haven](https://github.com/bitvora/haven) codebase, incorporating enhancements from [barrydeen/haven](https://github.com/barrydeen/haven) and specialized fixes for macOS and iOS.

## 🏗️ Architectural Changes

### C-Shared Library Architecture
The Go relay is compiled as a static library (`libhaven.a` for macOS, `libhaven_ios.a` for iOS) and linked directly into the Swift binary. This allows the relay to run as a thread inside the app process, which:
- Improves reliability by eliminating inter-process communication (IPC).
- Simplifies process management (lives and dies with the app).
- Enables App Store and TestFlight distribution within a single app bundle.

### Multi-Relay Dynamic Handler
This version manages four distinct internal relays within a single Go process, dynamically routed via a unified HTTP mux using a `dynamicRelayHandler`:
- **Private Relay**: Your main personal vault.
- **Chat Relay**: Optimized for real-time communication.
- **Inbox Relay**: Specifically for receiving events.
- **Outbox Relay**: For broadcasting to the network.
This unified routing allows the Swift app to interact with any of your internal relays through a single port/connection.

### macOS Sandbox Compatibility
Apple's App Sandbox restricts certain system calls like `sendfile()`, which Go's standard `http.ServeContent` relies on. We implemented a specialized file loader (`load_blob_darwin.go`) that bypasses these restrictions to ensure media loads correctly on macOS.

---

## 🚀 Enhancements from barrydeen/haven

We have incorporated several powerful features from the Barry Deen fork to enhance relay management:

### High-Performance Backups
- **Manual Backups (JSONL)**: Enhanced command-line support for specific relay exports and imports (`haven backup`/`haven restore`).
- **Blossom Media Exporting**: Native support for zipping and exporting the entire Blossom media vault, a custom integration not present in upstream or barrydeen forks.
- **S3 Cloud Snapshots**: Built-in support for periodic, automated backups to S3-compatible cloud storage providers.



### Recursive Web of Trust (WoT) 
The Barry Deen fork introduces a more robust WoT engine:
- **Persistent Cache**: WoT results are stored locally, significantly reducing startup time.
- **Configurable Depth**: Ability to set the WoT search depth (Level 2 vs Level 3).
- **Mobile Memory Optimization**: Automatically throttles WoT depth on iOS to prevent Out-of-Memory (OOM) crashes.


---

## 🌸 Blossom (BUD-02) Improvements

- **Standardized Endpoints**: Native support for the standard `/upload` endpoint across all mirrors.
- **Smart MIME Detection**: Uses magic bytes to identify file types for extensionless items.
- **CORS Support**: Built-in Cross-Origin Resource Sharing headers to support web-based Nostr clients.
- **Mirroring Logic**: Intelligent mirroring that coordinates between local storage and remote Blossom servers.

---

## 🛠️ Performance & Tuning

- **Custom User-Agents**: Adjustable identity for relay synchronization requests.
- **Blastr Overhaul**: Configurable timeouts and improved reliability for broadcasting to Blastr relays.
- **Lmdb Optimizations**: Adjustable database map sizes for different hardware constraints.

# NIP-17 Private DM Implementation Plan

## Overview

Add a private messenger using NIP-17 (Gift-Wrapped DMs) with NIP-44 (ChaCha20 + HMAC-SHA256) encryption. The local relay already has a dedicated `/inbox` endpoint that stores kind 1059 gift-wrapped events — we just need to wire up the Swift side.

---

## Architecture

### NIP-17 Message Flow

**Sending:**
1. Create a **rumor** — unsigned kind 14 with plaintext content and `["p", recipient_pubkey]` tag
2. Create a **seal** — NIP-44 encrypt the JSON of the rumor using `sender_sk` + `recipient_pk`, sign as kind 13 with sender's key (randomize `created_at` up to 2 days in the past)
3. Create a **gift wrap** — generate a one-time ephemeral keypair, NIP-44 encrypt the JSON of the seal using `ephemeral_sk` + `recipient_pk`, sign as kind 1059 with ephemeral key, add `["p", recipient_pubkey]` tag
4. Publish kind 1059 to local `/inbox` relay + recipient's DM relays (from their kind 10050, fallback to read relays from kind 10002)

**Receiving:**
1. Subscribe to local `/inbox` for kind 1059 where `#p` tag = own pubkey
2. Decrypt gift wrap content using `own_sk` + event's `pubkey` (ephemeral pk) → get seal JSON
3. Decrypt seal content using `own_sk` + seal's `pubkey` (sender pk) → get rumor JSON
4. Rumor's `content` is the plaintext message; `pubkey` is the real sender

---

## Files to Create / Modify

### 1. `haven-go/cshared.go` — Add NIP-44 C exports

Add two new exported functions after the existing NIP-04 block:

```go
//export EncryptNIP44C
func EncryptNIP44C(plaintext *C.char, pubkey *C.char, privkey *C.char) *C.char {
    convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
    if err != nil {
        slog.Error("EncryptNIP44C: GenerateConversationKey failed", "err", err)
        return nil
    }
    encrypted, err := nip44.Encrypt(C.GoString(plaintext), convKey)
    if err != nil {
        slog.Error("EncryptNIP44C: Encrypt failed", "err", err)
        return nil
    }
    return C.CString(encrypted)
}

//export DecryptNIP44C
func DecryptNIP44C(ciphertext *C.char, pubkey *C.char, privkey *C.char) *C.char {
    convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
    if err != nil {
        slog.Error("DecryptNIP44C: GenerateConversationKey failed", "err", err)
        return nil
    }
    decrypted, err := nip44.Decrypt(C.GoString(ciphertext), convKey)
    if err != nil {
        slog.Error("DecryptNIP44C: Decrypt failed", "err", err)
        return nil
    }
    return C.CString(decrypted)
}
```

Add `"github.com/nbd-wtf/go-nostr/nip44"` to the import block — it's already in `go.sum` (v0.52.3).

**Note:** Verify that the `nip44` package implements the correct spec (ChaCha20 stream cipher + HMAC-SHA256 authentication, NOT ChaCha20-Poly1305).

After adding, run `build_haven.sh` and update the three header files:
- `HavenApp/build/libhaven.h`
- `HavenApp/build/libhaven-arm64.h`
- `HavenApp/build/libhaven-x86_64.h`

Add to each:
```c
extern char* EncryptNIP44C(char* plaintext, char* pubkey, char* privkey);
extern char* DecryptNIP44C(char* ciphertext, char* pubkey, char* privkey);
```

---

### 2. `HavenApp/HavenApp/Services/NIP44Service.swift` — New file

Mirror the structure of `NIP04Service.swift`. Thin wrapper calling `EncryptNIP44C` / `DecryptNIP44C`.

```swift
enum NIP44Service {
    enum NIP44Error: Error { case encryptionFailed, decryptionFailed }

    static func encrypt(plaintext: String, recipientPubkey: String, senderPrivkey: String) throws -> String
    static func decrypt(ciphertext: String, senderPubkey: String, recipientPrivkey: String) throws -> String
}
```

---

### 3. `HavenApp/HavenApp/Services/NIP17Service.swift` — New file

Handles the full gift-wrap encode/decode chain.

**Types:**
```swift
struct DMRumor: Codable {
    // Kind 14, no sig — computed id but never signed
    let id: String
    let pubkey: String
    let created_at: Int64
    let kind: Int  // 14
    let tags: [[String]]
    let content: String
}
```

**Key functions:**
```swift
enum NIP17Service {
    // Build a kind 1059 gift-wrapped event ready to publish
    static func createGiftWrap(
        content: String,
        recipientHexPubkey: String,
        senderHexPrivkey: String,
        senderHexPubkey: String
    ) throws -> NostrEvent

    // Decode a received kind 1059 → (senderPubkey, plaintext, timestamp)
    static func unwrapGiftWrap(
        _ event: NostrEvent,
        recipientPrivkey: String
    ) throws -> (senderPubkey: String, content: String, timestamp: Date)
}
```

**Implementation notes:**
- `createGiftWrap`: build rumor → NIP-44 seal with sender key → generate ephemeral keypair via `GenerateKeyPairC()` → NIP-44 gift wrap with ephemeral key → sign both seal and gift wrap via `SignEventC()`
- Randomize `created_at` on seal and gift wrap: `Date().addingTimeInterval(Double.random(in: -172800...0))` (up to 2 days in the past for metadata privacy)
- Rumor `id` is computed as SHA256 of the canonical serialization (same as regular events) but no `sig` field

---

### 4. `HavenApp/HavenApp/Services/DMService.swift` — New file

`@MainActor ObservableObject` that manages all DM state.

**Models:**
```swift
struct DMMessage: Identifiable {
    let id: String          // event id of the rumor
    let senderPubkey: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
}

struct DMConversation: Identifiable {
    let id: String          // counterparty hex pubkey
    var messages: [DMMessage]  // sorted ascending by timestamp
    var unreadCount: Int
}
```

**DMService:**
```swift
@MainActor
class DMService: ObservableObject {
    static let shared = DMService()

    @Published var conversations: [DMConversation] = []  // sorted by latest message
    @Published var isLoading: Bool = false

    func startListening()   // subscribe to /inbox WebSocket for kind 1059
    func sendDM(content: String, to recipientHexPubkey: String) async throws
    func markRead(conversationWith pubkey: String)

    private func handleIncomingGiftWrap(_ event: NostrEvent)
    private func inboxRelayURL() -> URL?  // wss://127.0.0.1:<port>/inbox
    private func fetchRecipientDMRelays(_ pubkey: String) async -> [String]  // kind 10050, fallback to kind 10002 read relays
}
```

**Relay subscription filter:**
```json
{ "kinds": [1059], "#p": ["<own_pubkey>"] }
```

Connect to the local `/inbox` endpoint using the existing `WebSocketClient`. Outgoing DMs also publish to recipient's DM relays:
1. First check for kind 10050 (DM relay preferences specific to NIP-17)
2. Fallback to read relays from kind 10002 if no kind 10050 exists
3. `NostrService.relayLists` already caches kind 10002 — add similar caching for kind 10050

---

### 5. `HavenApp/HavenApp/Views/ConversationsView.swift` — New file

List of conversations, one row per counterparty.

Each row:
- Avatar from `NostrService.profiles[pubkey]`
- Display name or truncated npub
- Last message preview (truncated to ~60 chars)
- Timestamp of last message (relative: "2m", "3h", "Mon")
- Unread count badge

Tapping a row navigates to `DMThreadView`.

A "+" button in the nav bar opens `NewConversationView`.

---

### 6. `HavenApp/HavenApp/Views/DMThreadView.swift` — New file

Classic chat bubble layout:
- Own messages: right-aligned, purple bubble
- Counterparty messages: left-aligned, gray bubble
- Timestamp on long-press or grouped by day
- Text input bar at the bottom with send button
- Scroll to bottom on new messages

---

### 7. `HavenApp/HavenApp/Views/NewConversationView.swift` — New file

Simple sheet with a text field that accepts:
- `npub1...` (bech32)
- Hex pubkey

Validates the input, fetches the profile from the network if missing, shows a preview of the contact, then opens `DMThreadView` on confirm.

---

### 8. `HavenApp/HavenApp/Views/MenuBarView.swift` — Modify

Add `.messages` to the `Tab` enum:
```swift
enum Tab {
    case feed
    case messages   // new
    case search
    case profile
    case relay
    case settings
}
```

Add a Messages nav button (envelope icon: `envelope` or `bubble.left.and.bubble.right`) and wire it to `ConversationsView`. Show an unread badge on the tab icon when `DMService.shared.conversations` has unread messages.

---

## Build Order

1. Add NIP-44 C exports to `cshared.go`
2. Run `build_haven.sh` to rebuild `libhaven.a`
3. Update header files
4. Create `NIP44Service.swift`
5. Create `NIP17Service.swift`
6. Create `DMService.swift`
7. Create `ConversationsView.swift`, `DMThreadView.swift`, `NewConversationView.swift`
8. Modify `MenuBarView.swift`
9. Add all new `.swift` files to `project.pbxproj`

## Open Questions

- **Outgoing relay routing**: When sending a DM, publish to the recipient's kind 10050 DM relay preferences (fallback to read relays from kind 10002). Need to add caching for kind 10050 similar to the existing `NostrService.relayLists` caching for kind 10002. For kind 10002, read relays are those with tag `r` that have explicit `read` marker or no marker at all (no marker = both read/write).
- **Persistence**: Decrypted messages should be cached locally (e.g., in a JSON file under the Haven app support directory) so they don't need re-decryption on every launch. Consider a simple `[String: [DMMessage]]` keyed by conversation pubkey.
- **Sent DMs**: To see your own sent messages, you need to also gift-wrap a copy to yourself (wrap with `["p", own_pubkey]`) and publish it to your own inbox. This is the NIP-17 spec recommendation.
- **Notifications**: `PushNotificationService` likely fires on incoming relay events — hook DMService into the same path so new DMs trigger a notification.
- **iOS**: `NIP44Service.swift` uses the same C bridge as macOS, so it works for both targets automatically once `cshared.go` is updated and the iOS library is rebuilt.
- **Security limitation**: NIP-44 does not provide forward secrecy — if a private key is compromised, all previous conversations encrypted with that key can be decrypted. This is a known limitation of the protocol.

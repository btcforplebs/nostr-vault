# Common Tasks: Step-by-Step Recipes

## Add a New Config Option (End-to-End)

This is the most common cross-cutting change. A config option flows through 4 layers.

### Step 1: Add to Swift model (`HavenApp/HavenApp/Models/HavenConfig.swift`)
```swift
// Add field with default value
var newOption: String = "default"

// Add to CodingKeys enum
case newOption

// Add to init(from:) decoder
newOption = try container.decodeIfPresent(String.self, forKey: .newOption) ?? defaults.newOption
```

### Step 2: Add UI control (`HavenApp/HavenApp/Views/SettingsView.swift`)
Add appropriate control in the relevant settings section.

### Step 3: Map to env var (`HavenApp/HavenApp/Services/RelayProcessManager.swift`)
In `generateEnvDictionary(config:)` (~line 925), add:
```swift
"NEW_OPTION": config.newOption,
```

### Step 4: Add to Go config (`haven-go/config.go`)
```go
// Add field to Config struct
NewOption string `json:"new_option"`

// Add to loadConfig()
NewOption: getEnvString("NEW_OPTION", "default"),
```

### Step 5: Use in Go code
Reference `config.NewOption` where needed.

### Step 6: Test
1. Build and run
2. Change the setting in UI
3. Verify in .env file that env var is written
4. Restart relay and verify Go picks up the value (check logs)

---

## Add a New Swift Service

### Step 1: Create file
Create `HavenApp/HavenApp/Services/NewService.swift`

### Step 2: Follow the pattern
```swift
import Foundation

@MainActor
class NewService: ObservableObject {
    static let shared = NewService()
    @Published var someState: SomeType = initialValue

    func doSomething() {
        // ...
    }
}
```

### Step 3: If views need it, inject in `HavenApp.swift`
```swift
@StateObject private var newService = NewService.shared
// Add to each scene:
.environmentObject(newService)
```

### Step 4: Add to Xcode target membership
Ensure the file is added to both HavenApp (macOS) and HavenApp-iOS targets if cross-platform.

---

## Add a New SwiftUI View

### Step 1: Create file
Create `HavenApp/HavenApp/Views/NewView.swift`

### Step 2: Follow the pattern
```swift
import SwiftUI

struct NewView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    var body: some View {
        VStack {
            // ...
        }
    }
}
```

### Step 3: Add navigation
Wire it into `MenuBarView`, `SettingsView`, or wherever appropriate. Use `NavigationLink` or `sheet()`.

### Step 4: Color scheme
Don't add `.preferredColorScheme(.dark)` per-view — it's applied at scene level.

---

## Add a New C-Exported Go Function

### Step 1: Add function in `haven-go/cshared.go`
```go
//export NewFunctionC
func NewFunctionC(param *C.char) *C.char {
    defer func() {
        if r := recover(); r != nil {
            log.Printf("recovered from panic: %v", r)
            return
        }
    }()
    goParam := C.GoString(param)
    // ... implementation
    return C.CString(result)
}
```

### Step 2: Rebuild
Build via Xcode (Cmd+B) or run `build_haven.sh` manually. The new function automatically appears in `build/libhaven.h`.

### Step 3: Call from Swift
```swift
let cParam = strdup("value")
let result = NewFunctionC(cParam)
free(cParam)
if let result = result {
    let swiftResult = String(cString: result)
    free(result)
}
```

No bridging header changes needed — it already includes `libhaven.h`.

---

## Modify Relay Access Control

### Step 1: Edit policy in `haven-go/policies.go`
Policy functions follow this signature:
```go
func MyNewPolicy(ctx context.Context, event *nostr.Event) (bool, string) {
    // return (true, "reason") to reject
    // return (false, "") to accept
}
```

### Step 2: Wire into relay in `haven-go/init.go`
Add to the appropriate relay's policy chain:
```go
privateRelay.RejectEvent = append(privateRelay.RejectEvent, MyNewPolicy)
// or
chatRelay.RejectFilter = append(chatRelay.RejectFilter, MyNewPolicy)
```

### Step 3: Test
Use a Nostr client to send events and verify rejection/acceptance.

---

## Add a New Nostr Event Kind

### Step 1: In Go — add to allowed kinds if chat-related
In `haven-go/policies.go`, add to `allowedChatKinds`:
```go
var allowedChatKinds = map[int]struct{}{
    // ... existing kinds
    newKind: {},
}
```

### Step 2: In Swift — add kind description
In `HavenApp/HavenApp/Models/NostrEvent.swift`, add to the kind description helper.

### Step 3: Handle in relevant service
If the kind needs special processing, add handling in `FeedService` or `WebSocketClient`.

---

## Sync Upstream Go Changes

```bash
# 1. Ensure upstream remote exists
git remote add upstream https://github.com/bitvora/haven.git  # if not done

# 2. Pull upstream changes
git subtree pull --prefix=haven-go upstream master

# 3. Resolve conflicts (common in init.go)
# Preserve: lazy init pattern, isCShared() guard, error returns, CloseDBs()

# 4. Test build
cd HavenApp && xcodebuild -scheme HavenApp -configuration Debug build
```

See `docs/upstream-sync.md` for detailed instructions.

---

## Backup and Restore (Programmatic)

```swift
// Local backup
let path = "/path/to/backup.zip"
let cPath = strdup(path)
let result = BackupDatabaseC(cPath)  // 0=success, 1=failure
free(cPath)

// Cloud backup
let result = BackupToCloudC()  // 0=success, 1=failure

// Restore
let cPath = strdup(backupPath)
let result = RestoreDatabaseC(cPath)
free(cPath)
```

**Important**: Relay must be stopped during backup/restore. `RelayProcessManager` handles this.

---

## Debug the Go Relay

1. Set log level to DEBUG in Settings or via env: `HAVEN_LOG_LEVEL=DEBUG`
2. Go logs are captured by `RelayProcessManager` via file descriptor redirection
3. Parsed into `LogEntry` structs, displayed in `LogsView`
4. Log prefixes in Go code: `🚀` boot, `⏳` loading, `✅` success, `🚫` error, `⚠️` warning, `🔗` listening

---

## Add a Blossom Mirror

1. **UI**: already handled in `SettingsView` — editable list of mirror URLs
2. **Config**: stored in `HavenConfig.blossomMirrors` array
3. **Upload flow**: `BlossomService.uploadAndMirror()` handles:
   - Upload to local Blossom first
   - Concurrent uploads to all configured mirrors
   - BUD-02 auth (kind 24242) signed per mirror
   - 3 retries with exponential backoff per mirror
4. **Strict enforcement**: returns nil if local upload fails OR all mirrors fail

---

## Factory Reset

```swift
// 1. Stop relay
relayManager.stopRelay()

// 2. Delete all data
configService.resetApp()
// This deletes: relayDataDir (DBs, logs, .env), config.json
// Resets in-memory config to defaults

// 3. User must re-run setup wizard
```

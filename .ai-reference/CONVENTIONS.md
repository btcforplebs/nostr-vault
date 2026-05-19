# Coding Conventions

## Swift Conventions

### Service Pattern
All services are `@MainActor` `ObservableObject` singletons:
```swift
@MainActor
class MyService: ObservableObject {
    static let shared = MyService()
    @Published var someState: SomeType

    // Private init to enforce singleton
    // (though most services use default internal init)
}
```

### Environment Injection
Services are injected at the scene level in `HavenApp.swift`:
```swift
@StateObject private var configService = ConfigService.shared
// ...
SomeView()
    .environmentObject(configService)
    .environmentObject(relayManager)
    .environmentObject(nostrService)
    .environmentObject(statsService)
```

Views access via:
```swift
@EnvironmentObject var configService: ConfigService
```

### View Pattern
```swift
struct MyView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var localState = ""

    var body: some View {
        // ...
    }
}
```

### Dark Mode
Applied at scene level via `.preferredColorScheme(.dark)`. Do not set per-view.

### Platform Conditionals
```swift
#if os(macOS)
    // macOS-specific code
#else
    // iOS code
#endif
```

### Config Migration Safety
Every new `HavenConfig` field must follow this pattern:
```swift
// 1. Default value in struct declaration
var newField: String = "default"

// 2. Add to CodingKeys enum
case newField

// 3. Use decodeIfPresent in init(from:)
newField = try container.decodeIfPresent(String.self, forKey: .newField) ?? defaults.newField
```

### Naming
- Files named after primary type: `ConfigService.swift`, `FeedView.swift`
- Services: suffixed with `Service` (`BlossomService`, `NWCService`)
- Views: suffixed with `View` (`FeedView`, `SettingsView`)
- Models: plain names (`HavenConfig`, `NostrEvent`)

### Error Handling
- Services use `do/catch` with `#if DEBUG print(error)` for internal errors
- Go bridge errors: check return value (0=success for int, nil=error for strings)
- No `throws` in UI layer; handle errors in services

### Debug Logging
```swift
#if DEBUG
print("ConfigService: description of what happened")
#endif
```

## Go Conventions

### Package Structure
- All relay code in `package main` (root of `haven-go/`)
- Sub-packages only for isolated concerns: `pkg/wot/`, `internal/cloud/`
- No unnecessary abstraction layers

### Build Tags
- `//go:build cshared` on `cshared.go` only (first line of file)
- `cshared_stub.go` has no build tag — included in all builds
- `load_blob_darwin.go` uses implicit `_darwin` filename convention

### C-Exported Functions
```go
//export FunctionNameC
func FunctionNameC(param *C.char) *C.char {
    defer func() {
        if r := recover(); r != nil {
            log.Printf("recovered from panic: %v", r)
        }
    }()
    // ... implementation
}
```

Rules:
- PascalCase with `C` suffix: `StartRelayC`, `SignEventC`
- Always include `defer recover()` for panic safety
- Convert C strings immediately: `C.GoString(param)`
- Return C strings via `C.CString()` (caller frees)
- Return `nil` for errors, `C.int(1)` for failures

### Error Handling
- Return `error` from init functions (never panic in library code)
- Log errors with emoji prefixes: `🚫` error, `⚠️` warning, `✅` success, `🚀` boot, `⏳` loading
- Use `slog` for structured logging, `log` for human-readable boot messages

### Policy Functions
```go
func MustBeXToY(ctx context.Context, event/filter) (reject bool, reason string) {
    // return (true, "reason") to reject
    // return (false, "") to accept
}
```

Naming: `MustBeX`, `MustNotBeX`, `OnlyX`, `EventMustBeX`

### Config Helpers
```go
getEnv(key string) string                          // warns if not set
getEnvString(key string, defaultValue string) string
getEnvInt(key string, defaultValue int) int
getEnvBool(key string, defaultValue bool) bool
getEnvDuration(key string, defaultValue time.Duration) time.Duration
```

### Global State
- Global vars declared in `init.go` (not `main.go`)
- Re-created on each `initRelays()` call (not persistent across stop/start cycles)
- `config` is reloaded each `StartRelayC()` call
- Use `dbs` map for database lifecycle management

## Git Conventions

- `haven-go/` managed via git subtree (remote: `upstream`)
- Never cherry-pick from upstream — always use `git subtree pull`
- Never use `--squash` with subtree pull (preserves branch line)
- Downstream Go changes committed directly to `master`
- `CHANGELOG.md` updated with each build
- Commit messages: descriptive, prefix with area (`refactor:`, `feat:`, `fix:`)

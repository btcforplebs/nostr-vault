# Build System Reference

## Prerequisites

- Go 1.24+ (see `haven-go/go.mod`)
- Xcode 15+
- macOS 14.0+ SDK (for macOS target)
- iOS 17.0+ SDK (for iOS target)

## macOS Development Build

1. Open `HavenApp/HavenApp.xcodeproj`
2. Select **HavenApp** scheme, **My Mac** destination
3. Cmd+R to build and run
4. Xcode runs `build_haven.sh` as a Run Script build phase automatically

### `build_haven.sh` (`HavenApp/HavenApp/App/build_haven.sh`)

**What it does**:
1. Locates Go source at `{PROJECT_DIR}/../haven-go`
2. Detects architectures from Xcode `$ARCHS` variable (arm64, x86_64, or both)
3. Builds Go with: `GOARCH={arch} go build -tags cshared -buildmode=c-archive -ldflags="-s -w" -o {output}`
4. For universal builds: builds both slices, combines with `lipo`
5. Output: `HavenApp/build/libhaven.a` + `HavenApp/build/libhaven.h`

**Environment**:
```bash
export GOOS="darwin"
export CGO_ENABLED=1
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CGO_LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"
```

### `build_haven_ios.sh` (`HavenApp/HavenApp/App/build_haven_ios.sh`)

Similar to macOS but targets iOS SDK:
- `GOOS=ios`
- Uses `xcrun --sdk iphoneos/iphonesimulator` for C compiler
- `IPHONEOS_DEPLOYMENT_TARGET=15.0`
- Output: `HavenApp/build/ios/libhaven_ios.a`

## Xcode Project Structure

**Targets**:
- `HavenApp` (macOS)
- `HavenApp-iOS` (iOS)

**Key build phases** (macOS):
1. **Run Script**: executes `build_haven.sh` — builds Go library
2. **Compile Sources**: compiles Swift files
3. **Link Binary**: links `libhaven.a` + system frameworks

**Bridging header**: `HavenApp/HavenApp/HavenApp-Bridging-Header.h`
```c
#include "../build/libhaven.h"
```

**Entitlements**: `HavenApp/HavenApp/App/HavenApp.entitlements`
- App Sandbox: enabled
- Network client: enabled (outbound connections)
- Network server: enabled (relay listens on port)
- User-selected file read/write: enabled (backup/restore)
- Camera: enabled

**Info.plist**: `HavenApp/HavenApp/App/Info.plist`
- `NSAllowsLocalNetworking: true` (ATS exception for local relay)
- `NSAllowsArbitraryLoads: true` (HTTP for Blossom/media)

## Build Artifacts (not in git)

```
HavenApp/build/
├── libhaven.a          # macOS universal static library (~20 MB)
├── libhaven.h          # Auto-generated C header
├── libhaven-arm64.a    # Intermediate (deleted after lipo)
├── libhaven-x86_64.a   # Intermediate (deleted after lipo)
└── ios/
    ├── libhaven_ios.a  # iOS static library
    └── libhaven_ios.h  # iOS C header
```

## Clean Build

If Go changes aren't reflected after building:
- Xcode may cache the old `libhaven.a`
- Use **Cmd+Shift+K** (Clean Build Folder) in Xcode
- Or manually delete `HavenApp/build/libhaven.a`

## Archive Build (Release)

1. Product → Archive in Xcode
2. Universal binary created automatically (arm64 + x86_64 via lipo)
3. Distribute via: Copy App, TestFlight, or App Store Connect

## Upstream Sync (git subtree)

**Setup** (one-time):
```bash
git remote add upstream https://github.com/bitvora/haven.git
```

**Pull upstream changes**:
```bash
git subtree pull --prefix=haven-go upstream master
```

**Important**: Never use `--squash` — preserves upstream commit history on separate branch line.

**Conflict-prone files during sync**:
- `haven-go/init.go` — lazy init pattern, `CloseDBs()`, error returns
- `haven-go/main.go` — `isCShared()` early return guard
- `haven-go/cshared.go` / `cshared_stub.go` — downstream-only files

See `docs/upstream-sync.md` for detailed workflow.

## CI/CD

**GitHub Actions** (`.github/workflows/release.yml`):
- Triggers on tags matching `v*`
- Runs on `macos-latest`
- Steps: checkout → setup Go → setup Zig → import GPG key → goreleaser
- GoReleaser builds standalone binaries for macOS/Linux/Windows (not the app bundle)
- Signed with GPG fingerprint from secrets

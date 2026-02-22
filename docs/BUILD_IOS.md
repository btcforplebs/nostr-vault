# Building Haven for iOS

This document describes how to build the Haven app for iOS using the C-shared architecture.

## Overview

The C-shared architecture enables iOS builds by:
1. Compiling Go relay code as a C static library (`libhaven.a`)
2. Linking it directly into the iOS app's main process
3. Avoiding subprocess creation (forbidden on iOS)

## Prerequisites

- macOS with Xcode installed
- Go 1.21+
- iOS SDK (comes with Xcode)

## Build Script

The iOS build script is located at:
```
HavenApp/HavenApp/App/build_haven_ios.sh
```

### Usage

The script is designed to be run as an Xcode Run Script phase, but can also be run manually:

```bash
cd HavenApp/HavenApp/App
./build_haven_ios.sh
```

### Environment Variables

- `PROJECT_DIR` - Xcode project directory (auto-detected)
- `BUILT_PRODUCTS_DIR` - Xcode build products directory (auto-detected)
- `IPHONEOS_DEPLOYMENT_TARGET` - iOS version minimum (default: 15.0)
- `ARCHS` - Target architectures (arm64, x86_64)
- `SDKROOT` - iOS SDK (iphoneos or iphonesimulator)

## Integration with Xcode

### 1. Add the Build Script

In Xcode, add a "Run Script" build phase that calls `build_haven_ios.sh`:

```bash
# Run Script phase
"${SRCROOT}/HavenApp/App/build_haven_ios.sh"
```

### 2. Configure Build Settings

- **Header Search Paths**: Add `${PROJECT_DIR}/build/ios` to header search paths
- **Library Search Paths**: Add `${PROJECT_DIR}/build/ios` to library search paths  
- **Other Linker Flags**: Add `-lhaven` to link against the static library
- **Bridging Header**: Use existing `HavenApp-Bridging-Header.h`

### 3. iOS-Specific Code Adaptations

The Swift code needs modifications for iOS:

1. **Remove Menu Bar** - iOS doesn't support `NSStatusBar`
2. **Adapt Window Management** - Use `UIWindow` instead of `NSWindow`
3. **Platform Checks** - Use `#if os(iOS)` conditionals where needed

## Architecture Overview

```
┌─────────────────────────────────────────┐
│           iOS App (SwiftUI)             │
├─────────────────────────────────────────┤
│  HavenApp.swift                         │
│  ├── App entry point                    │
│  ├── UI views (Dashboard, Viewer, etc)  │
│  └── Services                           │
│      ├── RelayProcessManager (calls C) │
│      ├── WebSocketClient                │
│      └── ConfigService                  │
├─────────────────────────────────────────┤
│        libhaven.a (Go static lib)        │
│  ├── StartRelayC(0)                     │
│  ├── StopRelayC()                       │
│  └── Cgo bindings                       │
├─────────────────────────────────────────┤
│              iOS System                  │
│  ├── Foundation                         │
│  ├── UIKit/SwiftUI                      │
│  └── Network framework                  │
└─────────────────────────────────────────┘
```

## Building for Device vs Simulator

### Device Build
```bash
export SDKROOT=iphoneos
export ARCHS=arm64
./build_haven_ios.sh
```

### Simulator Build
```bash
export SDKROOT=iphonesimulator
export ARCHS="arm64 x86_64"  # For universal simulator
./build_haven_ios.sh
```

## Troubleshooting

### Error: "go" command not found
Ensure Go is installed and in your PATH:
```bash
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
```

### Error: iOS SDK not found
Ensure Xcode is properly installed:
```bash
xcode-select --print-path
xcrun --sdk iphoneos --show-sdk-path
```

### Linker errors
Make sure the library search path includes the build output directory:
```
${PROJECT_DIR}/build/ios
```

## See Also

- [C-Shared Relay Architecture](../docs/C_SHARED_RELAY.md)
- [macOS Build Guide](./BUILD_MAC.md)
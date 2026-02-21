# Building HAVEN for Mac

HAVEN for Mac is a native Swift wrapper around the [bitvora/haven](https://github.com/bitvora/haven) Go relay. The Go code is compiled into a static library (`libhaven.a`) and linked directly into the Swift app.

## Prerequisites

- [Go 1.24+](https://go.dev/dl/)
- macOS 14.0+
- Xcode 15+

## Build & Run (Development)

1.  Clone the repository:
    ```bash
    git clone https://github.com/btcforplebs/haven-mac.git
    cd haven-mac
    ```

2.  Open the project in Xcode:
    ```bash
    open HavenApp/HavenApp.xcodeproj
    ```

3.  Select the **HavenApp** scheme, set the destination to **My Mac**, and press **Cmd+R**.

Xcode automatically runs `build_haven.sh` during the build phase. This script:
1.  Navigates to the `haven-go/` directory.
2.  Builds the Go code as a C-archive (`go build -tags cshared -buildmode=c-archive`).
3.  Produces `libhaven.a` + `libhaven.h` which are linked into the app via a bridging header.

For archive builds (universal distribution), the script builds separate arm64 and x86_64 slices and combines them with `lipo`.

## Archive Build (Release)

1.  In Xcode, select **Product > Archive**.
2.  When the Organizer opens, select the archive and click **Distribute App**.
3.  Choose **Custom** > **Copy App** (or **App Store Connect** for TestFlight).
4.  Save `HAVEN.app` to your desired location.

## Verifying the Go Source

The Go code under `haven-go/` is the same code from [bitvora/haven](https://github.com/bitvora/haven), managed via `git subtree`. You can verify this by comparing commits:

```bash
git log --oneline haven-go/
```

Upstream commits appear on a separate branch line in the git graph. See [upstream-sync.md](./upstream-sync.md) for details.

---

**HAVEN for Mac** - Powered by [bitvora/haven](https://github.com/bitvora/haven)

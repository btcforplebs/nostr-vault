# How to Build & Install HAVEN for Mac

HAVEN for Mac is a native Swift wrapper around the original HAVEN Go implementation. Whether you're a developer or a security-conscious user, you can verify that the code running on your machine is exactly what you expect.

## 1. Verify the Backend (Go)

The core logic of HAVEN is 100% open-source Go. You don't need to trust our pre-compiled binary. You can build it yourself from this repository.

### Prerequisites

- [Go 1.24+](https://go.dev/dl/)

### Build Instructions

1.  Navigate to the Go source directory:
    ```bash
    cd haven-go
    ```

2.  Build the binary:
    ```bash
    go build -o haven .
    ```

3.  (Optional) Verify the hash of the release binary against your local build.
    > Note: Builds may vary slightly depending on Go version and OS environment. For a deterministic build, ensure you use the exact same Go version and flags as the release.

## 2. Verify the Frontend (Swift/Mac) & Install

The Mac application is a Swift project that embeds the Go binary.

### Prerequisites

- macOS 14.0+
- Xcode 15+

### Build & Install Instructions

1.  Open the project in Xcode:
    ```bash
    open HavenApp/HavenApp.xcodeproj
    ```

2.  **Archive the App**:
    - Go to `Product` > `Archive` in the menu bar.
    - Wait for the build to complete.
    - When the Organizer window appears, select your new archive and click **Distribute App**.
    - Choose **Custom** -> **Copy App**.
    - Save `HAVEN.app` to your desktop.

3.  **Install**:
    - Drag `HAVEN.app` into your **Applications** folder.
    - You're ready to go!

### Quick Build (Run without Installing)

1.  Open the project in Xcode.
2.  Build and Run (⌘R) to launch the app directly in the simulator or on your device.
    > Note: The Xcode project includes a run script that automatically builds the Go binary from `haven-go/` and places it into the app bundle.

## Manual Binary Replacement

If you downloaded the released `HAVEN.app` but want to use your own self-compiled Go binary:

1.  Build the Go binary as shown in Step 1.
2.  Right-click `HAVEN.app` in your Applications folder and select "Show Package Contents".
3.  Navigate to `Contents/Resources`.
4.  Replace the `haven` executable with your locally built binary.
5.  Restart the application.

---

**HAVEN for Mac** - Powered by [bitvora/haven](https://github.com/bitvora/haven)

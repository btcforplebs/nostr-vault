# Building & Verifying HAVEN for Mac

This guide is for users who want to build Haven themselves to verify the source code or contribute.

## Prerequisites

- **Go 1.21+**: [Install Go](https://go.dev/doc/install)
- **Xcode 15+**: Available on the Mac App Store.
- **Git**

## Step 1: Verify & Build the Go Core

The Go binary is the "brain" of Haven. You can build it independently to verify it matches the source code.

1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/btcforplebs/haven-mac.git
    cd haven-mac
    ```

2.  **Build the Go Binary**:
    ```bash
    go build -o haven_core
    ```
    This generates a file named `haven_core`. This is 99% of the project's logic.

## Step 2: Build the Mac App (Xcode)

The Mac App is the Swift wrapper that launches the Go binary.

1.  **Open the project in Xcode**:
    ```bash
    open HavenApp/HavenApp.xcodeproj
    ```

2.  **Select the Scheme**:
    - Choose **HavenApp** and set the destination to **My Mac**.

3.  **Run Build**:
    - Press `Cmd + B` to build or `Cmd + R` to run.

### How Xcode includes the Go Binary
Xcode automatically runs the script `HavenApp/HavenApp/App/build_haven.sh` during the build process. This script:
1.  Navigate to the root directory.
2.  Runs `go build`.
3.  Injects the resulting binary into the `Haven.app` bundle in the `Resources` folder.

## Manual Verification of a Release Build

If you downloaded a `HavenApp.zip` and want to verify the Go binary inside it:

1.  **Extract the app**.
2.  **Find the binary**: `HavenApp.app/Contents/Resources/haven`
3.  **Compare hashes**:
    Build your own binary as shown in Step 1 and compare the SHA256 hash:
    ```bash
    shasum -a 256 HavenApp.app/Contents/Resources/haven
    shasum -a 256 ./haven_core
    ```
    *Note: Small differences in hashes may occur due to build timestamps or paths, but you can inspect the code to ensure no malicious changes were made.*

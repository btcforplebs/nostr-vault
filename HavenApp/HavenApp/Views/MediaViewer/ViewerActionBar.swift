import SwiftUI
#if os(iOS)
import Photos
#endif

/// The one button row every full-screen viewer shows: Copy (the photo or
/// clip itself), Save, Share, then ··· for the link, Mirror and Delete.
/// Feed, DMs, the Media page and profile media all use it, so the buttons
/// do not change with the screen the photo was opened from.
///
/// Each viewer passes only what it knows: no `link` hides Copy link, no
/// `mirror` hides Mirror, no `onDelete` hides Delete, and with none of the
/// three the ··· goes too (a locked DM file stays on the phone).
struct ViewerActionBar: View {
    enum Mirror {
        /// Not on your media servers yet; the action copies it there.
        case offer(busy: Bool, action: () -> Void)
        /// This device's vault already has it: the only copy we know of.
        case done
    }

    let url: URL
    let isClip: Bool
    var link: String?
    var mirror: Mirror?
    var onDelete: ((MediaDeleteScope) -> Void)?

    @State private var copy: Progress = .idle
    @State private var save: Progress = .idle
    @State private var shareFile: ViewerShareFile?
    @State private var isPreparingShare = false

    private enum Progress { case idle, busy, done }

    static let doneGreen = Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8)

    var body: some View {
        // Short labels, and icons only when even those don't fit (larger
        // text, narrow phones): a squeezed capsule wraps its label one
        // letter per line.
        ViewThatFits(in: .horizontal) {
            row(showLabels: true)
            row(showLabels: false)
        }
        .shadow(color: Color.black.opacity(0.3), radius: 4)
        #if os(iOS)
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
        #endif
        // A new photo starts with fresh buttons, not the last one's "Copied".
        .onChange(of: url) { _, _ in
            copy = .idle
            save = .idle
        }
    }

    private func row(showLabels: Bool) -> some View {
        HStack(spacing: 6) {
            Button(action: copyTapped) {
                ViewerActionCapsule(
                    icon: copy == .done ? "checkmark.circle.fill" : "doc.on.doc",
                    label: copy == .done ? "Copied" : "Copy",
                    showLabel: showLabels,
                    fill: copy == .done ? Self.doneGreen : Color.black.opacity(0.6),
                    busy: copy == .busy
                )
            }
            .buttonStyle(.plain)
            .disabled(copy == .busy)
            .accessibilityLabel(copy == .done ? "Copied" : (isClip ? "Copy video" : "Copy photo"))

            #if os(iOS)
            Button(action: saveTapped) {
                ViewerActionCapsule(
                    icon: save == .done ? "checkmark.circle.fill" : "square.and.arrow.down",
                    label: save == .done ? "Saved" : "Save",
                    showLabel: showLabels,
                    fill: save == .done ? Self.doneGreen : Color.black.opacity(0.6),
                    busy: save == .busy
                )
            }
            .buttonStyle(.plain)
            .disabled(save != .idle)
            .accessibilityLabel(save == .done ? "Saved to Photos" : "Save to Photos")

            Button(action: shareTapped) {
                ViewerActionCapsule(icon: "square.and.arrow.up", label: "Share", showLabel: showLabels,
                                    fill: Color.black.opacity(0.6), busy: isPreparingShare)
            }
            .buttonStyle(.plain)
            .disabled(isPreparingShare)
            .accessibilityLabel("Share")
            #endif

            if link != nil || mirror != nil || onDelete != nil {
                moreMenu
            }
        }
    }

    /// Copy link, Mirror, Delete: the things you do less often, out of the
    /// way of the photo but not hidden behind a long-press.
    private var moreMenu: some View {
        Menu {
            if let link {
                Button {
                    PlatformClipboard.copy(link)
                    ActionToastManager.shared.show(icon: "link", message: "Link copied", tone: .success)
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
            switch mirror {
            case .offer(let busy, let action):
                Button(action: action) {
                    Label("Copy to your media servers", systemImage: "arrow.down.circle")
                }
                .disabled(busy)
            case .done:
                // `.done` only means this device's vault has the file
                // (`updateMirrorStatus`); no media server was asked.
                Button {} label: {
                    Label("In your vault", systemImage: "checkmark.circle")
                }
                .disabled(true)
            case nil:
                EmptyView()
            }
            if let onDelete {
                Divider()
                Button(role: .destructive) { onDelete(.mirrors) } label: {
                    Label("Delete from media servers", systemImage: "trash")
                }
                Button(role: .destructive) { onDelete(.everywhere) } label: {
                    Label("Delete everywhere", systemImage: "trash.fill")
                }
            }
        } label: {
            // Icon only: "···" says it, and a label would push the others
            // into icons sooner on narrow phones.
            ViewerActionCapsule(icon: "ellipsis", label: "", showLabel: false, fill: Color.black.opacity(0.6))
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    private func copyTapped() {
        copy = .busy
        let mediaURL = url
        let clip = isClip
        Task {
            do {
                let prepared = try await ViewerMediaTransfer.prepare(mediaURL, isClip: clip)
                try ViewerMediaTransfer.copy(prepared, isClip: clip)
                withAnimation(Motion.pop) { copy = .done }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(Motion.fade) { if copy == .done { copy = .idle } }
                }
            } catch {
                copy = .idle
                ErrorNotificationManager.shared.show(error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    #if os(iOS)
    private func saveTapped() {
        save = .busy
        let mediaURL = url
        let clip = isClip
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                save = .idle
                ErrorNotificationManager.shared.show("Allow Nostr Vault to add to Photos in Settings", icon: "exclamationmark.triangle.fill")
                return
            }
            do {
                let prepared = try await ViewerMediaTransfer.prepare(mediaURL, isClip: clip)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: clip ? .video : .photo, fileURL: prepared.file, options: nil)
                }
                save = .done
            } catch {
                save = .idle
                ErrorNotificationManager.shared.show("Couldn't save to Photos", icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func shareTapped() {
        isPreparingShare = true
        let mediaURL = url
        let clip = isClip
        Task {
            defer { isPreparingShare = false }
            do {
                let prepared = try await ViewerMediaTransfer.prepare(mediaURL, isClip: clip)
                shareFile = ViewerShareFile(url: prepared.file)
            } catch {
                ErrorNotificationManager.shared.show(error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }
    #endif
}

/// One capsule in the viewer's row: dark glass, white glyph, optional label.
struct ViewerActionCapsule: View {
    let icon: String
    let label: String
    let showLabel: Bool
    let fill: Color
    var busy: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: icon)
                    .font(.appSystem(size: 15, weight: .semibold))
            }
            if showLabel {
                Text(label)
                    .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundColor(.white.opacity(0.95))
        .padding(.vertical, 8)
        .padding(.horizontal, showLabel ? 11 : 9)
        .background(
            Capsule()
                .fill(fill)
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
    }
}

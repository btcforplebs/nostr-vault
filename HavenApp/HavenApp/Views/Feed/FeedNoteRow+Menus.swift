import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension FeedNoteRow {
    // MARK: - Glass User Menu

    func toggleUserMenu() {
        if showingUserMenu {
            dismissMenu(expanded: $menuExpanded, showing: $showingUserMenu)
        } else if FillYourVaultCoordinator.shared.meterShowing {
            // Fill your feed: the photo opens the profile card like the name,
            // rather than a Follow button that skips looking first.
            onProfile?(rowData.displayPubkey)
        } else if !rowData.isOwnNote {
            withAnimation(Motion.panel) {
                showingUserMenu = true
                menuExpanded = true
            }
        } else {
            onProfile?(rowData.displayPubkey)
        }
    }

    func toggleParentUserMenu() {
        if showingParentUserMenu {
            dismissMenu(expanded: $parentMenuExpanded, showing: $showingParentUserMenu)
        } else if FillYourVaultCoordinator.shared.meterShowing, let parent = rowData.parentNote {
            onProfile?(parent.pubkey)
        } else {
            withAnimation(Motion.panel) {
                showingParentUserMenu = true
                parentMenuExpanded = true
            }
        }
    }

    private func dismissMenu(expanded: Binding<Bool>, showing: Binding<Bool>) {
        withAnimation(Motion.panel) {
            expanded.wrappedValue = false
            showing.wrappedValue = false
        }
    }

    @ViewBuilder
    var userMenuToolbar: some View {
        let name = rowData.displayProfile?.bestName ?? "user"
        glassToolbar(
            pubkey: rowData.displayPubkey,
            displayName: name,
            isFollowed: rowData.isFollowed,
            expanded: menuExpanded
        ) {
            dismissMenu(expanded: $menuExpanded, showing: $showingUserMenu)
        }
    }

    @ViewBuilder
    var parentUserMenuToolbar: some View {
        if let parent = rowData.parentNote {
            let name = rowData.parentProfile?.bestName ?? "user"
            glassToolbar(
                pubkey: parent.pubkey,
                displayName: name,
                isFollowed: rowData.isParentFollowed,
                expanded: parentMenuExpanded
            ) {
                dismissMenu(expanded: $parentMenuExpanded, showing: $showingParentUserMenu)
            }
        }
    }

    /// The ⋯ menu on the note header: the secondary actions that do not
    /// fit the action bar, in the same order as Android's NoteCard menu.
    /// On a repost every item acts on the original the row shows, not the
    /// reposter: Android keys its menu on effectiveEventId the same way.
    var moreMenu: some View {
        Menu {
            ShareLink(
                item: URL(string: "https://mynostrspace.com/thread/\(bodySource.nevent)")!,
                subject: Text(String(localized: "feed.share.subject")),
                message: Text(String(localized: "feed.share.message"))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                copyToPasteboard("https://mynostrspace.com/thread/\(bodySource.nevent)")
                ActionToastManager.shared.show(icon: "link", message: "Link copied")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            if !bodySource.content.isEmpty {
                Button {
                    copyToPasteboard(bodySource.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    ActionToastManager.shared.show(icon: "doc.on.doc", message: "Text copied")
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }
            Divider()
            if rowData.isOwnNote {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    showingReportSheet = true
                } label: {
                    Label("Report Post", systemImage: "flag.fill")
                }
                Button(role: .destructive) {
                    showingBlockConfirm = true
                } label: {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func glassToolbar(pubkey: String, displayName: String, isFollowed: Bool, expanded: Bool, dismiss: @escaping () -> Void) -> some View {
        AuthorQuickMenu(
            pubkey: pubkey,
            displayName: displayName,
            isFollowed: isFollowed,
            expanded: expanded,
            onWebOfTrust: {
                trustWebPubkey = pubkey
                showingTrustWeb = true
            },
            dismiss: dismiss
        )
    }

    func actionButton(icon: String, color: Color = .secondary, count: Int? = nil, countLabel noun: String = "",
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(color)
                countText(count)
            }
            .padding(.horizontal, (count ?? 0) > 0 ? 10 : 0)
            .frame(minWidth: 32, minHeight: 32, maxHeight: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityValue(countLabel(count, noun))
        #if os(macOS)
        .onHover { inside in
            // Handle hover state if needed, though .hoverEffect handles it on iOS
        }
        #endif
    }
}

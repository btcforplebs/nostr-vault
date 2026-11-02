import SwiftUI

/// The Vault's way to the Bookmarks page, next to Messages.
struct VaultBookmarksButton: View {
    @Environment(\.filterButtonWidth) private var width
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "bookmark")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: width, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bookmarks")
        #if os(macOS)
        .help("Bookmarks")
        #endif
        .sheet(isPresented: $showing) {
            NavigationStack {
                BookmarksView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { showing = false } }
                    }
            }
            .environmentObject(NostrService.shared)
            .environmentObject(ConfigService.shared)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
    }
}

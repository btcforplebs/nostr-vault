import SwiftUI

extension NVShareIntent: Identifiable {}

/// The card every shared thing ends on before anything is signed: what was
/// shared, the action's own review (from its handler), and a way to throw it
/// away. Swiping it down keeps it for later.
struct SharePortalReviewSheet: View {
    let intent: NVShareIntent
    @ObservedObject var inbox: SharePortalInbox

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if intent.isStale() {
                    Label("Shared more than a week ago.", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                SharePortalRouter.handler(for: intent.action)
                    .review(intent) { inbox.finish(intent) }
            }
            .navigationTitle(intent.action.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { inbox.finish(intent) }
                }
            }
        }
    }
}

/// Opens the review sheet when the Share Portal has something waiting.
/// Attached once, to the iOS root.
struct SharePortalPresenter: ViewModifier {
    @ObservedObject private var inbox = SharePortalInbox.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $inbox.presented) { intent in
                SharePortalReviewSheet(intent: intent, inbox: inbox)
            }
            // A review left open when the app was killed comes back.
            .onAppear { inbox.reload(present: true) }
    }
}

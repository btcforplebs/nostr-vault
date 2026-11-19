import SwiftUI

/// Nuclear unfollow from a profile's ··· menu (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md):
/// the globe lights everyone you follow who follows `target`, and Show list
/// opens the checklist that cuts them (NuclearUnfollowListView).
struct NuclearUnfollowView: View {
    let target: String
    let name: String

    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss
    @State private var people: [String]?
    @State private var complete = true
    @State private var showingList = false

    private var follows: Set<String> { Set(FeedService.shared.followedPubkeys) }

    var body: some View {
        NavigationStack {
            Group {
                if let people {
                    TrustWebView(author: target, path: TrustPath.resolve(
                        author: target, follows: follows, trustGraph: [], bridges: people, complete: true))
                        .safeAreaInset(edge: .bottom) { showListBar(people) }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding who you follow that follows \(name)…")
                            .font(.appSystem(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Nuclear unfollow")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showingList) {
                NuclearUnfollowListView(target: target, name: name, people: people ?? [], complete: complete,
                                        followsTarget: follows.contains(target), onFinished: { dismiss() })
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 600)
        #endif
        .task(id: target) {
            let found = await NuclearUnfollowService.bridges(to: target)
            complete = found.complete
            people = found.people
        }
    }

    private func showListBar(_ people: [String]) -> some View {
        VStack(spacing: 6) {
            Text(people.isEmpty
                 ? "No one you follow follows \(name)."
                 : "\(people.count) of the people you follow follow \(name).")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Button { showingList = true } label: {
                Text("Show list")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(16)
        .background(.black.opacity(0.55))
    }
}

import SwiftUI

/// Settings > Recently Deleted: your posts deleted from this device in the
/// last 30 days, each with Un-delete and Delete forever. Android's twin is
/// `RecentlyDeletedSettingsScreen.kt`.
struct RecentlyDeletedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared

    @State private var posts: [DeletedPost] = []
    @State private var restoringId: String?
    @State private var pendingForget: DeletedPost?

    var body: some View {
        Form {
            Section {
                if posts.isEmpty {
                    Text("No deleted posts.").foregroundColor(.secondary)
                } else {
                    ForEach(posts) { post in
                        row(post)
                    }
                }
            } footer: {
                Text("Posts you delete on this device stay here for 30 days. \(DeletedPost.undeleteNote)")
            }
        }
        .groupedFormStyleCompat()
        .onAppear(perform: reload)
        .onChange(of: configService.config.activeAccountNpub) { _ in reload() }
        // A delete in another window (the Mac feed) while this page is open.
        .onReceive(NotificationCenter.default.publisher(for: DeletedPostsStore.didChange).receive(on: DispatchQueue.main)) { _ in reload() }
        .confirmDestructive(
            "Delete Forever",
            item: $pendingForget,
            consequence: { _ in "This removes the saved copy. You won't be able to un-delete this post." },
            confirmTitle: "Delete Forever"
        ) { post in
            DeletedPostsStore.shared.remove(id: post.id, account: post.pubkey)
            reload()
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ post: DeletedPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let images = imageURLs(in: post)
            let text = textWithoutMedia(post, removing: images)
            if !text.isEmpty {
                Text(text).lineLimit(4)
            }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(images, id: \.self) { url in
                            CachedAsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            Text("Deleted \(post.deletedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button {
                    restore(post)
                } label: {
                    if restoringId == post.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Un-delete")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(restoringId != nil)
                Spacer()
                Button("Delete Forever", role: .destructive) {
                    pendingForget = post
                }
                .buttonStyle(.bordered)
                .disabled(restoringId != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        let account = nostrService.activeHexPubkey
        posts = account.isEmpty ? [] : DeletedPostsStore.shared.posts(account: account)
    }

    private func restore(_ post: DeletedPost) {
        restoringId = post.id
        Task {
            let posted = await nostrService.undelete(post)
            restoringId = nil
            reload()
            if posted {
                ErrorNotificationManager.shared.show("Posted again.", icon: "arrow.uturn.backward.circle.fill", style: .warning)
            } else {
                ErrorNotificationManager.shared.show("Couldn't post it again: it wasn't signed, or no relay took it. The copy is kept here.")
            }
        }
    }

    private func imageURLs(in post: DeletedPost) -> [URL] {
        nostrService.extractMediaURLs(from: post.content).filter {
            NostrService.mediaTypeFromMime(NostrService.mimeFromExtension($0), url: $0) == .image
        }
    }

    /// The post's text with the image links taken out, since they show as
    /// thumbnails below it.
    private func textWithoutMedia(_ post: DeletedPost, removing images: [URL]) -> String {
        var text = post.content
        for url in images { text = text.replacingOccurrences(of: url.absoluteString, with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

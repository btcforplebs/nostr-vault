import SwiftUI

// MARK: - FeedView

struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var showingCompose = false
    @State private var replyToNote: FeedNote?
    @State private var showingRelayStatus = false

    var body: some View {
        NavigationView {
            ZStack {
                // Dark sophisticated background
                Color(red: 0.08, green: 0.08, blue: 0.12).ignoresSafeArea()

                Group {
                    if feedService.isLoadingContacts {
                        loadingContactsView
                    } else if feedService.followedPubkeys.isEmpty && !feedService.isLoadingFeed {
                        emptyStateView
                    } else {
                        feedList
                    }
                }
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.08, green: 0.08, blue: 0.12), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingRelayStatus = true }) {
                        Circle()
                            .fill(feedService.connectionStatus == "Live" ? Color(red: 0.2, green: 0.8, blue: 0.6) : Color(red: 1, green: 0.6, blue: 0.1))
                            .frame(width: 8, height: 8)
                            .shadow(color: feedService.connectionStatus == "Live" ? Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.6) : Color(red: 1, green: 0.6, blue: 0.1).opacity(0.4), radius: 3)
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            replyToNote = nil
                            showingCompose = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }

                        if feedService.newNoteCount > 0 && !configService.config.showReplies {
                            Button {
                                feedService.refresh()
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(feedService.newNoteCount)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(red: 0.2, green: 0.8, blue: 0.6))
                                )
                            }
                        } else {
                            Button {
                                feedService.refresh()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(red: 0.8, green: 0.2, blue: 0.6))
                                    .rotationEffect(.degrees(feedService.isLoadingFeed ? 360 : 0))
                                    .animation(
                                        feedService.isLoadingFeed ?
                                            .linear(duration: 1).repeatForever(autoreverses: false) :
                                            .default,
                                        value: feedService.isLoadingFeed
                                    )
                            }
                            .disabled(feedService.isLoadingContacts || feedService.isLoadingFeed)
                        }

                        Button(action: { configService.config.showReplies.toggle(); configService.save() }) {
                            Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(configService.config.showReplies ? Color(red: 0.8, green: 0.2, blue: 0.6) : .secondary)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            feedService.markViewed()
            if feedService.notes.isEmpty && !feedService.isLoadingContacts {
                if relayManager.isRunning && !relayManager.isBooting {
                    feedService.refresh()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { running in
            if running && !relayManager.isBooting && feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.refresh()
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(replyTo: replyToNote)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingRelayStatus) {
            RelayStatusSheet()
                .environmentObject(relayManager)
                .environmentObject(configService)
        }
    }

    // MARK: - Loading Contacts

    private var loadingContactsView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color(red: 0.8, green: 0.2, blue: 0.6))

                VStack(spacing: 8) {
                    Text("Synchronizing")
                        .font(.system(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text("fetching your follows")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text("This may take a moment")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.8, green: 0.2, blue: 0.6),
                                Color(red: 0.2, green: 0.8, blue: 0.6)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    Text("No Following Feed")
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .tracking(0.2)

                    Text("Start by following npubs on Nostr")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                }
            }

            Button {
                feedService.refresh()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh Feed")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.8, green: 0.2, blue: 0.6),
                            Color(red: 1.0, green: 0.3, blue: 0.4)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
    }

    // MARK: - Feed List

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Loading header
                if feedService.isLoadingFeed && feedService.notes.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        FeedNoteSkeletonRow()
                            .padding(.horizontal, 16)
                    }
                }

                ForEach(feedService.notes.filter { note in
                    configService.config.showReplies || !note.isReply
                }) { note in
                    NavigationLink(destination: NoteDetailView(note: note)) {
                        FeedNoteRow(note: note, profile: feedService.profiles[note.pubkey], onReply: {
                            replyToNote = note
                            showingCompose = true
                        })
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }

                // Load more
                if !feedService.notes.isEmpty {
                    Button {
                        feedService.loadMore()
                    } label: {
                        HStack(spacing: 8) {
                            if feedService.isLoadingFeed {
                                ProgressView().controlSize(.small).tint(Color(red: 0.8, green: 0.2, blue: 0.6))
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(feedService.isLoadingFeed ? "Loading..." : "Show earlier")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 1))
                        .padding(.horizontal, 16)
                    }
                    .disabled(feedService.isLoadingFeed)
                }

                Color.clear.frame(height: 20)
            }
            .padding(.vertical, 16)
        }
        .refreshable {
            feedService.refresh()
        }
    }
}

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    var onReply: (() -> Void)? = nil

    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService

    @State private var isExpanded = false
    @State private var isHovered = false
    private let maxCollapsedLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile?.bestName ?? shortKey(note.pubkey))
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .lineLimit(1)

                        if let nip05 = profile?.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                        }

                        Spacer()

                        Text(relativeTime(note.createdAt))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }

                    // Reply indicator - subtle
                    if note.isReply {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(red: 0.8, green: 0.2, blue: 0.6).opacity(0.6))

                            if let rPubkey = note.replyToPubkey {
                                Text("reply to \(shortKey(rPubkey))")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .tracking(0.1)
                            }
                        }
                    }
                }
            }

            // Parent Note Preview (if reply)
            if let pId = note.parentEventId, let parent = feedService.notes.first(where: { $0.id == pId }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color(red: 0.8, green: 0.2, blue: 0.6).opacity(0.3))
                            .frame(width: 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feedService.profiles[parent.pubkey]?.bestName ?? "Someone")
                                .font(.system(size: 11, weight: .semibold, design: .default))
                            Text(parent.content)
                                .font(.system(size: 11, weight: .regular, design: .default))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .background(Color(red: 0.15, green: 0.15, blue: 0.2))
                .cornerRadius(8)
            }

            // Content
            VStack(alignment: .leading, spacing: 8) {
                Text(formattedContent(note.content))
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : maxCollapsedLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { isExpanded.toggle() }

                // Expand button
                if needsExpansion && !isExpanded {
                    Button("expand") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.8, green: 0.2, blue: 0.6).opacity(0.8))
                    .tracking(0.2)
                }
            }

            // Media previews
            if !note.mediaURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(note.mediaURLs.prefix(3), id: \.absoluteString) { url in
                            FeedMediaThumbnail(url: url)
                        }
                    }
                }
                .frame(height: 110)
                .clipped()
            }

            // Actions row - minimal and clean
            HStack(spacing: 12) {
                actionButton(icon: "message", action: { onReply?() })
                actionButton(icon: "arrow.2.squarepath", action: { repostNote() })
                actionButton(icon: "quote.closing", action: { quoteNote() })
                actionButton(icon: "heart", action: { likeNote() })
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: note.isReply ? 1.2 : 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .hoverEffect(.lift)
        .clipped()
    }

    private func actionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 28, height: 28)
        }
    }

    private func likeNote() {
        guard let signed = nostrService.signEvent(kind: 7, content: "+", tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    private func repostNote() {
        guard let signed = nostrService.signEvent(kind: 6, content: "", tags: [["e", note.id, "", "root"], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    private func quoteNote() {
        let quoteContent = "nostr:note\(note.id)\n\n—\n"
        onReply?()
    }

    private var needsExpansion: Bool {
        note.content.count > 400
    }

    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    private func formattedContent(_ content: String) -> String {
        // Strip bare image/video URLs from text (they'll show as thumbnails)
        var text = content
        for url in note.mediaURLs {
            text = text.replacingOccurrences(of: url.absoluteString, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}

// MARK: - FeedMediaThumbnail

struct FeedMediaThumbnail: View {
    let url: URL
    @State private var image: PlatformImage?
    @State private var isVideo = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                .frame(width: 90, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let ext = url.pathExtension.lowercased()
        isVideo = ["mp4", "mov", "webm", "m4v"].contains(ext)
        guard !isVideo && image == nil else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let img = PlatformImage(data: data) {
                DispatchQueue.main.async { image = img }
            }
        }.resume()
    }
}

// MARK: - AvatarView

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 40, height: 40)

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Text(String(pubkey.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Circle()
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5)
                .frame(width: 40, height: 40)
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _ in loadImage() }
    }

    private var avatarGradient: LinearGradient {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        let hue = Double(first % 360) / 360.0
        let saturation = 0.6 + Double((first / 10) % 30) / 100.0

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: 0.75),
                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage() {
        guard let url = url, image == nil else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let img = PlatformImage(data: data) {
                DispatchQueue.main.async { image = img }
            }
        }.resume()
    }
}

// MARK: - Skeleton Loading Row

struct FeedNoteSkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                        .frame(width: 100, height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                        .frame(width: 60, height: 10)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                    .frame(width: 180, height: 12)
            }

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.2))
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Relay Status Sheet

struct RelayStatusSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Main Relay Status
                        Section {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(relayManager.isRunning ? Color(red: 0.2, green: 0.8, blue: 0.6) : Color(red: 1, green: 0.6, blue: 0.1))
                                        .frame(width: 12, height: 12)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Haven Relay")
                                            .font(.system(size: 16, weight: .bold))
                                        Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Connected" : "Disconnected"))
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Text("127.0.0.1:\(configService.config.relayPort)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(12)
                                .background(Color(red: 0.12, green: 0.12, blue: 0.16))
                                .cornerRadius(10)
                            }
                        } header: {
                            Text("Write Relay")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                                .tracking(0.5)
                        }
                        .padding(.horizontal)

                        Divider()
                            .padding(.vertical, 8)

                        // Blastr Distribution
                        Section {
                            VStack(spacing: 8) {
                                Text("Configured for distribution to \(configService.config.blastrRelays.count) relays")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(configService.config.blastrRelays.prefix(5), id: \.self) { relay in
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(red: 0.8, green: 0.2, blue: 0.6).opacity(0.3))
                                                .frame(width: 4, height: 4)

                                            Text(relay)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.secondary.opacity(0.8))
                                                .lineLimit(1)
                                        }
                                    }

                                    if configService.config.blastrRelays.count > 5 {
                                        Text("+ \(configService.config.blastrRelays.count - 5) more")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.6))
                                            .padding(.top, 4)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(red: 0.12, green: 0.12, blue: 0.16))
                            .cornerRadius(10)
                        } header: {
                            Text("Blastr Distribution")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                                .tracking(0.5)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }

                Divider()

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.8, green: 0.2, blue: 0.6))
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("Relay Status")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(red: 0.08, green: 0.08, blue: 0.12))
        }
    }
}

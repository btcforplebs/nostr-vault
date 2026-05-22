import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation

/// Imports a PhotosPickerItem video as a file URL on disk, avoiding loading the
/// entire video into memory. The system writes the picked file into our app's
/// temp area; we copy it to a known location we can clean up later.
struct ImportedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedVideoFile(url: dest)
        }
    }
}

struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var content: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var isUploading = false
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var isTextEditorFocused: Bool
    
    @StateObject private var uploadInfoProvider = MediaUploadsIndicatorInfoProvider()

    // @mention state
    @State private var mentionQuery: String? = nil          // nil = popup hidden
    @State private var mentionResults: [FeedProfile] = []
    @State private var taggedPubkeys: [String] = []         // hex pubkeys of tagged users

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    // Optional: for replies
    var replyTo: FeedNote?
    // Optional: for quote posts
    var quoteTo: FeedNote?
    // Optional: pre-filled content (used when editing a pending post)
    var initialContent: String = ""
    
    struct Attachment: Identifiable {
        let id = UUID()
        // Exactly one of `data` or `fileURL` is set. Images use `data` (small,
        // possibly transcoded); videos use `fileURL` so they stream from disk.
        let data: Data?
        let fileURL: URL?
        var type: UTType
        var url: URL?
        var isUploaded: Bool = false
        var thumbnail: PlatformImage?
    }
    
    var body: some View {
        Group {
            #if os(macOS)
            composeContent
                .frame(minWidth: 500, idealWidth: 500, minHeight: 400, idealHeight: 450)
            #else
            NavigationView {
                composeContent
            }
            #endif
        }
    }

    private var composeContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                #if os(macOS)
                header
                #endif

                ScrollView {
                    VStack(spacing: 16) {
                        if let parent = replyTo {
                            replyHeader(parent: parent)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(
                                url: nostrService.profiles[configService.activeAccountHexPubkey]?.pictureURL,
                                pubkey: configService.activeAccountHexPubkey
                            )
                            .frame(width: 36, height: 36)
                            .contextMenu {
                                if configService.allAccountNpubs.count > 1 {
                                    ForEach(configService.allAccountNpubs, id: \.self) { npub in
                                        let isOwner = npub == configService.config.ownerNpub
                                        let activeAccountNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let isActive = activeAccountNpub.isEmpty ? isOwner : npub == activeAccountNpub
                                        let hex = Bech32.decode(npub)?.hexString ?? ""
                                        let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))
                                        
                                        Button {
                                            configService.switchActiveAccount(to: npub)
                                        } label: {
                                            if isActive {
                                                Label(name, systemImage: "checkmark")
                                            } else {
                                                Text(name)
                                            }
                                        }
                                    }
                                } else {
                                    Text("No other accounts")
                                }
                            }
                            
                            ZStack(alignment: .topLeading) {
                                if content.isEmpty {
                                    Text("What's happening?")
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(.top, 10)
                                        .padding(.leading, 4)
                                }
                                
                                TextEditor(text: $content)
                                    .focused($isTextEditorFocused)
                                    .font(.system(size: 16))
                                    .frame(minHeight: 200)
                                    .scrollContentBackground(.hidden)
                                    .onChange(of: content) { _, newValue in
                                        updateMentionQuery(in: newValue)
                                    }
                            }
                        }
                        
                        if !attachments.isEmpty {
                            attachmentGrid
                        }

                        if let quoted = quoteTo {
                            QuotedNoteView(note: quoted)
                                .environmentObject(nostrService)
                        }
                    }
                    .padding(20)
                }
                
                Spacer()
                
                footer
            }

            // @mention popup
            if let _ = mentionQuery, !mentionResults.isEmpty {
                mentionPopup
                    .padding(.bottom, 60) // sits just above the footer toolbar
            }
        }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle(replyTo != nil ? "Reply" : quoteTo != nil ? "Quote" : "New Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { performDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { postNote() }
                        .disabled((content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || isPosting)
                        .fontWeight(.bold)
                }
                #endif
            }
            .alert("Error", isPresented: Binding<Bool>(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                if let error = error {
                    Text(error)
                }
            }
            .onAppear {
                if !initialContent.isEmpty { content = initialContent }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isTextEditorFocused = true
                }
            }
            .onDisappear {
                cleanupAttachmentTempFiles()
            }

    }

    // MARK: - @mention popup

    private var mentionPopup: some View {
        VStack(spacing: 0) {
            ForEach(mentionResults.prefix(5)) { profile in
                Button {
                    insertMention(profile)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(url: profile.pictureURL, pubkey: profile.pubkey, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.bestName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if profile.id != mentionResults.prefix(5).last?.id {
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformControlBackground)
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: mentionResults.count)
    }

    /// Called every time `content` changes — finds the @query at the cursor tail.
    private func updateMentionQuery(in text: String) {
        // Look for the last `@` that hasn't been terminated by whitespace or newline
        guard let atRange = text.range(of: "@", options: .backwards) else {
            mentionQuery = nil
            mentionResults = []
            return
        }

        let queryStart = text.index(after: atRange.lowerBound)
        let tail = String(text[queryStart...])

        // If there is whitespace or newline after the @, the mention is done
        if tail.contains(" ") || tail.contains("\n") {
            mentionQuery = nil
            mentionResults = []
            return
        }

        mentionQuery = tail
        filterMentionResults(query: tail)
    }

    private func filterMentionResults(query: String) {
        let followed = FeedService.shared.followedPubkeys
        let allProfiles = followed.compactMap { nostrService.profiles[$0] }

        if query.isEmpty {
            // Show first 5 followed profiles when query is empty (just typed @)
            mentionResults = Array(allProfiles.prefix(5))
        } else {
            let lower = query.lowercased()
            mentionResults = allProfiles.filter { profile in
                (profile.bestName.lowercased().contains(lower)) ||
                (profile.name?.lowercased().contains(lower) ?? false) ||
                (profile.nip05?.lowercased().contains(lower) ?? false)
            }
        }
    }

    private func insertMention(_ profile: FeedProfile) {
        // Encode pubkey as npub
        guard let data = Bech32.hexToData(profile.pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }

        // Replace the trailing `@query` with `nostr:npub1...`
        if let atRange = content.range(of: "@", options: .backwards) {
            content = String(content[content.startIndex..<atRange.lowerBound])
                + "nostr:\(npub) "
        } else {
            content += "nostr:\(npub) "
        }

        // Track the mention so we can add the `p` tag
        if !taggedPubkeys.contains(profile.pubkey) {
            taggedPubkeys.append(profile.pubkey)
        }

        withAnimation {
            mentionQuery = nil
            mentionResults = []
        }
    }

    #if os(macOS)
    private var header: some View {
        HStack {
            Button("Cancel") { performDismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(replyTo != nil ? "Reply" : quoteTo != nil ? "Quote" : "New Note")
                .font(.headline)
            
            Spacer()
            
            Button("Post") { postNote() }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled((content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || isPosting)
        }
        .padding()
        .background(Color.platformControlBackground.opacity(0.5))
    }
    #endif

    private var footer: some View {
        let purple = Color.havenPurple
        return HStack(spacing: 12) {
            PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, 4 - attachments.count), matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            
            PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, 4 - attachments.count), matching: .videos) {
                Image(systemName: "video.fill")
                    .font(.title3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            if isUploading, let msg = uploadInfoProvider.uploadMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            } else if isPosting {
                Text("Posting note...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            
            Text("\(content.count)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(content.count > 280 ? .red : .secondary)
                .padding(.trailing, 8)
        }
        .padding()
        .background(Color.platformControlBackground)
        .onChange(of: selectedItems) { _, _ in loadSelectedItems() }
    }
    
    private func replyHeader(parent: FeedNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                AvatarView(url: nostrService.profiles[parent.pubkey]?.pictureURL, pubkey: parent.pubkey)
                    .frame(width: 32, height: 32)
                
                Rectangle()
                    .fill(Color.havenPurple.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Replying to \(nostrService.profiles[parent.pubkey]?.bestName ?? String(parent.pubkey.prefix(8)))...")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text(parent.content)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(3)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.havenPurple.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.15), lineWidth: 1)
        )
    }
    
    private var attachmentGrid: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(platformImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let data = attachment.data, let img = PlatformImage(data: data) {
                                Image(platformImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                ZStack {
                                    Color.platformSecondaryGroupedBackground
                                    Image(systemName: attachment.type.conforms(to: .movie) || attachment.type.conforms(to: .video) ? "video.fill" : "doc.fill")
                                        .font(.title)
                                        .foregroundColor(Color.havenPurple.opacity(0.8))
                                }
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.havenPurple.opacity(0.3), lineWidth: 1)
                                )
                            }
                        }
                        
                        if attachment.type.conforms(to: .movie) || attachment.type.conforms(to: .video) {
                            ZStack {
                                Circle()
                                    .fill(.black.opacity(0.4))
                                    .frame(width: 32, height: 32)
                                
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .offset(x: 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        Button {
                            if let fileURL = attachment.fileURL {
                                try? FileManager.default.removeItem(at: fileURL)
                            }
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(4)
                    }
                }
            }
            .padding()
        }
        .frame(height: 120)
    }
    
    private func loadSelectedItems() {
        for item in selectedItems {
            // Get the specific content type
            let contentType = item.supportedContentTypes.first ?? .image
            let isVideo = contentType.conforms(to: .movie) || contentType.conforms(to: .video)

            if isVideo {
                loadVideoItem(item, contentType: contentType)
            } else {
                loadImageItem(item, contentType: contentType)
            }
        }
        selectedItems = []
    }

    private func loadVideoItem(_ item: PhotosPickerItem, contentType: UTType) {
        item.loadTransferable(type: ImportedVideoFile.self) { result in
            switch result {
            case .success(let video):
                guard let video = video else { return }
                let thumbnail = self.generateVideoThumbnail(url: video.url)
                // Prefer the actual file extension's UTType (e.g. .mpeg4Movie)
                // so preferredMIMEType yields the right Content-Type on upload.
                let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                DispatchQueue.main.async {
                    self.attachments.append(Attachment(
                        data: nil,
                        fileURL: video.url,
                        type: derivedType,
                        thumbnail: thumbnail
                    ))
                }
            case .failure(let error):
                print("Failed to load video: \(error)")
            }
        }
    }

    private func loadImageItem(_ item: PhotosPickerItem, contentType: UTType) {
        item.loadTransferable(type: Data.self) { result in
            switch result {
            case .success(let data):
                guard let data = data else { return }
                DispatchQueue.main.async {
                    var finalData = data
                    var finalType = contentType

                    // Convert HEIC/HEIF to JPEG
                    if contentType.conforms(to: .heic) || contentType.conforms(to: .heif) {
                        #if os(iOS)
                        if let image = UIImage(data: data),
                           let jpegData = image.jpegData(compressionQuality: 0.8) {
                            finalData = jpegData
                            finalType = .jpeg
                        }
                        #elseif os(macOS)
                        if let image = NSImage(data: data),
                           let tiffData = image.tiffRepresentation,
                           let bitmapRep = NSBitmapImageRep(data: tiffData),
                           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            finalData = jpegData
                            finalType = .jpeg
                        }
                        #endif
                    }

                    self.attachments.append(Attachment(
                        data: finalData,
                        fileURL: nil,
                        type: finalType,
                        thumbnail: nil
                    ))
                }
            case .failure(let error):
                print("Failed to load media: \(error)")
            }
        }
    }
    
    /// Computes the SHA256 of a file by streaming it in 1 MB chunks so large
    /// videos don't sit fully in memory.
    nonisolated static func streamingSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private func cleanupAttachmentTempFiles() {
        for attachment in attachments {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func generateVideoThumbnail(url: URL) -> PlatformImage? {
        let asset = AVAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            #if os(macOS)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #else
            return UIImage(cgImage: cgImage)
            #endif
        } catch {
            print("Error generating video thumbnail: \(error)")
            return nil
        }
    }
    
    private func postNote() {
        isPosting = true
        uploadInfoProvider.startUpload(totalCount: attachments.count)

        Task {
            // 1. Upload media to Blossom mirrors
            var finalContent = content
            isUploading = true

            // Upload all attachments and fail if any fail
            for i in attachments.indices {
                uploadInfoProvider.setCurrentIndex(i + 1, type: attachments[i].type)
                let mimeType = attachments[i].type.preferredMIMEType ?? "application/octet-stream"
                let progressHandler: (Double) -> Void = { progressFraction in
                    self.uploadInfoProvider.updateProgress(progressFraction)
                }

                let uploadedURL: URL?
                if let fileURL = attachments[i].fileURL {
                    guard let sha256 = ComposeView.streamingSHA256(of: fileURL) else {
                        DispatchQueue.main.async {
                            error = "Failed to read video file for upload."
                            isPosting = false
                            isUploading = false
                            uploadInfoProvider.reset()
                        }
                        return
                    }
                    uploadedURL = await blossomService.uploadAndMirror(
                        fileURL: fileURL,
                        sha256: sha256,
                        contentType: mimeType,
                        progress: progressHandler
                    )
                } else if let data = attachments[i].data {
                    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    uploadedURL = await blossomService.uploadAndMirror(
                        data: data,
                        sha256: sha256,
                        contentType: mimeType,
                        progress: progressHandler
                    )
                } else {
                    uploadedURL = nil
                }

                guard let url = uploadedURL else {
                    DispatchQueue.main.async {
                        error = "Failed to upload media to Blossom mirrors. Check your connection and try again."
                        isPosting = false
                        isUploading = false
                        uploadInfoProvider.reset()
                    }
                    return
                }
                attachments[i].url = url
                attachments[i].isUploaded = true
                finalContent += "\n\(url.absoluteString)"
            }
            isUploading = false
            uploadInfoProvider.reset()
            cleanupAttachmentTempFiles()

            // 2. Build Event
            var tags: [[String]] = []
            if let parent = replyTo {
                // NIP-10 tags — for reposts (kind 6), reply to the original note, not the repost
                if parent.kind == 6, let originalId = parent.repostedEventId {
                    tags.append(["e", originalId, "", "reply"])
                    // Resolve the original note's author; fall back to the parent's pubkey
                    if let original = FeedService.shared.notes.first(where: { $0.id == originalId }) {
                        tags.append(["p", original.pubkey])
                    } else {
                        tags.append(["p", parent.pubkey])
                    }
                } else {
                    tags.append(["e", parent.id, "", "reply"])
                    tags.append(["p", parent.pubkey])
                }
            }

            // @mention p-tags
            for mentionedPubkey in taggedPubkeys {
                // Avoid duplicating p-tags already added for reply/quote
                let alreadyTagged = tags.contains { $0.first == "p" && $0.count > 1 && $0[1] == mentionedPubkey }
                if !alreadyTagged {
                    tags.append(["p", mentionedPubkey])
                }
            }

            // Quote post: append nevent reference and q tag
            if let quoted = quoteTo {
                finalContent += "\nnostr:\(quoted.nevent)"
                tags.append(["q", quoted.id])
                tags.append(["p", quoted.pubkey])
            }

            // 3. Sign
            guard let event = nostrService.signEvent(kind: 1, content: finalContent, tags: tags) else {
                DispatchQueue.main.async {
                    error = "Failed to sign event. Do you have your private key set in Settings?"
                    isPosting = false
                }
                return
            }

            DispatchQueue.main.async {
                // Add to local feed immediately for preview
                let feedNote = FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                )
                FeedService.shared.addNote(feedNote)

                // Hand to PendingPostManager — it will broadcast after countdown
                PendingPostManager.shared.startPost(
                    event: event,
                    content: finalContent,
                    replyTo: self.replyTo,
                    quoteTo: self.quoteTo,
                    nostrService: self.nostrService
                )

                isPosting = false
                performDismiss()
            }
        }
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

class MediaUploadsIndicatorInfoProvider: ObservableObject {
    @Published var isUploading: Bool = false
    @Published var totalCount: Int = 0
    @Published var currentIndex: Int = 0
    @Published var uploadMessage: String? = nil
    @Published var currentProgress: Double = 0.0
    private var currentType: UTType = .image
    
    func startUpload(totalCount: Int) {
        DispatchQueue.main.async {
            self.isUploading = true
            self.totalCount = totalCount
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = totalCount > 0 ? "Preparing uploads..." : nil
        }
    }
    
    func setCurrentIndex(_ index: Int, type: UTType) {
        DispatchQueue.main.async {
            self.currentIndex = index
            self.currentType = type
            self.currentProgress = 0.0
            self.updateMessage()
        }
    }
    
    func updateProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.currentProgress = progress
            self.updateMessage()
        }
    }
    
    private func updateMessage() {
        let isVideo = self.currentType.conforms(to: .movie) || self.currentType.conforms(to: .video)
        let mediaType = isVideo ? "video" : "image"
        let pct = Int(self.currentProgress * 100)
        if self.totalCount > 1 {
            self.uploadMessage = "Uploading \(mediaType) (\(self.currentIndex) of \(self.totalCount)) - \(pct)%..."
        } else {
            self.uploadMessage = "Uploading \(mediaType) - \(pct)%..."
        }
    }
    
    func reset() {
        DispatchQueue.main.async {
            self.isUploading = false
            self.totalCount = 0
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = nil
        }
    }
}

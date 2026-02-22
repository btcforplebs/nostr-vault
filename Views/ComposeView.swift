import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit

struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var content: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var isUploading = false
    @State private var isPosting = false
    @State private var error: String?

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    // Optional: for replies
    var replyTo: FeedNote?

    struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let type: UTType
        var url: URL?
        var isUploaded: Bool = false
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let parent = replyTo {
                    replyHeader(parent: parent)
                }

                TextEditor(text: $content)
                    .padding(12)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        Group {
                            if content.isEmpty {
                                Text("What's happening?")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 20)
                                    .padding(.leading, 16)
                                    .allowsHitTesting(false)
                            }
                        },
                        alignment: .topLeading
                    )

                if !attachments.isEmpty {
                    attachmentGrid
                }

                Spacer()

                HStack {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundColor(.havenPurple)
                            .padding(12)
                    }
                    .onChange(of: selectedItems) { _ in loadSelectedItems() }

                    Spacer()

                    if isUploading || isPosting {
                        ProgressView().controlSize(.small).padding(.trailing, 8)
                    }

                    Text("\(content.count)")
                        .font(.caption.monospaced())
                        .foregroundColor(content.count > 280 ? .red : .secondary)
                        .padding(.trailing, 8)
                }
                .padding(.horizontal)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .navigationTitle(replyTo == nil ? "New Note" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Post") { postNote() }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                        .bold()
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                if let error = error { Text(error) }
            }
        }
    }

    private func replyHeader(parent: FeedNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.secondary.opacity(0.2)).frame(width: 4, height: 4).padding(.top, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(parent.pubkey.prefix(8))...")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text(parent.content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
    }

    private var attachmentGrid: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let uiImage = UIImage(data: attachment.data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
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
            item.loadTransferable(type: Data.self) { result in
                switch result {
                case .success(let data):
                    if let data = data {
                        DispatchQueue.main.async {
                            self.attachments.append(Attachment(data: data, type: .image))
                        }
                    }
                case .failure(let error):
                    print("Failed to load photo: \(error)")
                }
            }
        }
        selectedItems = []
    }

    private func postNote() {
        isPosting = true

        Task {
            // 1. Upload media to Blossom (local) and mirror to external servers
            var finalContent = content
            isUploading = true
            for i in attachments.indices {
                let sha256 = SHA256.hash(data: attachments[i].data).map { String(format: "%02x", $0) }.joined()
                if let url = await blossomService.uploadAndMirror(data: attachments[i].data, sha256: sha256) {
                    attachments[i].url = url
                    attachments[i].isUploaded = true
                    finalContent += "\n\(url.absoluteString)"
                }
            }
            isUploading = false

            // 2. Build Event
            var tags: [[String]] = []
            if let parent = replyTo {
                // NIP-10 tags
                tags.append(["e", parent.id, "", "reply"])
                tags.append(["p", parent.pubkey])
            }

            // 3. Sign
            guard let event = nostrService.signEvent(kind: 1, content: finalContent, tags: tags) else {
                error = "Failed to sign event. Do you have your private key set in Settings?"
                isPosting = false
                return
            }

            // 4. Post
            nostrService.postEvent(event)

            DispatchQueue.main.async {
                // Immediate feedback in feed
                let feedNote = FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                )
                FeedService.shared.insertNote(feedNote)

                isPosting = false
                dismiss()
            }
        }
    }

}

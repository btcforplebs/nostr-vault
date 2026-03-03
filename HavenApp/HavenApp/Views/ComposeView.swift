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
        var type: UTType
        var url: URL?
        var isUploaded: Bool = false
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
        VStack(spacing: 0) {
                #if os(macOS)
                header
                #endif

                ScrollView {
                    VStack(spacing: 16) {
                        if let parent = replyTo {
                            replyHeader(parent: parent)
                        }
                        
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's happening?")
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .padding(.top, 10)
                                    .padding(.leading, 4)
                            }
                            
                            TextEditor(text: $content)
                                .font(.system(size: 16))
                                .frame(minHeight: 200)
                                .scrollContentBackground(.hidden)
                        }
                        
                        if !attachments.isEmpty {
                            attachmentGrid
                        }
                    }
                    .padding(20)
                }
                
                Spacer()
                
                footer
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle(replyTo == nil ? "New Note" : "Reply")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { postNote() }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
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

    }

    #if os(macOS)
    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(replyTo == nil ? "New Note" : "Reply")
                .font(.headline)
            
            Spacer()
            
            Button("Post") { postNote() }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
        }
        .padding()
        .background(Color.platformControlBackground.opacity(0.5))
    }
    #endif

    private var footer: some View {
        HStack {
            PhotosPicker(selection: $selectedItems, maxSelectionCount: 4, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                    .foregroundColor(Color.havenPurple)
                    .padding(10)
                    .background(Color.havenPurple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onChange(of: selectedItems) { _, _ in loadSelectedItems() }
            
            Spacer()
            
            if isUploading || isPosting {
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            
            Text("\(content.count)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(content.count > 280 ? .red : .secondary)
                .padding(.trailing, 8)
        }
        .padding()
        .background(Color.platformControlBackground)
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
                        if let img = PlatformImage(data: attachment.data) {
                            Image(platformImage: img)
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
            // Get the specific content type
            let contentType = item.supportedContentTypes.first ?? .image
            
            item.loadTransferable(type: Data.self) { result in
                switch result {
                case .success(let data):
                    if let data = data {
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
                            
                            self.attachments.append(Attachment(data: finalData, type: finalType))
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
            // 1. Upload media to Blossom mirrors
            var finalContent = content
            isUploading = true

            // Upload all attachments and fail if any fail
            for i in attachments.indices {
                let sha256 = SHA256.hash(data: attachments[i].data).map { String(format: "%02x", $0) }.joined()
                let mimeType = attachments[i].type.preferredMIMEType ?? "application/octet-stream"
                guard let url = await blossomService.uploadAndMirror(data: attachments[i].data, sha256: sha256, contentType: mimeType) else {
                    DispatchQueue.main.async {
                        error = "Failed to upload image to Blossom mirrors. Check your connection and try again."
                        isPosting = false
                        isUploading = false
                    }
                    return
                }
                attachments[i].url = url
                attachments[i].isUploaded = true
                finalContent += "\n\(url.absoluteString)"
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
                DispatchQueue.main.async {
                    error = "Failed to sign event. Do you have your private key set in Settings?"
                    isPosting = false
                }
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
                FeedService.shared.addNote(feedNote)

                isPosting = false
                dismiss()
            }
        }
    }
}

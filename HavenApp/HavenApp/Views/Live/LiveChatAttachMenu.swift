import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The chat composer's media button: a photo or video from the library,
/// uploaded to the owner's media servers; a GIF; or a file already on the
/// relay. Each lands in the message as its link, which the chat row draws
/// as the picture, GIF or video. A chat message is text, so the link is the
/// attachment, as in every other live chat.
struct LiveChatAttachMenu: View {
    var onLink: (URL) -> Void
    var onError: (String) -> Void
    var beforeOpening: () -> Void = {}

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var showingLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var showingGifs = false
    @State private var showingRelayMedia = false
    @State private var relayMedia: [MediaItem] = []
    @State private var isLoadingRelayMedia = false
    @State private var isUploading = false

    var body: some View {
        Menu {
            Button {
                beforeOpening()
                showingLibrary = true
            } label: {
                Label("Photo or video", systemImage: "photo.on.rectangle")
            }
            Button {
                beforeOpening()
                showingGifs = true
            } label: {
                Label("GIF", systemImage: "face.smiling")
            }
            Button {
                beforeOpening()
                showingRelayMedia = true
            } label: {
                Label("From your relay", systemImage: "externaldrive")
            }
        } label: {
            Group {
                if isUploading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.appSystem(size: 19, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Add a photo, video or GIF")
        #else
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .disabled(isUploading)
        .accessibilityLabel(isUploading ? "Uploading media" : "Add a photo, video or GIF")
        .photosPicker(isPresented: $showingLibrary, selection: $libraryItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            upload(item)
        }
        .sheet(isPresented: $showingGifs) {
            GifPickerSheet { item in
                showingGifs = false
                attachGif(item)
            }
        }
        .sheet(isPresented: $showingRelayMedia) {
            BlossomMediaPickerSheet(
                blossomMedia: $relayMedia,
                isLoading: $isLoadingRelayMedia,
                onSelect: { item in
                    onLink(item.shareURL(with: configService))
                    showingRelayMedia = false
                },
                onAppearLoad: { loadRelayMedia() }
            )
            .environmentObject(configService)
        }
    }

    // MARK: - Library

    /// Uploads to the outside media servers the composer uses, so the link
    /// works for everyone in the stream, not only this device's relay.
    private func upload(_ item: PhotosPickerItem) {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                let blob: ModePostPublisher.UploadedBlob
                var ext = "mp4"
                if isVideo {
                    guard let video = try await item.loadTransferable(type: ImportedVideoFile.self) else {
                        throw ModePostPublisher.PublishError.upload("Couldn't read that video.")
                    }
                    defer { try? FileManager.default.removeItem(at: video.url) }
                    let type = UTType(filenameExtension: video.url.pathExtension) ?? .mpeg4Movie
                    ext = type.preferredFilenameExtension ?? "mp4"
                    blob = try await ModePostPublisher.upload(
                        fileURL: video.url, mimeType: type.preferredMIMEType ?? "video/mp4",
                        configService: configService, nostrService: nostrService)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ModePostPublisher.PublishError.upload("Couldn't read that photo.")
                    }
                    let picked = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                    let (photo, type) = Self.jpegIfHEIC(data, type: picked)
                    blob = try await ModePostPublisher.upload(
                        data: photo, mimeType: type.preferredMIMEType ?? "image/jpeg",
                        configService: configService, nostrService: nostrService)
                    ext = type.preferredFilenameExtension ?? "jpg"
                }
                onLink(Self.link(blob.url, extension: ext))
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Blossom answers with `<server>/<sha256>` and sometimes no extension;
    /// the chat (ours and other apps') decides photo or video by the file's
    /// extension, so a bare hash would show as a plain link.
    static func link(_ url: URL, extension ext: String) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(ext) : url
    }

    /// HEIC as JPEG, as the note composer sends it: most other apps cannot
    /// draw a HEIC.
    static func jpegIfHEIC(_ data: Data, type: UTType) -> (Data, UTType) {
        guard type.conforms(to: .heic) || type.conforms(to: .heif) else { return (data, type) }
        #if os(iOS)
        if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8) { return (jpeg, .jpeg) }
        #elseif os(macOS)
        if let tiff = NSImage(data: data)?.tiffRepresentation,
           let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            return (jpeg, .jpeg)
        }
        #endif
        return (data, type)
    }

    // MARK: - GIF

    /// A nostr.build GIF is already hosted: send its link, as the note
    /// composer does unless the owner keeps GIFs on their own servers.
    private func attachGif(_ item: GifItem) {
        if item.source == .nostrBuild && !configService.config.saveGifsToBlossom {
            onLink(item.attachURL)
            return
        }
        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                let data: Data
                switch item.source {
                case .nostrBuild:
                    data = try await NostrBuildGifService.download(item.attachURL).data
                case .tenor:
                    #if TENOR_SIDELOAD
                    data = try await TenorGifService.downloadGIF(url: item.attachURL)
                    #else
                    throw URLError(.unsupportedURL)
                    #endif
                }
                let blob = try await ModePostPublisher.upload(
                    data: data, mimeType: "image/gif",
                    configService: configService, nostrService: nostrService)
                onLink(Self.link(blob.url, extension: "gif"))
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    // MARK: - Relay

    private func loadRelayMedia() {
        guard !isLoadingRelayMedia else { return }
        let relay = RelayProcessManager.shared
        guard relay.isRunning && !relay.isBooting else {
            relayMedia = []
            return
        }
        isLoadingRelayMedia = true
        Task {
            relayMedia = await ComposeView.relayBlossomMedia(
                relayManager: relay, configService: configService, nostrService: nostrService)
            isLoadingRelayMedia = false
        }
    }
}

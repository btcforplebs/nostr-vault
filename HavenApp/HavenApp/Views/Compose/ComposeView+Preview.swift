import SwiftUI

/// The live preview of the note. On a phone the keyboard owns the bottom
/// half, so Write and Preview take turns (a toggle in the title bar) rather
/// than sharing the screen; on the Mac, and an iPad sheet wide enough, the
/// preview sits beside the editor.
extension ComposeView {
    /// Wide enough for the editor and the preview side by side.
    static let sideBySideWidth: CGFloat = 700

    var showsPreviewBeside: Bool {
        #if os(macOS)
        return true
        #else
        return composerWidth >= Self.sideBySideWidth
        #endif
    }

    /// The text as it will be published: mentions as `nostr:` references,
    /// and each hosted link the author did not place added at the end.
    func publishedText() -> String {
        let hosted = attachments.filter { $0.upload == .hosted }.compactMap { $0.url?.absoluteString }
        return ComposerPlacement.withUnplacedLinks(convertMentionsToNostr(content), links: hosted)
    }

    /// The note as the feed would draw it now. nil while there is nothing to show.
    func makePreviewNote() -> FeedNote? {
        var text = publishedText()
        var tags: [[String]] = taggedPubkeys.map { ["p", $0] }
        if let quoted = effectiveQuoteTo {
            text += "\nnostr:\(quoted.nevent)"
            tags.append(["q", quoted.id, configService.config.publicRelayHint, quoted.pubkey])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        tags.append(contentsOf: LiveStreamShare.quoteTags(in: text, relayHint: configService.config.publicRelayHint))
        tags.append(contentsOf: customEmojiTags(for: text))
        tags.append(contentsOf: NoteTagging.hashtagTags(in: text))
        tags.append(contentsOf: NoteTagging.imetaTags(for: mediaDescriptors(in: text)))
        return FeedNote(
            id: "compose-preview",
            pubkey: configService.activeAccountHexPubkey,
            content: text,
            createdAt: Date(),
            tags: tags,
            kind: 1
        )
    }

    /// NIP-92 descriptors for the hosted attachments, in content order.
    func mediaDescriptors(in text: String) -> [NoteTagging.MediaDescriptor] {
        let hosted = attachments.filter { $0.upload == .hosted && $0.url != nil }
        return ComposerPlacement.contentOrder(hosted, link: { $0.url?.absoluteString ?? "" }, in: text).map(\.descriptor)
    }

    /// What changes the preview. Typing settles for a moment before it redraws.
    var previewKey: String {
        let media = attachments.map { "\($0.id)\($0.upload)\($0.altText)" }.joined(separator: ",")
        return "\(content)|\(media)|\(effectiveQuoteTo?.id ?? "")"
    }

    var previewPane: some View {
        ComposeNotePreview(
            note: previewNote,
            uploadingCount: attachments.filter { !$0.upload.isFinished || $0.upload == .savedOnDevice }.count
        )
        .environmentObject(nostrService)
        .task(id: previewKey) {
            // Live, but not every keystroke: the row lays out links and media.
            if previewNote != nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            previewNote = makePreviewNote()
        }
    }

    #if os(iOS)
    /// Write | Preview, in the title bar so it takes no room from the text.
    var writePreviewToggle: some View {
        Picker("Mode", selection: Binding(
            get: { showingPreview },
            set: { preview in
                showingPreview = preview
                isEditorFocused = !preview
            }
        )) {
            Text("Write").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .accessibilityLabel("Write or preview")
    }
    #endif
}

extension ComposeView.Attachment {
    var isVideo: Bool { type.conforms(to: .movie) || type.conforms(to: .video) }

    /// This attachment's NIP-92 `imeta` description once it is hosted.
    var descriptor: NoteTagging.MediaDescriptor {
        NoteTagging.MediaDescriptor(
            url: url?.absoluteString ?? "",
            mimeType: type.preferredMIMEType ?? "application/octet-stream",
            sha256: sha256,
            pixelWidth: pixelSize.map { Int($0.width.rounded()) },
            pixelHeight: pixelSize.map { Int($0.height.rounded()) },
            alt: altText,
            byteCount: byteCount
        )
    }
}

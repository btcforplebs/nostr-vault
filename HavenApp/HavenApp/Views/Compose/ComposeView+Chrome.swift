import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

extension ComposeView {
    #if os(macOS)
    var header: some View {
        HStack {
            Button("Cancel") { handleCancelTapped() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

            if !draftService.draftsForActiveAccount.isEmpty && draftId == nil {
                Button {
                    showingDraftPicker = true
                } label: {
                    Image(systemName: "doc.text")
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .draftCountBadge(draftService.draftsForActiveAccount.count, ringColor: .platformControlBackground)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(effectiveReplyTo != nil ? "Reply" : effectiveQuoteTo != nil ? "Quote" : "New Note")
                .font(.appHeadline)
            
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

    var isAttachmentLimitReached: Bool { attachments.count >= Self.maxAttachments }

    /// `PhotosPicker` has no "pick nothing" state, so this floors at 1; the
    /// picker is disabled at the limit and `appendAttachment` is the backstop.
    var remainingAttachmentSlots: Int {
        max(1, Self.maxAttachments - attachments.count)
    }

    var footer: some View {
        let purple = Color.havenPurple
        let title3 = Font.appTitle3
        return Group {
            // Posting/uploading left the attachment buttons enabled in the
            // layout, so the status text had to squeeze into whatever space
            // five buttons and a collapsed Spacer left it -- on iPhone that
            // was ~0, and the text landed pinned against the GIF button
            // instead of reading cleanly. Swapping the whole row for a
            // dedicated status row keeps it from crowding at all.
            if isUploading, let msg = uploadInfoProvider.uploadMessage {
                footerStatus(text: msg)
            } else if isPosting {
                footerStatus(text: "Posting note...")
            } else {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: remainingAttachmentSlots, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(title3)
                            .foregroundColor(isAttachmentLimitReached ? purple.opacity(0.3) : purple)
                            .padding(10)
                            .background(purple.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAttachmentLimitReached)
                    .help("Add photos")

                    PhotosPicker(selection: $selectedItems, maxSelectionCount: remainingAttachmentSlots, matching: .videos) {
                        Image(systemName: "video.fill")
                            .font(title3)
                            .foregroundColor(isAttachmentLimitReached ? purple.opacity(0.3) : purple)
                            .padding(10)
                            .background(purple.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAttachmentLimitReached)
                    .help("Add a video")

                    Button(action: handlePasteFromClipboard) {
                        Group {
                            if isPastingVideo {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.appTitle3)
                            }
                        }
                        .foregroundColor(isAttachmentLimitReached ? purple.opacity(0.3) : purple)
                        .padding(10)
                        .background(purple.opacity(0.1))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAttachmentLimitReached || isPastingVideo)
                    .help("Paste media from the clipboard")

// Hidden when no GIF source is available in this build (no nostr.build
                    // key, and Tenor not opted in): never show a picker that finds nothing.
                    if !GifSource.available.isEmpty {
                        Button(action: { showingGifPicker = true }) {
                            Group {
                                if isFetchingGif {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("GIF")
                                        .font(.appSystem(size: 12, weight: .bold))
                                }
                            }
                            .frame(width: 22, height: 22)
                            .foregroundColor(isAttachmentLimitReached ? purple.opacity(0.3) : purple)
                            .padding(8)
                            .background(purple.opacity(0.1))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAttachmentLimitReached || isFetchingGif)
                        .help("Search GIFs from nostr.build or Tenor")
                    }

                    Spacer()

                    Button(action: { showBlossomPicker = true }) {
                        Image(systemName: "camera.macro")
                            .font(.appTitle3)
                            .foregroundColor(purple)
                            .padding(10)
                            .background(purple.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Pick from your Blossom media")
                }
            }
        }
        .padding()
        .background(Color.platformControlBackground)
        .onChange(of: selectedItems) { _, _ in loadSelectedItems() }
    }

    private func footerStatus(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.appSystem(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .frame(minHeight: 44)
    }
    
    func replyHeader(parent: FeedNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                AvatarView(url: nostrService.profiles[parent.pubkey]?.pictureURL, pubkey: parent.pubkey, size: 32)
                
                Rectangle()
                    .fill(Color.havenPurple.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Replying to \(nostrService.profiles[parent.pubkey]?.bestName ?? String(parent.pubkey.prefix(8)))...")
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                
                // Same treatment the note gets everywhere else it is shown —
                // FeedView, QuotedNoteView. Raw `parent.content` printed the
                // `nostr:nevent1…` of a quoted note, bare media URLs and raw
                // npubs into the preview, so replying to a quote-post buried
                // the actual words under a wall of bech32.
                // Blank lines squeezed out, or they use up the three lines.
                let parentPreview = NostrContentFormatter.format(CondensedText.squeezeBlankLines(parent.content),
                                                                 mediaURLs: parent.mediaURLs)
                // A note that is nothing but a quote strips to empty; the
                // "Replying to …" line above already carries the context, so
                // an empty row with padding is worse than no row.
                if !parentPreview.characters.isEmpty {
                    Text(parentPreview)
                        .font(.appSystem(size: 13, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(3)
                        .padding(.bottom, 4)
                }

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
    
    var attachmentGrid: some View {
        let side: CGFloat = 72
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(platformImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let data = attachment.data, attachment.isAnimatable {
                                AnimatedThumbnail(data: data)
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let data = attachment.data, let img = PlatformImage(data: data) {
                                Image(platformImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let url = attachment.url, attachment.data == nil, attachment.fileURL == nil {
                                relayMediaThumbnail(url: url, type: attachment.type)
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                ZStack {
                                    Color.platformSecondaryGroupedBackground
                                    Image(systemName: attachment.type.conforms(to: .movie) || attachment.type.conforms(to: .video) ? "video.fill" : "doc.fill")
                                        .font(.appTitle)
                                        .foregroundColor(Color.havenPurple.opacity(0.8))
                                }
                                .frame(width: side, height: side)
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
                                    .font(.appSystem(size: 14, weight: .bold))
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
                        .accessibilityLabel("Remove attachment")
                    }
                    // Overlaid rather than stacked: a Button sized to the whole
                    // thumbnail would sit on top of the remove button and
                    // swallow its taps.
                    .overlay(alignment: .bottomLeading) {
                        altChip(for: attachment)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: side + 16)
        .overlay(alignment: .top) { Divider() }
    }

    /// Preview for media picked from the relay: it is already hosted, so it
    /// renders from its URL the same way the picker grid did.
    @ViewBuilder
    private func relayMediaThumbnail(url: URL, type: UTType) -> some View {
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            VideoThumbnailView(url: url, mimeType: type.preferredMIMEType)
        } else if type.conforms(to: .gif) {
            AnimatedThumbnail(url: url)
        } else {
            RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
        }
    }

    /// The ALT affordance on a thumbnail: filled once the attachment has a
    /// description, hollow while it has none, so an undescribed image is
    /// visible as such at a glance rather than only after publishing.
    private func altChip(for attachment: Attachment) -> some View {
        let described = !attachment.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            altEditorText = attachment.altText
            altEditorTarget = AltEditorTarget(id: attachment.id)
        } label: {
            Text("ALT")
                .font(.appSystem(size: 10, weight: .bold))
                .foregroundColor(described ? .white : .white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(described ? Color.havenPurple : Color.black.opacity(0.55))
                )
                .overlay(
                    Capsule().stroke(.white.opacity(described ? 0 : 0.7), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(described ? "Edit description" : "Add description")
        .accessibilityValue(described ? attachment.altText : "No description")
        .help(described ? attachment.altText : "Describe this media for screen readers")
    }

    /// Sheet for writing one attachment's NIP-92 `alt` text.
    var altEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe this media")
                .font(.appHeadline)
            Text("Published as the image's ALT text. Screen readers read this instead of the picture.")
                .font(.appSystem(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $altEditorText)
                .font(.appBody)
                .frame(minHeight: 100)
                .padding(6)
                .background(Color.platformSecondaryGroupedBackground)
                .cornerRadius(10)
                .accessibilityLabel("Media description")

            HStack {
                Spacer()
                Button("Cancel") { altEditorTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let id = altEditorTarget?.id,
                       let index = attachments.firstIndex(where: { $0.id == id }) {
                        attachments[index].altText = altEditorText
                    }
                    altEditorTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 380)
    }
}

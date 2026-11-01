import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Overlays a small numbered badge on the top-trailing corner, matching the
    /// unread-dot treatment used for conversation rows elsewhere in the app
    /// (see DMInboxView) but with a count instead of a plain dot.
    func draftCountBadge(_ count: Int, ringColor: Color) -> some View {
        overlay(alignment: .topTrailing) {
            Text("\(count)")
                .font(.appSystem(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.havenPurple, in: Circle())
                .overlay(Circle().stroke(ringColor, lineWidth: 1.5))
                .offset(x: 10, y: -8)
        }
    }
}

struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    // Rebuilds the account menu once each account's picture is cached.
    @ObservedObject private var accountAvatars = AccountMenuAvatars.shared
    @EnvironmentObject var relayManager: RelayProcessManager

    /// The text, the photos and their uploads (ComposerNote).
    @StateObject var note = ComposerNote()
    var content: String {
        get { note.text }
        nonmutating set { note.text = newValue }
    }
    var attachments: [Attachment] {
        get { note.attachments }
        nonmutating set { note.attachments = newValue }
    }
    @State var selectedItems: [PhotosPickerItem] = []
    /// Media is being dragged over the editor.
    @State private var isDropTargeted = false
    /// Post was tapped and is waiting for uploads still going.
    @State var isUploading = false
    @State var isPosting = false
    @State var error: String?
    @State var isEditorFocused = false
    /// Phone: the Preview side of the Write | Preview toggle is showing.
    @State var showingPreview = false
    /// The composer's width, which decides whether the preview fits beside the editor.
    @State var composerWidth: CGFloat = 0
    /// What the preview draws, rebuilt a moment after each edit.
    @State var previewNote: FeedNote?

    // Blossom media picker state
    @State var showBlossomPicker = false
    @State var blossomMedia: [MediaItem] = []
    @State var isLoadingBlossomMedia = false

    // @mention state
    @State var mentionQuery: String? = nil          // nil = popup hidden
    @State var mentionResults: [FeedProfile] = []
    @State var taggedPubkeys: [String] = []         // hex pubkeys of tagged users
    @State var mentionStartOffset: Int? = nil       // char offset of the active `@`
    @State var mentionEndOffset: Int? = nil         // char offset of the caret (query end)
    // Maps an inserted display token (e.g. "@Alice") → hex pubkey. The editor shows
    // `@name` for readability; tokens are converted back to `nostr:npub…` at publish
    // and draft-save time so published notes stay interoperable.
    @State var mentionMap: [String: String] = [:]
    // Debounced NIP-50 relay search for mentioning people who aren't followed / cached.
    @State var mentionSearchTask: Task<Void, Never>? = nil

    // :emoji autocomplete (NIP-30), see ComposeView+Emoji.swift
    @State var emojiSuggestions: [CustomEmoji] = []
    @State var emojiQuery: ComposeEmoji.Query? = nil

    // Draft auto-save state
    @State var draftId: String? = nil
    @State var autoSaveTask: Task<Void, Never>? = nil
    @State var lastSavedContent: String = ""
    @State var showingDraftPicker = false
    @State var showingGifPicker = false
    @State var isFetchingGif = false
    /// A pasted video is copied to disk before it attaches, and one from
    /// another device over Universal Clipboard is still in transit.
    @State var isPastingVideo = false
    @State var showingDiscardConfirm = false
    @StateObject var draftService = DraftService.shared

    // ALT-text editor: which attachment is being described, and the text being
    // written for it. Nil target = sheet closed.
    @State var altEditorTarget: AltEditorTarget? = nil
    @State var altEditorText: String = ""

    // Draft-loaded reply/quote context (overrides init-provided values)
    @State var draftReplyTo: FeedNote? = nil
    @State var draftQuoteTo: FeedNote? = nil

    /// The editor's text size: 16 points scaled like `Font.appSystem(size: 16)`.
    static var editorFontSize: CGFloat {
        #if os(macOS)
        let mac = true
        #else
        let mac = false
        #endif
        return AppTypeScale.floored(16 * CGFloat(ConfigService.shared.config.textSizeScale), mac: mac)
    }

    var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    // Optional: for replies
    var replyTo: FeedNote?
    // Optional: for quote posts
    var quoteTo: FeedNote?

    /// Effective reply target: draft-loaded value takes precedence over init-provided value.
    var effectiveReplyTo: FeedNote? { draftReplyTo ?? replyTo }
    /// Effective quote target: draft-loaded value takes precedence over init-provided value.
    var effectiveQuoteTo: FeedNote? { draftQuoteTo ?? quoteTo }
    // Optional: pre-filled content (used when editing a pending post)
    var initialContent: String = ""
    // Optional: draft ID when restoring a saved draft
    var restoredDraftId: String? = nil
    /// The account this note is for (npub), when it isn't simply whichever is
    /// active: a reply from a note opened as another account. nil = active.
    var postAs: String? = nil
    /// `postAs`, or the account picked from the avatar menu since.
    @State var postAsPicked: String? = nil
    
    struct Attachment: Identifiable {
        let id = UUID()
        // At most one of `data` or `fileURL` is set. Images use `data` (small,
        // possibly transcoded); videos use `fileURL` so they stream from disk.
        // Neither is set for media already on the relay, picked from the
        // Blossom picker: that arrives with `url` set and `isUploaded` true.
        let data: Data?
        let fileURL: URL?
        var type: UTType
        var url: URL?
        var isUploaded: Bool = false
        var thumbnail: PlatformImage?
        /// NIP-92 `alt` — what this media is, for anyone who cannot see it.
        /// Published inside the attachment's `imeta` tag; empty means omitted.
        var altText: String = ""
        /// For relay-picked media: the blob in the local Blossom directory,
        /// read only for `imeta` dimensions and size. Never uploaded or deleted.
        var relayBlobFile: URL? = nil

        /// Where its upload has got to; it starts when the attachment is picked.
        var upload: ComposerUploadState = .waiting
        /// Filled in by the upload, for the note's `imeta` tag.
        var sha256: String?
        var pixelSize: CGSize?
        var byteCount: Int?

        /// GIF or WebP bytes, which may hold more than one frame and so are
        /// previewed with `AnimatedThumbnail` rather than a still decode.
        var isAnimatable: Bool { type.conforms(to: .gif) || type.conforms(to: .webP) }
    }

    /// `sheet(item:)` needs an Identifiable; the attachment's own id is a bare
    /// UUID, so it is wrapped rather than conformance being added to UUID.
    struct AltEditorTarget: Identifiable {
        let id: Attachment.ID
    }
    
    var body: some View {
        Group {
            #if os(macOS)
            composeContent
                .frame(minWidth: 820, idealWidth: 900, minHeight: 400, idealHeight: 480)
            #else
            // NavigationStack, not NavigationView: on iPad (regular width) a
            // single-root NavigationView renders as a collapsed split view,
            // leaving the reply sheet blank/squeezed in portrait.
            NavigationStack {
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

            if showsPreviewBeside {
                HStack(spacing: 0) {
                    editorScroll
                        .frame(maxWidth: .infinity)
                    Divider()
                    previewPane
                        .frame(maxWidth: .infinity)
                }
            } else if showingPreview {
                previewPane
            } else {
                editorScroll
            }

            // @mention popup — inline above footer so it stays visible above the keyboard
            if !showingPreview || showsPreviewBeside, mentionQuery != nil, !mentionResults.isEmpty {
                mentionPopup
            }

            // :emoji suggestions, docked the same way
            if !showingPreview || showsPreviewBeside, emojiQuery != nil, !emojiSuggestions.isEmpty {
                emojiPopup
            }

            // Attachments dock above the footer rather than sitting under the
            // text: below a 200pt editor they landed under the keyboard, so a
            // just-added photo needed a scroll to see and ate typing room.
            if !attachments.isEmpty {
                attachmentGrid
                UploadServersLink()
            }

            footer
        }
            .background(Color.platformSecondaryGroupedBackground)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerWidth = $0 }
            // Photos and videos dragged in from Photos, Files or Safari join the
            // note's attachments, the same as ones picked from the footer.
            .onDrop(of: DroppedMedia.acceptedTypes, isTargeted: $isDropTargeted) { providers in
                guard !isPosting, !isAttachmentLimitReached, !providers.isEmpty else { return false }
                Task { await attachDropped(providers) }
                return true
            }
            .dropTargetHighlight(isDropTargeted, cornerRadius: 0)
            #if os(iOS)
            .modifier(PastesClipboardImage(action: handlePasteFromClipboard))
            #endif
            .navigationTitle(effectiveReplyTo != nil ? "Reply" : effectiveQuoteTo != nil ? "Quote" : "New Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { handleCancelTapped() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if !draftService.draftsForActiveAccount.isEmpty && draftId == nil {
                        Button {
                            showingDraftPicker = true
                        } label: {
                            Image(systemName: "doc.text")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.havenPurple)
                                .draftCountBadge(draftService.draftsForActiveAccount.count, ringColor: .platformSecondaryGroupedBackground)
                        }
                    }
                }
                if !showsPreviewBeside {
                    ToolbarItem(placement: .principal) { writePreviewToggle }
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
            .confirmationDialog(
                "Save this note as a draft?",
                isPresented: $showingDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Save Draft") { performDismiss() }
                Button("Discard", role: .destructive) { discardDraftAndDismiss() }
                Button("Keep Editing", role: .cancel) { }
            }
            .onAppear {
                // A reply for another account's note: be that account before
                // anything is typed, so the avatar, the signer and a remote
                // signer's connection are all that account's.
                if postAsPicked == nil { postAsPicked = postAs }
                if let npub = PostingAccount.switchTarget(postAs: postAsPicked,
                                                          active: configService.config.activeAccountNpub,
                                                          owner: configService.config.ownerNpub) {
                    configService.switchActiveAccount(to: npub)
                }
                // Start waking sleeping mirror hosts (e.g. the Mac relay) now,
                // so they're reachable by the time the user hits Post.
                Task { await blossomService.prewarmMirrors() }
                if !initialContent.isEmpty {
                    content = convertNostrToMentions(initialContent)
                }
                if let restored = restoredDraftId {
                    draftId = restored
                    // Baseline must match the editor's display form (with @name mentions),
                    // not the canonical nostr: form, or the dirty check always fires and
                    // re-saves/re-syncs the draft on every open with no real edit.
                    lastSavedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Task { await draftService.fetchDrafts() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isEditorFocused = true
                }
            }
            .onDisappear {
                // performDismiss already handles auto-save cancellation and final save.
                cleanupAttachmentTempFiles()
            }
            .sheet(isPresented: $showBlossomPicker) {
                BlossomMediaPickerSheet(
                    blossomMedia: $blossomMedia,
                    isLoading: $isLoadingBlossomMedia,
                    onSelect: { item in
                        attachRelayMedia(item)
                        showBlossomPicker = false
                    },
                    onAppearLoad: { loadBlossomMedia() }
                )
            }
            .sheet(isPresented: $showingGifPicker) {
                GifPickerSheet { item in attachGif(item) }
            }
            .sheet(item: $altEditorTarget) { _ in
                altEditorSheet
            }
            .sheet(isPresented: $showingDraftPicker) {
                DraftPickerView(
                    onSelect: { draft in
                        loadDraft(draft)
                    },
                    onDelete: { draft in
                        Task { await DraftService.shared.deleteDraft(id: draft.id) }
                    }
                )
            }
    }

    private var editorScroll: some View {
            ScrollView {
                VStack(spacing: 16) {
                    if let parent = effectiveReplyTo {
                        replyHeader(parent: parent)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(
                            url: nostrService.profiles[configService.activeAccountHexPubkey]?.pictureURL,
                            pubkey: configService.activeAccountHexPubkey,
                            size: 36
                        )
                        .contextMenu {
                            if configService.allAccountNpubs.count > 1 {
                                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                                    let isOwner = npub == configService.config.ownerNpub
                                    let activeAccountNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let hex = Bech32.decode(npub)?.hexString ?? ""
                                    let profile = nostrService.profiles[hex]
                                    AccountMenuItem(
                                        npub: npub,
                                        name: profile?.bestName ?? (isOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)),
                                        pictureURL: profile?.pictureURL,
                                        isActive: activeAccountNpub.isEmpty ? isOwner : npub == activeAccountNpub
                                    ) {
                                        postAsPicked = npub
                                        configService.switchActiveAccount(to: npub)
                                    }
                                }
                            } else {
                                Text("No other accounts")
                            }
                        }
                        .task(id: AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles)) {
                            accountAvatars.prefetch(AccountMenuAvatars.pictureURLs(npubs: configService.allAccountNpubs, profiles: nostrService.profiles))
                        }

                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's happening?")
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .padding(.top, 10)
                                    .padding(.leading, 4)
                            }

                            ComposeTextView(
                                text: $note.text,
                                selection: $note.selection,
                                isFocused: $isEditorFocused,
                                fontSize: ComposeView.editorFontSize,
                                minHeight: 200
                            )
                                #if os(iOS)
                                .background(CaretFollower(trigger: "\(content.count)|\(mentionResults.isEmpty)|\(attachments.count)"))
                                #endif
                                .onChange(of: content) { oldValue, newValue in
                                    if note.appEdited {
                                        // A link written in is not typing.
                                        note.appEdited = false
                                    } else {
                                        updateMentionQuery(old: oldValue, new: newValue)
                                        updateEmojiQuery(old: oldValue, new: newValue)
                                    }
                                    scheduleAutoSave(newValue)
                                }
                        }
                    }

                    if let quoted = effectiveQuoteTo {
                        QuotedNoteView(note: quoted)
                            .environmentObject(nostrService)
                    }
                }
                .padding(20)
            }
    }
}

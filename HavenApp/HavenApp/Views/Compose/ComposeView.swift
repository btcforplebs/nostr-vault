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

    @State var content: String = ""
    @State var selectedItems: [PhotosPickerItem] = []
    @State var attachments: [Attachment] = []
    /// Media is being dragged over the editor.
    @State private var isDropTargeted = false
    @State var isUploading = false
    @State var isPosting = false
    @State var error: String?
    @FocusState private var isTextEditorFocused: Bool
    
    @StateObject var uploadInfoProvider = MediaUploadsIndicatorInfoProvider()

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
                .frame(minWidth: 500, idealWidth: 500, minHeight: 400, idealHeight: 450)
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

                            TextEditor(text: $content)
                                .focused($isTextEditorFocused)
                                .font(.appSystem(size: 16))
                                .frame(minHeight: 200)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("Post content")
                                #if os(iOS)
                                .background(CaretFollower(trigger: "\(content.count)|\(mentionResults.isEmpty)|\(attachments.count)"))
                                #endif
                                .onChange(of: content) { oldValue, newValue in
                                    updateMentionQuery(old: oldValue, new: newValue)
                                    updateEmojiQuery(old: oldValue, new: newValue)
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

            // @mention popup — inline above footer so it stays visible above the keyboard
            if let _ = mentionQuery, !mentionResults.isEmpty {
                mentionPopup
            }

            // :emoji suggestions, docked the same way
            if emojiQuery != nil, !emojiSuggestions.isEmpty {
                emojiPopup
            }

            // Attachments dock above the footer rather than sitting under the
            // text: below a 200pt editor they landed under the keyboard, so a
            // just-added photo needed a scroll to see and ate typing room.
            if !attachments.isEmpty {
                attachmentGrid
            }

            footer
        }
            .background(Color.platformSecondaryGroupedBackground)
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
                    isTextEditorFocused = true
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
}

#if os(iOS)
/// Keeps the caret on screen while typing. The editor grows with its text
/// inside the compose ScrollView, so the text view never scrolls itself and
/// UIKit doesn't scroll the SwiftUI ScrollView around it: once a note ran
/// past the keyboard (or the @mention strip appeared), the line being typed
/// slid out of sight. On every edit this scrolls the enclosing scroll view
/// just enough to show the caret.
private struct CaretFollower: UIViewRepresentable {
    /// Changes whenever the caret may have moved or the visible area changed.
    let trigger: String

    final class Coordinator {
        weak var textView: UITextView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        _ = trigger
        // After SwiftUI has laid out the editor's new height.
        DispatchQueue.main.async {
            if context.coordinator.textView?.window == nil, let window = view.window {
                context.coordinator.textView = Self.focusedTextView(in: window)
            }
            guard let textView = context.coordinator.textView,
                  textView.isFirstResponder,
                  let caret = textView.selectedTextRange?.end,
                  let scrollView = Self.enclosingScrollView(of: textView) else { return }
            scrollView.layoutIfNeeded()
            let rect = textView.convert(textView.caretRect(for: caret), to: scrollView)
            scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -12), animated: false)
        }
    }

    private static func focusedTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isFirstResponder { return textView }
        for sub in view.subviews {
            if let found = focusedTextView(in: sub) { return found }
        }
        return nil
    }

    /// The first scroll view above the text view (a UITextView is itself one).
    private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var current = view.superview
        while let v = current {
            if let scroll = v as? UIScrollView { return scroll }
            current = v.superview
        }
        return nil
    }
}
#endif

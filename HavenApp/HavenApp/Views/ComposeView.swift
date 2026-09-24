import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

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

private extension View {
    /// Overlays a small numbered badge on the top-trailing corner, matching the
    /// unread-dot treatment used for conversation/group rows elsewhere in the app
    /// (see GroupListView/DMInboxView) but with a count instead of a plain dot.
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
    @EnvironmentObject var relayManager: RelayProcessManager

    @State private var content: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var isUploading = false
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var isTextEditorFocused: Bool
    
    @StateObject private var uploadInfoProvider = MediaUploadsIndicatorInfoProvider()

    // Blossom media picker state
    @State private var showBlossomPicker = false
    @State private var blossomMedia: [MediaItem] = []
    @State private var isLoadingBlossomMedia = false

    // @mention state
    @State private var mentionQuery: String? = nil          // nil = popup hidden
    @State private var mentionResults: [FeedProfile] = []
    @State private var taggedPubkeys: [String] = []         // hex pubkeys of tagged users
    @State private var mentionStartOffset: Int? = nil       // char offset of the active `@`
    @State private var mentionEndOffset: Int? = nil         // char offset of the caret (query end)
    // Maps an inserted display token (e.g. "@Alice") → hex pubkey. The editor shows
    // `@name` for readability; tokens are converted back to `nostr:npub…` at publish
    // and draft-save time so published notes stay interoperable.
    @State private var mentionMap: [String: String] = [:]
    // Debounced NIP-50 relay search for mentioning people who aren't followed / cached.
    @State private var mentionSearchTask: Task<Void, Never>? = nil

    // Draft auto-save state
    @State private var draftId: String? = nil
    @State private var autoSaveTask: Task<Void, Never>? = nil
    @State private var lastSavedContent: String = ""
    @State private var showingDraftPicker = false
    @State private var showingGifPicker = false
    @State private var isFetchingGif = false
    @State private var showingDiscardConfirm = false
    @StateObject private var draftService = DraftService.shared

    // ALT-text editor: which attachment is being described, and the text being
    // written for it. Nil target = sheet closed.
    @State private var altEditorTarget: AltEditorTarget? = nil
    @State private var altEditorText: String = ""

    // Draft-loaded reply/quote context (overrides init-provided values)
    @State private var draftReplyTo: FeedNote? = nil
    @State private var draftQuoteTo: FeedNote? = nil

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    // Optional: for replies
    var replyTo: FeedNote?
    // Optional: for quote posts
    var quoteTo: FeedNote?

    /// Effective reply target: draft-loaded value takes precedence over init-provided value.
    private var effectiveReplyTo: FeedNote? { draftReplyTo ?? replyTo }
    /// Effective quote target: draft-loaded value takes precedence over init-provided value.
    private var effectiveQuoteTo: FeedNote? { draftQuoteTo ?? quoteTo }
    // Optional: pre-filled content (used when editing a pending post)
    var initialContent: String = ""
    // Optional: draft ID when restoring a saved draft
    var restoredDraftId: String? = nil
    
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
        /// NIP-92 `alt` — what this media is, for anyone who cannot see it.
        /// Published inside the attachment's `imeta` tag; empty means omitted.
        var altText: String = ""
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

            ScrollViewReader { proxy in
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
                                    .font(.appSystem(size: 16))
                                    .frame(minHeight: 200)
                                    .scrollContentBackground(.hidden)
                                    .accessibilityLabel("Post content")
                                    .onChange(of: content) { oldValue, newValue in
                                        updateMentionQuery(old: oldValue, new: newValue)
                                        scheduleAutoSave(newValue)
                                    }
                            }
                        }

                        if !attachments.isEmpty {
                            attachmentGrid
                                .id("attachmentGrid")
                        }

                        if let quoted = effectiveQuoteTo {
                            QuotedNoteView(note: quoted)
                                .environmentObject(nostrService)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: attachments.count) { oldCount, newCount in
                    // Scroll to show attachments when a new one is added
                    if newCount > oldCount && newCount > 0 {
                        withAnimation {
                            proxy.scrollTo("attachmentGrid", anchor: .bottom)
                        }
                    }
                }
            }

            // @mention popup — inline above footer so it stays visible above the keyboard
            if let _ = mentionQuery, !mentionResults.isEmpty {
                mentionPopup
            }

            footer
        }
            .background(Color.platformSecondaryGroupedBackground)
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
                        let url = item.shareURL(with: configService).absoluteString
                        if content.isEmpty || content.hasSuffix("\n") || content.hasSuffix(" ") {
                            content += url
                        } else {
                            content += " " + url
                        }
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
                                .font(.appSystem(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 12))
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
        .animation(Motion.panel, value: mentionResults.count)
    }

    /// Called every time `content` changes — finds the @query at the caret, which
    /// may be anywhere in the text (not just at the end). The caret is located via
    /// the diff between the previous and new text, then we scan backwards from it to
    /// find the `@` that begins the token currently being edited.
    private func updateMentionQuery(old: String, new text: String) {
        let caret = caretIndex(old: old, new: text)

        // Scan backwards from the caret for the start of the current token.
        var atIndex: String.Index? = nil
        var idx = caret
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]
            if ch == "@" {
                atIndex = prev
                break
            }
            // A mention token can't contain whitespace/newline.
            if ch == " " || ch == "\n" || ch == "\t" { break }
            idx = prev
        }

        guard let atIndex else {
            clearMention()
            return
        }

        // The `@` must start a word (preceded by start-of-text or whitespace) so
        // that email addresses like foo@bar.com don't trigger the picker.
        if atIndex > text.startIndex {
            let before = text[text.index(before: atIndex)]
            if before != " " && before != "\n" && before != "\t" {
                clearMention()
                return
            }
        }

        let queryStart = text.index(after: atIndex)
        let query = String(text[queryStart..<caret])

        mentionStartOffset = text.distance(from: text.startIndex, to: atIndex)
        mentionEndOffset = text.distance(from: text.startIndex, to: caret)
        mentionQuery = query
        filterMentionResults(query: query)
        scheduleMentionSearch(query)
    }

    /// Returns the index in `new` just past the region that differs from `old` —
    /// i.e. where the caret sits after the edit that produced `new`.
    private func caretIndex(old: String, new: String) -> String.Index {
        let oldChars = Array(old)
        let newChars = Array(new)
        let maxLen = min(oldChars.count, newChars.count)

        var prefix = 0
        while prefix < maxLen && oldChars[prefix] == newChars[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = maxLen - prefix
        while suffix < maxSuffix &&
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let caretOffset = newChars.count - suffix
        return new.index(new.startIndex, offsetBy: caretOffset)
    }

    private func clearMention() {
        mentionQuery = nil
        mentionResults = []
        mentionStartOffset = nil
        mentionEndOffset = nil
        mentionSearchTask?.cancel()
        mentionSearchTask = nil
    }

    private func filterMentionResults(query: String) {
        let followed = FeedService.shared.followedPubkeys
        let followedSet = Set(followed)
        let selfPubkey = nostrService.activeHexPubkey

        // Thread participants when replying — valid mention targets even if unfollowed.
        var threadPubkeys: [String] = []
        if let parent = effectiveReplyTo {
            threadPubkeys.append(parent.pubkey)
            for tag in parent.tags where tag.count >= 2 && tag[0] == "p" {
                if !threadPubkeys.contains(tag[1]) { threadPubkeys.append(tag[1]) }
            }
            threadPubkeys.removeAll { $0 == selfPubkey }
        }
        let threadSet = Set(threadPubkeys)

        if query.isEmpty {
            // Just typed @: thread participants first, then followed.
            let threadProfiles = threadPubkeys.compactMap { nostrService.profiles[$0] }
            let followedProfiles = followed.compactMap { nostrService.profiles[$0] }
            var combined: [FeedProfile] = threadProfiles
            for p in followedProfiles where !combined.contains(where: { $0.pubkey == p.pubkey }) {
                combined.append(p)
            }
            mentionResults = Array(combined.prefix(8))
            return
        }

        // Search the entire profile cache (feed authors, search results, etc.),
        // not just follows, ranking thread participants and follows first.
        let lower = query.lowercased()
        let matches = nostrService.profiles.values.filter { profile in
            profile.pubkey != selfPubkey && (
                profile.bestName.lowercased().contains(lower) ||
                (profile.name?.lowercased().contains(lower) ?? false) ||
                (profile.nip05?.lowercased().contains(lower) ?? false)
            )
        }
        let ranked = matches.sorted { a, b in
            func rank(_ p: FeedProfile) -> (Int, Int, Int) {
                (threadSet.contains(p.pubkey) ? 0 : 1,
                 followedSet.contains(p.pubkey) ? 0 : 1,
                 p.bestName.lowercased().hasPrefix(lower) ? 0 : 1)
            }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.bestName.count < b.bestName.count
        }
        mentionResults = Array(ranked.prefix(8))
    }

    /// Debounced NIP-50 relay search so you can @-mention people who aren't followed
    /// and whose profile isn't cached yet. `globalSearch` merges discovered profiles
    /// into `nostrService.profiles`; we re-filter when results arrive.
    private func scheduleMentionSearch(_ query: String) {
        mentionSearchTask?.cancel()
        guard query.count >= 2 else { return }
        mentionSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            nostrService.globalSearch(query: query) { _ in
                // Completion runs on the main queue; re-filter if still editing this query.
                if mentionQuery == query {
                    filterMentionResults(query: query)
                }
            }
        }
    }

    /// Resolves a bare `npub1…`/`nprofile1…` bech32 identifier to a hex pubkey.
    private func resolvePubkey(fromBech32 bech32: String) -> String? {
        if bech32.lowercased().hasPrefix("npub1") {
            return Bech32.decode(bech32)?.hexString
        }
        if bech32.lowercased().hasPrefix("nprofile1"), let decoded = Bech32.decode(bech32) {
            // TLV: type 0 = pubkey (32 bytes)
            var data = decoded.data
            while data.count >= 2 {
                let type = data.removeFirst()
                let length = Int(data.removeFirst())
                guard data.count >= length else { break }
                let value = data.prefix(length)
                if type == 0 && length == 32 {
                    return value.map { String(format: "%02x", $0) }.joined()
                }
                data.removeFirst(length)
            }
        }
        return nil
    }

    /// Display token shown in the editor for a mention (e.g. "@Alice").
    private func mentionToken(name: String, pubkey: String) -> String {
        let clean = name
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "@\(clean.isEmpty ? String(pubkey.prefix(8)) : clean)"
    }

    /// Returns a token guaranteed unique within `mentionMap`. Two distinct users can
    /// share a display name (e.g. both "satoshi"); without disambiguation the second
    /// insertion would overwrite the first in `mentionMap`, and `convertMentionsToNostr`
    /// would rewrite *every* `@satoshi` to the last-stored pubkey — silently mentioning
    /// the wrong person. On a same-name collision we append a short pubkey suffix.
    private func uniqueMentionToken(name: String, pubkey: String) -> String {
        let base = mentionToken(name: name, pubkey: pubkey)
        // Unmapped, or already mapped to this same pubkey → the base token is correct.
        if let existing = mentionMap[base] {
            if existing == pubkey { return base }
        } else {
            return base
        }
        // Collision with a different pubkey → disambiguate with a stable suffix.
        var candidate = "\(base)·\(String(pubkey.prefix(8)))"
        var n = 2
        while let existing = mentionMap[candidate], existing != pubkey {
            candidate = "\(base)·\(String(pubkey.prefix(8)))-\(n)"
            n += 1
        }
        return candidate
    }

    /// Converts `nostr:npub1…`/`nostr:nprofile1…` references in `text` to readable
    /// `@name` tokens for editing, rebuilding `mentionMap` and `taggedPubkeys`.
    /// Used when loading drafts or editing a pending post.
    private func convertNostrToMentions(_ text: String) -> String {
        let pattern = "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = text
        // Replace last → first so earlier match ranges remain valid against `result`.
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let bech32 = ns.substring(with: match.range(at: 1))
            guard let pubkey = resolvePubkey(fromBech32: bech32) else { continue }
            let token = uniqueMentionToken(name: nostrService.profiles[pubkey]?.bestName ?? "", pubkey: pubkey)
            mentionMap[token] = pubkey
            if !taggedPubkeys.contains(pubkey) { taggedPubkeys.append(pubkey) }
            result = (result as NSString).replacingCharacters(in: match.range, with: token)
        }
        return result
    }

    /// Converts `@name` display tokens back to canonical `nostr:npub…` references for
    /// publishing and draft persistence. Longest tokens first so a shorter name that is
    /// a prefix of another doesn't clobber it; a trailing word-boundary guards against
    /// partial matches inside other words.
    private func convertMentionsToNostr(_ text: String) -> String {
        guard !mentionMap.isEmpty else { return text }
        var result = text
        for (token, pubkey) in mentionMap.sorted(by: { $0.key.count > $1.key.count }) {
            guard let data = Bech32.hexToData(pubkey),
                  let npub = Bech32.encode(hrp: "npub", data: data) else { continue }
            let pattern = NSRegularExpression.escapedPattern(for: token) + "(?![\\p{L}\\p{N}_])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: NSRegularExpression.escapedTemplate(for: "nostr:\(npub)")
            )
        }
        return result
    }

    private func insertMention(_ profile: FeedProfile) {
        let token = uniqueMentionToken(name: profile.bestName, pubkey: profile.pubkey)
        let replacement = "\(token) "

        // Replace the active `@query` token (which may be mid-text) with the display token.
        if let startOff = mentionStartOffset, let endOff = mentionEndOffset,
           startOff <= endOff, endOff <= content.count {
            let start = content.index(content.startIndex, offsetBy: startOff)
            let end = content.index(content.startIndex, offsetBy: endOff)
            content.replaceSubrange(start..<end, with: replacement)
        } else if let atRange = content.range(of: "@", options: .backwards) {
            // Fallback: replace the trailing `@query`.
            content = String(content[content.startIndex..<atRange.lowerBound]) + replacement
        } else {
            content += replacement
        }

        // Remember the token → pubkey mapping and track for the `p` tag.
        mentionMap[token] = profile.pubkey
        if !taggedPubkeys.contains(profile.pubkey) {
            taggedPubkeys.append(profile.pubkey)
        }

        withAnimation {
            clearMention()
        }
    }

    #if os(macOS)
    private var header: some View {
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

    private var isAttachmentLimitReached: Bool { attachments.count >= Self.maxAttachments }

    /// `PhotosPicker` has no "pick nothing" state, so this floors at 1; the
    /// picker is disabled at the limit and `appendAttachment` is the backstop.
    private var remainingAttachmentSlots: Int {
        max(1, Self.maxAttachments - attachments.count)
    }

    private var footer: some View {
        let purple = Color.havenPurple
        let title3 = Font.appTitle3
        return HStack(spacing: 12) {
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

            Button(action: handlePasteFromClipboard) {
                Image(systemName: "wand.and.stars")
                    .font(.appTitle3)
                    .foregroundColor(isAttachmentLimitReached ? purple.opacity(0.3) : purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isAttachmentLimitReached)

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
            .help("Search GIFs from getyarn.io or Tenor")

            Spacer()
            
            if isUploading, let msg = uploadInfoProvider.uploadMessage {
                Text(msg)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            } else if isPosting {
                Text("Posting note...")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            
            Button(action: { showBlossomPicker = true }) {
                Image(systemName: "camera.macro")
                    .font(.appTitle3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.platformControlBackground)
        .onChange(of: selectedItems) { _, _ in loadSelectedItems() }
    }
    
    private func replyHeader(parent: FeedNote) -> some View {
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
                let parentPreview = NostrContentFormatter.format(parent.content,
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
                                        .font(.appTitle)
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
            .padding()
        }
        .frame(height: 120)
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
    private var altEditorSheet: some View {
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
    
    private func loadSelectedItems() {
        for item in selectedItems {
            // Check ALL supported content types — .first can be a non-video type
            // even for videos (e.g. HEVC, iCloud items, combined pickers).
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let contentType = item.supportedContentTypes.first ?? .image

            if isVideo {
                loadVideoItem(item, contentType: contentType)
            } else {
                loadImageItem(item, contentType: contentType)
            }
        }
        selectedItems = []
    }

    private func loadVideoItem(_ item: PhotosPickerItem, contentType: UTType) {
        Task {
            // Try file-based ImportedVideoFile first, fall back to Data if the system
            // can't provide a .movie file representation (HEVC transcoding, iCloud, etc.).
            if let video = try? await item.loadTransferable(type: ImportedVideoFile.self) {
                let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                let videoURL = video.url
                let thumbnail = await self.generateVideoThumbnail(url: videoURL)
                await MainActor.run {
                    self.appendAttachment(Attachment(
                        data: nil,
                        fileURL: videoURL,
                        type: derivedType,
                        thumbnail: thumbnail
                    ))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                // Fallback: write bytes to temp file so the upload can stream from disk.
                let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? contentType
                let ext = videoType.preferredFilenameExtension ?? "mp4"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                do {
                    try data.write(to: dest)
                    let derivedType = UTType(filenameExtension: ext) ?? videoType
                    let thumbnail = await self.generateVideoThumbnail(url: dest)
                    await MainActor.run {
                        self.appendAttachment(Attachment(
                            data: nil,
                            fileURL: dest,
                            type: derivedType,
                            thumbnail: thumbnail
                        ))
                    }
                } catch {
                    await MainActor.run {
                        self.error = "Failed to load video: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    self.error = "Failed to load video file."
                }
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

                    self.appendAttachment(Attachment(
                        data: finalData,
                        fileURL: nil,
                        type: finalType,
                        thumbnail: nil
                    ))
                }
            case .failure(let error):
                #if DEBUG
                print("Failed to load media: \(error)")
                #endif
                DispatchQueue.main.async {
                    self.error = "Failed to load media: \(error.localizedDescription)"
                }
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

    /// Pixel dimensions of encoded image bytes, read from the image's own
    /// header rather than by decoding it — an `imeta dim` is worth one header
    /// read, not a full decode of a 12-megapixel photo.
    nonisolated static func pixelSize(ofImageData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Displayed dimensions of a video track: `naturalSize` is pre-rotation, so
    /// a portrait clip shot on a phone reports landscape unless the track's
    /// preferred transform is applied. Getting this backwards would reserve a
    /// sideways box in every client that trusts our `dim`.
    nonisolated static func pixelSize(ofVideoAt url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let oriented = naturalSize.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// How many attachments one note carries. The editor's grid, the upload
    /// progress copy and every reader's media layout assume a small number.
    static let maxAttachments = 4

    /// Adds an attachment unless the note is already full.
    ///
    /// The picker paths used to append unconditionally: `maxSelectionCount`
    /// floors at 1, so a note already holding four could still take a fifth,
    /// and nothing ever told the author there was a limit — they met it as
    /// buttons that stopped responding.
    @discardableResult
    private func appendAttachment(_ attachment: Attachment) -> Bool {
        guard attachments.count < Self.maxAttachments else {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            error = "A note can carry \(Self.maxAttachments) attachments."
            return false
        }
        attachments.append(attachment)
        return true
    }

    private func cleanupAttachmentTempFiles() {
        for attachment in attachments {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func generateVideoThumbnail(url: URL) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let asset = AVAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let cgImage = cgImage {
                    #if os(macOS)
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    #else
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                    #endif
                } else {
                    #if DEBUG
                    if let error = error {
                        print("Error generating video thumbnail: \(error)")
                    }
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Downloads a picked GIF and adds it as an attachment. Each source
    /// downloads through its own client so the size cap and the GIF-magic
    /// check stay with the service that knows the host.
    private func attachGif(_ item: GifItem) {
        guard !isAttachmentLimitReached, !isFetchingGif else { return }
        isFetchingGif = true
        Task {
            do {
                let data: Data
                switch item.source {
                case .yarn:
                    data = try await YarnClipService.downloadGIF(uuid: item.sourceID)
                case .tenor:
                    data = try await TenorGifService.downloadGIF(url: item.attachURL)
                }
                await MainActor.run {
                    appendAttachment(Attachment(data: data, fileURL: nil, type: .gif))
                    isFetchingGif = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Could not fetch GIF: \(error.localizedDescription)"
                    isFetchingGif = false
                }
            }
        }
    }

    private func handlePasteFromClipboard() {
        guard !isAttachmentLimitReached else { return }

        if PlatformClipboard.hasImage(), let imageData = PlatformClipboard.getImageData() {
            // Detect actual image format from data magic bytes
            let detectedType: UTType
            if imageData.count >= 6 {
                let gif87 = Data("GIF87a".utf8)
                let gif89 = Data("GIF89a".utf8)
                let prefix = imageData.prefix(6)
                if prefix == gif87 || prefix == gif89 {
                    detectedType = .gif
                } else if imageData.prefix(4) == Data([137, 80, 78, 71]) { // PNG magic
                    detectedType = .png
                } else {
                    detectedType = .jpeg
                }
            } else {
                detectedType = .jpeg
            }
            appendAttachment(Attachment(
                data: imageData,
                fileURL: nil,
                type: detectedType
            ))
        } else if let clipboardString = PlatformClipboard.getString() {
            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pasted = URL(string: trimmed),
               (pasted.scheme == "http" || pasted.scheme == "https") {
                // A getyarn.io clip link (or its y.yarn.co media) pastes as the clip's GIF.
                let url: URL
                if let yarnUUID = YarnClipService.clipUUID(from: pasted) {
                    url = YarnClipService.mediaURL(uuid: yarnUUID, suffix: "_text_hi.gif")
                } else {
                    url = pasted
                }
                let ext = url.pathExtension.lowercased()
                let hasKnownExt = SupportedMediaFormats.allExtensions.contains(ext)
                // Media URL — download and add as attachment
                Task {
                    guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                        await MainActor.run { error = "Failed to download media from URL" }
                        return
                    }
                    // Determine the media type from extension, or fall back to Content-Type
                    let httpResponse = response as? HTTPURLResponse
                    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    let resolvedExt: String
                    if hasKnownExt {
                        resolvedExt = ext
                    } else if let mimeExt = SupportedMediaFormats.extension(forMime: contentType) {
                        resolvedExt = mimeExt
                    } else if !hasKnownExt {
                        // Not a recognized media URL
                        await MainActor.run { error = "Clipboard does not contain an image or media URL" }
                        return
                    } else {
                        resolvedExt = ext
                    }
                    let isVideo = SupportedMediaFormats.videoExtensions.contains(resolvedExt)
                    if isVideo {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("haven-paste-\(UUID().uuidString)")
                            .appendingPathExtension(resolvedExt)
                        try? data.write(to: tempURL)
                        let thumbnail = await generateVideoThumbnail(url: tempURL)
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .mpeg4Movie
                        await MainActor.run {
                            appendAttachment(Attachment(
                                data: nil,
                                fileURL: tempURL,
                                type: derivedType,
                                thumbnail: thumbnail
                            ))
                        }
                    } else {
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .jpeg
                        await MainActor.run {
                            appendAttachment(Attachment(
                                data: data,
                                fileURL: nil,
                                type: derivedType
                            ))
                        }
                    }
                }
            } else {
                error = "Clipboard does not contain an image or media URL"
            }
        } else {
            error = "Clipboard is empty"
        }
    }

    private func postNote() {
        isPosting = true
        autoSaveTask?.cancel()
        autoSaveTask = nil
        uploadInfoProvider.startUpload(totalCount: attachments.count)

        // Durably persist the current text to disk BEFORE the (potentially long) post
        // begins, so an unexpected crash during upload/mining/broadcast can't lose it.
        // The draft is cleared only once the post actually broadcasts (PendingPostManager),
        // so a cancel or crash in the pending window leaves it recoverable.
        let trimmedForDraft = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedForDraft.isEmpty || !attachments.isEmpty {
            let id = draftId ?? UUID().uuidString
            draftId = id
            DraftService.shared.saveDraftLocally(
                draftId: id,
                content: convertMentionsToNostr(content),
                replyTo: effectiveReplyTo,
                quoteTo: effectiveQuoteTo,
                taggedPubkeys: taggedPubkeys
            )
        }

        Task {
            // Request background execution time so upload + PoW mining (which can take
            // several seconds, more on slower devices or with PoW set high) isn't killed
            // mid-flight if the user backgrounds the app or locks the phone right after
            // tapping post.
            #if os(iOS)
            let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "ComposePost", expirationHandler: nil)
            #endif
            defer {
                #if os(iOS)
                UIApplication.shared.endBackgroundTask(bgTaskId)
                #endif
            }

            // 1. Upload media to Blossom mirrors
            // Convert `@name` display tokens back to canonical `nostr:npub…` references.
            var finalContent = convertMentionsToNostr(content)
            isUploading = true

            // NIP-92 descriptors, filled in as each upload lands. Published as
            // `imeta` tags so a reader can reserve the right box before the
            // bytes arrive and can read out what the media is.
            var mediaDescriptors: [NoteTagging.MediaDescriptor] = []

            // Upload all attachments and fail if any fail
            for i in attachments.indices {
                uploadInfoProvider.setCurrentIndex(i + 1, type: attachments[i].type)
                let mimeType = attachments[i].type.preferredMIMEType ?? "application/octet-stream"
                let progressHandler: (Double) -> Void = { progressFraction in
                    self.uploadInfoProvider.updateProgress(progressFraction)
                }

                let uploadedURL: URL?
                var uploadedSHA256: String?
                var pixelSize: CGSize?
                var byteCount: Int?
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
                    uploadedSHA256 = sha256
                    pixelSize = await ComposeView.pixelSize(ofVideoAt: fileURL)
                    byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int
                    uploadedURL = await blossomService.uploadAndMirror(
                        fileURL: fileURL,
                        sha256: sha256,
                        contentType: mimeType,
                        progress: progressHandler
                    )
                } else if let data = attachments[i].data {
                    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    uploadedSHA256 = sha256
                    pixelSize = ComposeView.pixelSize(ofImageData: data)
                    byteCount = data.count
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

                mediaDescriptors.append(NoteTagging.MediaDescriptor(
                    url: url.absoluteString,
                    mimeType: mimeType,
                    sha256: uploadedSHA256,
                    pixelWidth: pixelSize.map { Int($0.width.rounded()) },
                    pixelHeight: pixelSize.map { Int($0.height.rounded()) },
                    alt: attachments[i].altText,
                    byteCount: byteCount
                ))
            }
            isUploading = false
            uploadInfoProvider.reset()
            cleanupAttachmentTempFiles()

            // 2. Build Event
            var tags: [[String]] = []
            let relayHint = ConfigService.shared.config.nostrURL

            if let parent = effectiveReplyTo {
                // NIP-10 tags — for reposts (kind 6), reply to the original note, not the repost
                let effectiveParentId: String
                let effectiveParentPubkey: String
                let effectiveParentTags: [[String]]

                if parent.kind == 6, let originalId = parent.repostedEventId {
                    effectiveParentId = originalId
                    if let original = FeedService.shared.notes.first(where: { $0.id == originalId }) {
                        effectiveParentPubkey = original.pubkey
                        effectiveParentTags = original.tags
                    } else {
                        effectiveParentPubkey = parent.pubkey
                        effectiveParentTags = parent.tags
                    }
                } else {
                    effectiveParentId = parent.id
                    effectiveParentPubkey = parent.pubkey
                    effectiveParentTags = parent.tags
                }

                // NIP-10: Determine the thread root from the parent's e-tags
                let parentETags = effectiveParentTags.filter { $0.count >= 2 && $0[0] == "e" }
                let parentNonMentionETags = parentETags.filter { tag in
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }

                // NIP-10/NIP-01: addressable-event a-tags, alongside the e-tags above.
                // A parameterized replaceable event (kind 30000–39999, e.g. a long-form
                // article) gets a new event id every time it's edited, so an e-tag-only
                // reply silently becomes orphaned from other clients' view of the thread
                // once the author edits it — the "a" coordinate (kind:pubkey:d-tag) is
                // what stays stable across edits.
                func addressableCoordinate(kind: Int, pubkey: String, tags: [[String]]) -> String? {
                    guard kind >= 30000 && kind < 40000,
                          let dTag = tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return nil }
                    return "\(kind):\(pubkey):\(dTag)"
                }
                let parentNonMentionATags = effectiveParentTags.filter { tag in
                    guard tag.count >= 2 && tag[0] == "a" else { return false }
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }

                if parentNonMentionETags.isEmpty {
                    // Parent IS the root note — single e-tag with "root" marker.
                    // NIP-10: the optional 5th element is the event author's pubkey,
                    // used by the outbox model to know whose relays to fetch it from.
                    tags.append(["e", effectiveParentId, relayHint, "root", effectiveParentPubkey])
                    if let coord = addressableCoordinate(kind: parent.kind, pubkey: effectiveParentPubkey, tags: effectiveParentTags) {
                        tags.append(["a", coord, relayHint, "root"])
                    }
                } else {
                    // Parent is itself a reply — find the thread root
                    let threadRootId: String
                    let threadRootPubkey: String?
                    if let rootTag = parentNonMentionETags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
                        // Preferred: explicit "root" marker in parent's tags
                        threadRootId = rootTag[1]
                        threadRootPubkey = rootTag.count >= 5 ? rootTag[4] : nil
                    } else {
                        // Deprecated positional: first e-tag is the root
                        threadRootId = parentNonMentionETags[0][1]
                        threadRootPubkey = parentNonMentionETags[0].count >= 5 ? parentNonMentionETags[0][4] : nil
                    }
                    if let pk = threadRootPubkey {
                        tags.append(["e", threadRootId, relayHint, "root", pk])
                    } else {
                        tags.append(["e", threadRootId, relayHint, "root"])
                    }
                    tags.append(["e", effectiveParentId, relayHint, "reply", effectiveParentPubkey])

                    // Root a-tag: we only have the root's event id here (not its kind/
                    // pubkey/d-tag), so propagate it forward from the parent's own root
                    // a-tag if it had one.
                    if let rootATag = parentNonMentionATags.first(where: { $0.count >= 4 && $0[3] == "root" }) ?? parentNonMentionATags.first {
                        tags.append(["a", rootATag[1], relayHint, "root"])
                    }

                    // Reply a-tag: the immediate parent might itself be addressable.
                    if let coord = addressableCoordinate(kind: parent.kind, pubkey: effectiveParentPubkey, tags: effectiveParentTags) {
                        tags.append(["a", coord, relayHint, "reply"])
                    }
                }

                // Always tag the parent author
                tags.append(["p", effectiveParentPubkey])

                // NIP-10: Accumulate p-tags from parent (thread participants), deduplicated
                var seenPubkeys = Set<String>([effectiveParentPubkey])
                for tag in effectiveParentTags where tag.count >= 2 && tag[0] == "p" {
                    let pk = tag[1]
                    if seenPubkeys.insert(pk).inserted {
                        tags.append(["p", pk])
                    }
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

            // Quote post: append nevent reference and q tag (NIP-18)
            if let quoted = effectiveQuoteTo {
                finalContent += "\nnostr:\(quoted.nevent)"
                tags.append(["q", quoted.id, relayHint, quoted.pubkey])
                if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == quoted.pubkey }) {
                    tags.append(["p", quoted.pubkey])
                }
            }

            // NIP-24 `t` tags. Without these a note typed with #bitcoin is
            // invisible to hashtag feeds — including our own Search tab, which
            // builds its trending list from `t` tags. Read from finalContent so
            // a hashtag inside a `nostr:` reference or a media URL is excluded.
            tags.append(contentsOf: NoteTagging.hashtagTags(in: finalContent))

            // NIP-92 `imeta`, one per uploaded attachment, in content order.
            tags.append(contentsOf: NoteTagging.imetaTags(for: mediaDescriptors))

            // 3. Mine PoW + Sign
            let isReply = effectiveReplyTo != nil
            let powSnap = PowPreferences.snapshot()
            let powDifficulty = powSnap.noteEnabled ? powSnap.noteDifficulty : 0
            print("ComposeView: signing \(isReply ? "reply" : "post") – mode=\(configService.config.activeSigningMode()) nip46connected=\(NIP46Service.shared.isConnected) tags=\(tags.count) pow=\(powDifficulty)")
            guard let event = await nostrService.mineAndSignEventAsync(kind: 1, content: finalContent, tags: tags, difficulty: powDifficulty) else {
                await MainActor.run {
                    let signingMode = configService.config.activeSigningMode()
                    print("ComposeView: sign FAILED – signingMode=\(signingMode) activeNpub=\(configService.config.activeAccountNpub.prefix(20)) isReply=\(isReply)")
                    if signingMode == "nip46" {
                        error = "Remote signer failed to sign the event. Check that your bunker is connected."
                    } else {
                        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isWhitelisted = !activeNpub.isEmpty && activeNpub != configService.config.ownerNpub
                        if isWhitelisted {
                            error = "No private key stored for this account. Add its nsec in Settings to post as this account."
                        } else {
                            error = "Failed to sign event. Do you have your private key set in Settings?"
                        }
                    }
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

                // Hand to PendingPostManager — it will broadcast after countdown and then
                // delete the backing draft. We keep the draft alive until broadcast so a
                // crash/cancel during the pending window stays recoverable.
                PendingPostManager.shared.startPost(
                    event: event,
                    content: finalContent,
                    replyTo: self.effectiveReplyTo,
                    quoteTo: self.effectiveQuoteTo,
                    nostrService: self.nostrService,
                    draftId: self.draftId
                )

                // Mark content as "saved" so performDismiss won't re-save the draft
                self.lastSavedContent = self.content.trimmingCharacters(in: .whitespacesAndNewlines)

                isPosting = false
                performDismiss()
            }
        }
    }

    private func loadBlossomMedia() {
        guard !isLoadingBlossomMedia else { return }
        guard relayManager.isRunning && !relayManager.isBooting else {
            blossomMedia = []
            return
        }
        isLoadingBlossomMedia = true
        let relayDataDir = configService.relayDataDir
        let blossomPath = configService.config.blossomPath
        let ownerHex = nostrService.activeHexPubkey
        let webURL = configService.config.webURL
        let rpm = relayManager

        Task {
            let result = await Task.detached(priority: .background) { () -> [MediaItem] in
                let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
                guard FileManager.default.fileExists(atPath: blossomDir.path),
                      let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                    return []
                }
                return fileURLs.compactMap { fileURL -> MediaItem? in
                    let filename = fileURL.lastPathComponent
                    if filename.starts(with: ".") || filename == "LOCK" { return nil }
                    guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let date = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                    let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime
                    let mediaType: MediaItem.MediaType
                    if let mime = mimeType {
                        if mime.hasPrefix("video/") { mediaType = .video }
                        else if mime.hasPrefix("audio/") { mediaType = .audio }
                        else if mime.hasPrefix("image/") { mediaType = .image }
                        else { mediaType = .unknown }
                    } else {
                        mediaType = .unknown
                    }
                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
                }.sorted { $0.dateAdded > $1.dateAdded }
            }.value

            await MainActor.run {
                blossomMedia = result
                isLoadingBlossomMedia = false
            }
        }
    }

    private func handleCancelTapped() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSavableContent = !trimmed.isEmpty && (trimmed.contains(" ") || trimmed.count > 10)
        if hasSavableContent {
            showingDiscardConfirm = true
        } else {
            performDismiss()
        }
    }

    private func discardDraftAndDismiss() {
        autoSaveTask?.cancel()
        if let id = draftId {
            Task { await DraftService.shared.deleteDraft(id: id) }
        }
        // Nothing left to persist — mark current content "saved" so if performDismiss
        // were ever reached again it wouldn't re-save.
        lastSavedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func performDismiss() {
        autoSaveTask?.cancel()

        // Final save to local cache if content changed since last save
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty
            && (trimmed.contains(" ") || trimmed.count > 10)
            && trimmed != lastSavedContent {
            let id = draftId ?? UUID().uuidString
            if draftId == nil { draftId = id }

            // Fire off save — local disk write happens immediately inside saveDraft,
            // relay sync is best-effort and queued if unavailable
            Task {
                await DraftService.shared.saveDraft(
                    draftId: id,
                    content: convertMentionsToNostr(content),
                    replyTo: effectiveReplyTo,
                    quoteTo: effectiveQuoteTo,
                    taggedPubkeys: taggedPubkeys
                )
            }
        }

        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    // MARK: - Draft Auto-Save

    private func scheduleAutoSave(_ text: String) {
        autoSaveTask?.cancel()

        // Don't schedule saves while a post is in progress
        guard !isPosting else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't save empty content or very short fragments
        guard !trimmed.isEmpty, trimmed.contains(" ") || trimmed.count > 10 else { return }
        // Don't save if nothing changed since last save
        guard trimmed != lastSavedContent else { return }

        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s debounce
            guard !Task.isCancelled else { return }
            // Re-check after waking — a post may have started during the debounce
            guard !isPosting else { return }

            let id = draftId ?? UUID().uuidString
            if draftId == nil {
                await MainActor.run { draftId = id }
            }

            let canonicalContent = await MainActor.run { convertMentionsToNostr(content) }
            await DraftService.shared.saveDraft(
                draftId: id,
                content: canonicalContent,
                replyTo: effectiveReplyTo,
                quoteTo: effectiveQuoteTo,
                taggedPubkeys: taggedPubkeys
            )
            await MainActor.run { lastSavedContent = trimmed }
        }
    }

    private func loadDraft(_ draft: Draft) {
        draftId = draft.id
        content = convertNostrToMentions(draft.content)
        lastSavedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Restore reply context from saved draft
        if let replyId = draft.replyToId {
            draftReplyTo = FeedService.shared.notes.first(where: { $0.id == replyId })
                ?? FeedService.shared.parentNotesCache[replyId]
        } else {
            draftReplyTo = nil
        }

        // Restore quote context from saved draft
        // A quote of a repost saves the original's id, which may only exist
        // inside the repost that carried it — find that repost and rebuild the
        // original from it. Older drafts that saved the wrapper id resolve
        // through quoteTarget too, so they come back citing the original.
        if let quoteId = draft.quoteId {
            let feed = FeedService.shared
            let found = feed.findNote(id: quoteId)
                ?? feed.notes.first(where: { $0.id == quoteId })
                ?? feed.notes.first(where: { $0.kind == 6 && $0.repostedEventId == quoteId })
            draftQuoteTo = found.map { feed.quoteTarget(for: $0) }
        } else {
            draftQuoteTo = nil
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

struct BlossomMediaPickerSheet: View {
    @Binding var blossomMedia: [MediaItem]
    @Binding var isLoading: Bool
    let onSelect: (MediaItem) -> Void
    let onAppearLoad: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selectedFilter: BlossomMediaFilter = .all

    enum BlossomMediaFilter: String, CaseIterable {
        case all = "All"
        case photo = "Photo"
        case video = "Video"
        case gif = "GIF"
    }

    #if os(macOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    #else
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    #endif

    private var filteredMedia: [MediaItem] {
        switch selectedFilter {
        case .all:
            return blossomMedia
        case .photo:
            return blossomMedia.filter { $0.type == .image && !$0.isAnimatedGIF }
        case .video:
            return blossomMedia.filter { $0.type == .video }
        case .gif:
            return blossomMedia.filter { $0.isAnimatedGIF }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Loading media...")
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredMedia.isEmpty && !blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No \(selectedFilter.rawValue.lowercased()) media")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No media on Blossom")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(filteredMedia) { item in
                                BlossomPickerGridItem(item: item)
                                    .onTapGesture { onSelect(item) }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        ForEach(BlossomMediaFilter.allCases, id: \.self) { filter in
                            Button {
                                selectedFilter = filter
                            } label: {
                                Text(filter.rawValue)
                                    .font(.appSystem(size: 13, weight: selectedFilter == filter ? .semibold : .regular))
                                    .foregroundColor(selectedFilter == filter ? .white : .secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        selectedFilter == filter
                                            ? Color.havenPurple
                                            : Color.secondary.opacity(0.15)
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { onAppearLoad() }
    }
}

private struct BlossomPickerGridItem: View {
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    if item.type == .video {
                        VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.appSystem(size: 28))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.isAnimatedGIF {
                        AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 200, height: 200))
                    } else {
                        RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                    }
                }
            )
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

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
    func handleCancelTapped() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSavableContent = !trimmed.isEmpty && (trimmed.contains(" ") || trimmed.count > 10)
        if hasSavableContent {
            showingDiscardConfirm = true
        } else {
            performDismiss()
        }
    }

    func discardDraftAndDismiss() {
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

    func performDismiss() {
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

    func scheduleAutoSave(_ text: String) {
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

    func loadDraft(_ draft: Draft) {
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

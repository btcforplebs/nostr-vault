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
    // MARK: - @mention popup

    /// One-line strip of people, docked on the footer like the keyboard's own
    /// suggestion bar. The old five-row card stood ~260pt tall between the text
    /// and the footer; with the keyboard up on iPhone that squeezed the editor
    /// to a sliver and hid the line being typed. One row keeps the caret, and
    /// the `@name` being written, in view.
    var mentionPopup: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mentionResults.prefix(8)) { profile in
                    Button {
                        insertMention(profile)
                    } label: {
                        HStack(spacing: 8) {
                            AvatarView(url: profile.pictureURL, pubkey: profile.pubkey, size: 30)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(profile.bestName)
                                    .font(.appSystem(size: 14, weight: .semibold))
                                    .foregroundColor(.primary)
                                if let nip05 = profile.nip05, !nip05.isEmpty {
                                    Text(nip05)
                                        .font(.appSystem(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.havenPurple.opacity(0.1)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(profile.bestName)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(alignment: .top) { Divider() }
        .transition(.opacity)
        .animation(Motion.panel, value: mentionResults.count)
    }

    /// Called every time `content` changes — finds the @query at the caret, which
    /// may be anywhere in the text (not just at the end). The caret is located via
    /// the diff between the previous and new text, then we scan backwards from it to
    /// find the `@` that begins the token currently being edited.
    func updateMentionQuery(old: String, new text: String) {
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
        let wotSet = FeedService.shared.webOfTrustForRanking
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
        // not just follows, ranking thread participants, follows, then the rest
        // of the Web of Trust first.
        let lower = query.lowercased()
        let matches = nostrService.profiles.values.filter { profile in
            profile.pubkey != selfPubkey && (
                profile.bestName.lowercased().contains(lower) ||
                (profile.name?.lowercased().contains(lower) ?? false) ||
                (profile.nip05?.lowercased().contains(lower) ?? false)
            )
        }
        let ranked = matches.sorted { a, b in
            func rank(_ p: FeedProfile) -> (Int, Int, Int, Int) {
                (threadSet.contains(p.pubkey) ? 0 : 1,
                 followedSet.contains(p.pubkey) ? 0 : 1,
                 wotSet.contains(p.pubkey) ? 0 : 1,
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
        QuoteReference.profilePubkey(fromBech32: bech32)
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
    func convertNostrToMentions(_ text: String) -> String {
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
    func convertMentionsToNostr(_ text: String) -> String {
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
}

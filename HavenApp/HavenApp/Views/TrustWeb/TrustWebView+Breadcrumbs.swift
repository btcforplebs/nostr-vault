import SwiftUI

extension TrustWebView {
    // MARK: - Breadcrumbs

    var crumbRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.element) { index, pubkey in
                    if index > 0 { crumbArrow }
                    Button { jump(to: index) } label: { chip(pubkey, on: index == crumbs.count - 1) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(index == crumbs.count - 1 ? "" : "Goes back to this step"))
                }
                // On the WOT tab the destination is always you.
                if centerKey != author && !isWOTTab {
                    crumbArrow
                    chip(author, on: false, destination: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Looking for \(name(author))"))
                }
            }
            .padding(.horizontal)
        }
    }

    private var crumbArrow: some View {
        Text("›").font(.appSystem(size: 13)).foregroundColor(.secondary).accessibilityHidden(true)
    }

    private func chip(_ pubkey: String, on: Bool, destination: Bool = false) -> some View {
        HStack(spacing: 6) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 22)
            Text(name(pubkey))
                .font(.appSystem(size: 13))
                .lineLimit(1)
            if !destination, pubkey != me, frames[pubkey] == nil {
                ProgressView().controlSize(.mini).tint(.white)
                    .accessibilityLabel(Text("Loading \(name(pubkey))'s follows"))
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .foregroundColor(destination ? Color.havenPurple : .primary)
        .background(Capsule().fill(on ? Color.havenPurple.opacity(0.22) : Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(destination ? Color.havenPurple.opacity(0.5) : .clear, lineWidth: 1))
    }

    // MARK: - Words

    /// "47", or "at least 5" while relays may hold more: the count is only
    /// the signed lists actually checked, never a number a relay states.
    private func countText(_ frame: Frame) -> String {
        frame.exhausted ? "\(frame.bridges.count)" : "at least \(frame.bridges.count)"
    }

    /// The globe's words for VoiceOver, which reads the picture as one element.
    var summary: String {
        guard let frame else { return "Loading who \(name(centerKey)) follows." }
        if frame.center == me && author == me {
            return "You, the \(frame.ring.count) people you follow, and your web around them."
        }
        let them = name(author)
        let who = frame.center == me ? "you follow" : "\(name(frame.center)) follows"
        if frame.bridges.isEmpty {
            return frame.ring.contains(author) ? "\(name(frame.center)) follows \(them) directly." : "No one \(who) was seen following \(them)."
        }
        let named = frame.bridges.prefix(2).map(name).joined(separator: ", ")
        return "\(them) is followed by \(countText(frame)) people \(who), including \(named)."
    }
}

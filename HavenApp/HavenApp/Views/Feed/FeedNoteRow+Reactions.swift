import SwiftUI

extension FeedNoteRow {
    /// Toggle like: delegates to the appropriate action closure. Only the
    /// liking direction pulses — a pulse is confirmation of the tap that just
    /// happened, not a description of the resulting state, so it must not
    /// also fire when a like arrives from backfill or another client.
    /// The account's reaction as it should read on the button, if any.
    private var shownReaction: String? {
        guard rowData.isLiked else { return nil }
        return reactionDisplayEmoji(rowData.myReaction ?? "+")
    }

    /// Tap: react with the default, or take the reaction back. Hold: the
    /// tapback bar (see `ReactionTapback`); sliding onto an emoji and letting
    /// go sends it.
    @ViewBuilder
    var reactionButton: some View {
        let shown = shownReaction
        let likes = rowData.engagement?.likes
        HStack(spacing: 4) {
            if let shown, shown != "❤️" {
                Text(shown)
                    .font(.system(size: 16))
            } else {
                Image(systemName: shown == nil ? "heart" : "heart.fill")
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(shown == nil ? .secondary : .red)
            }
            countText(likes)
        }
        .padding(.horizontal, (likes ?? 0) > 0 ? 10 : 0)
        .frame(minWidth: 32, minHeight: 32, maxHeight: 32)
        .background(shown == nil ? Color.secondary.opacity(0.1)
                    : shown == "❤️" ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.18))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .scaleEffect(likePulse ? Motion.pulseScale : 1.0)
        .animation(Motion.pop, value: likePulse)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reactionButtonFrame = $0 }
        .onTapGesture { toggleLike() }
        #if os(iOS)
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($holdingReaction) { value, holding, _ in
                    if case .second(true, _) = value { holding = true }
                }
                .onChanged { value in
                    if case .second(true, let drag?) = value {
                        ReactionTapback.shared.track(drag.location)
                    }
                }
        )
        .onChange(of: holdingReaction) { _, holding in
            if holding {
                openTapback()
            } else {
                ReactionTapback.shared.release()
            }
        }
        // Torn down mid-hold, the row can no longer end it.
        .onDisappear { ReactionTapback.shared.close(for: note.id) }
        #else
        .onLongPressGesture(minimumDuration: 0.35) { showingTapbackPopover = true }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.map { "Your reaction: \($0)" } ?? "React")
        .accessibilityValue(countLabel(likes, "likes"))
        .accessibilityHint(shown == nil ? "Hold for more reactions" : "Removes your reaction. Hold to change it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleLike() }
        .accessibilityAction(named: "More reactions") { showingEmojiPicker = true }
    }

    #if os(iOS)
    private func openTapback() {
        ReactionTapback.shared.begin(
            noteId: note.id,
            anchor: reactionButtonFrame,
            current: shownReaction,
            defaultContent: ConfigService.shared.config.defaultReactionEmoji,
            onPick: { pickReaction($0) },
            onMore: { showingEmojiPicker = true }
        )
    }
    #endif

    /// Sends `emoji` as the reaction; picking the one already sent takes it back.
    func pickReaction(_ emoji: String) {
        if emoji == shownReaction {
            actions.unlikeNote(note)
        } else {
            actions.reactToNote(note, emoji)
            Motion.firePulse($likePulse)
        }
    }

    private func toggleLike() {
        if rowData.isLiked {
            actions.unlikeNote(note)
        } else {
            actions.likeNote(note)
            Motion.firePulse($likePulse)
        }
    }
}

import SwiftUI

/// A bubble draws again only when what it shows changed. Without this, any
/// change to any conversation redrew every visible bubble in an open chat
/// (~55 per incoming message, Messages perf review 2026-11-28 #3): the
/// closures it takes are new on every thread redraw, so SwiftUI could never
/// tell it was the same. The closures act on `message.id`, compared here.
extension MessageBubbleView: Equatable {
    nonisolated static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content == rhs.message.content
            && lhs.message.isNIP04 == rhs.message.isNIP04
            && lhs.message.sendState == rhs.message.sendState
            && lhs.message.sendFailure == rhs.message.sendFailure
            && lhs.profile == rhs.profile
            && lhs.containerWidth == rhs.containerWidth
            && lhs.mediaZoom == rhs.mediaZoom
            && lhs.canRetry == rhs.canRetry
            && lhs.masked == rhs.masked
            && lhs.outlined == rhs.outlined
    }
}

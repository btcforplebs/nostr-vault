import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One Genmoji as the system hands it over: its HEIC picture, a stable ID
/// and its description (NSAdaptiveImageGlyph).
struct GenmojiPick: Equatable {
    let imageContent: Data
    let id: String
    let description: String
}

/// A one-line text field that accepts Genmoji (made in the emoji keyboard,
/// or pasted). When one lands it is passed to `onPick` and the field is
/// cleared, ready for the next. Plain text typed here is ignored.
@available(iOS 18.0, macOS 15.0, *)
struct GenmojiField {
    let onPick: (GenmojiPick) -> Void

    static func firstGlyph(in text: NSAttributedString) -> GenmojiPick? {
        var pick: GenmojiPick?
        text.enumerateAttribute(.adaptiveImageGlyph, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let glyph = value as? NSAdaptiveImageGlyph else { return }
            pick = GenmojiPick(imageContent: glyph.imageContent, id: glyph.contentIdentifier,
                               description: glyph.contentDescription)
            stop.pointee = true
        }
        return pick
    }

    final class Coordinator: NSObject {
        let onPick: (GenmojiPick) -> Void
        init(onPick: @escaping (GenmojiPick) -> Void) { self.onPick = onPick }

        func take(_ text: NSAttributedString) -> Bool {
            guard let pick = GenmojiField.firstGlyph(in: text) else { return false }
            onPick(pick)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
}

#if os(iOS)
@available(iOS 18.0, *)
extension GenmojiField: UIViewRepresentable {
    /// Opens on the emoji keyboard, where the Genmoji button is.
    final class EmojiTextView: UITextView {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = EmojiTextView()
        view.supportsAdaptiveImageGlyph = true
        view.allowsEditingTextAttributes = true
        view.font = .preferredFont(forTextStyle: .title1)
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.delegate = context.coordinator
        view.accessibilityLabel = "Genmoji"
        view.accessibilityHint = "Make a Genmoji in the emoji keyboard, or paste one"
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

@available(iOS 18.0, *)
extension GenmojiField.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        if take(textView.attributedText) { textView.attributedText = NSAttributedString() }
    }
}
#else
@available(macOS 15.0, *)
extension GenmojiField: NSViewRepresentable {
    /// Rich text that says it takes Genmoji (read-only on the Mac, so overridden).
    final class GlyphTextView: NSTextView {
        override var supportsAdaptiveImageGlyph: Bool { true }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = GlyphTextView()
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.font = .systemFont(ofSize: 28)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Genmoji")
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

@available(macOS 15.0, *)
extension GenmojiField.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
        if take(storage) { storage.setAttributedString(NSAttributedString()) }
    }
}
#endif

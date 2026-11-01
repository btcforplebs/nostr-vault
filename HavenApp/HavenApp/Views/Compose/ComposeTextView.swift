import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The note editor. SwiftUI's `TextEditor` does not say where the caret is,
/// and a photo's link goes in at the caret, so the editor is the platform
/// text view (`UITextView`, `NSTextView`) reporting its selection.
///
/// It grows with its text inside the composer's scroll view, as `TextEditor`
/// did. When the app changes the text itself (a mention filled in, a link
/// written in) the caret follows the change instead of jumping to the end.
struct ComposeTextView {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    var fontSize: CGFloat
    var minHeight: CGFloat

    final class Coordinator: NSObject {
        var parent: ComposeTextView
        /// True while the view itself is applying the binding, so its own
        /// delegate callbacks are not echoed back as edits.
        var applying = false
        init(_ parent: ComposeTextView) { self.parent = parent }

        func report(text: String, selection: NSRange) {
            guard !applying else { return }
            if parent.text != text { parent.text = text }
            if parent.selection != selection {
                let binding = parent.$selection
                // Selection callbacks can arrive mid view update.
                DispatchQueue.main.async { binding.wrappedValue = selection }
            }
        }

        func reportFocus(_ focused: Bool) {
            guard parent.isFocused != focused else { return }
            let binding = parent.$isFocused
            DispatchQueue.main.async { binding.wrappedValue = focused }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The caret after `old` became `new` from outside the editor, clamped.
    static func caret(after old: String, becomes new: String, from range: NSRange) -> NSRange {
        let caret = ComposerPlacement.followCaret(range.location + range.length, old: old, new: new)
        return NSRange(location: max(0, min(caret, new.utf16.count)), length: 0)
    }
}

#if canImport(UIKit)
extension ComposeTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: fontSize)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.allowsEditingTextAttributes = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Post content"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
        if view.text != text {
            coordinator.applying = true
            let old = view.text ?? ""
            let caret = Self.caret(after: old, becomes: text, from: view.selectedRange)
            view.text = text
            view.selectedRange = caret
            coordinator.applying = false
            let binding = $selection
            DispatchQueue.main.async { binding.wrappedValue = caret }
        }
        if isFocused, !view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, fitted.height))
    }
}

extension ComposeTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        report(text: textView.text ?? "", selection: textView.selectedRange)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        report(text: textView.text ?? "", selection: textView.selectedRange)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { reportFocus(true) }
    func textViewDidEndEditing(_ textView: UITextView) { reportFocus(false) }
}
#else
extension ComposeTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: fontSize)
        view.textContainerInset = NSSize(width: 0, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Post content")
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
        if view.string != text {
            coordinator.applying = true
            let old = view.string
            let caret = Self.caret(after: old, becomes: text, from: view.selectedRange())
            view.string = text
            view.setSelectedRange(caret)
            coordinator.applying = false
            let binding = $selection
            DispatchQueue.main.async { binding.wrappedValue = caret }
        }
        if isFocused, let window = view.window, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 460
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width - nsView.textContainerInset.width * 2, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + nsView.textContainerInset.height * 2
        return CGSize(width: width, height: max(minHeight, ceil(height)))
    }
}

extension ComposeTextView.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        report(text: view.string, selection: view.selectedRange())
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        report(text: view.string, selection: view.selectedRange())
    }

    func textDidBeginEditing(_ notification: Notification) { reportFocus(true) }
    func textDidEndEditing(_ notification: Notification) { reportFocus(false) }
}
#endif

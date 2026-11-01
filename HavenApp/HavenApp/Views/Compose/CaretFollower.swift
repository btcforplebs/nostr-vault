import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// Keeps the caret on screen while typing. The editor grows with its text
/// inside the compose ScrollView, so the text view never scrolls itself and
/// UIKit doesn't scroll the SwiftUI ScrollView around it: once a note ran
/// past the keyboard (or the @mention strip appeared), the line being typed
/// slid out of sight. On every edit this scrolls the enclosing scroll view
/// just enough to show the caret.
struct CaretFollower: UIViewRepresentable {
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

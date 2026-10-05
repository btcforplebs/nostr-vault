import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// "Translate" under a post written in another language. Runs on the device
/// with Apple's translator; nothing is sent anywhere. On iOS 18 / macOS 15
/// the translation appears inline under the post; on iOS 17.4 / macOS 14.4 it
/// opens the system translation sheet; older systems show no button.
struct NoteTranslateButton: View {
    /// Identifies the post (caches its language); `content` is what is shown,
    /// which for a bare repost is the original's text.
    let noteID: String
    let content: String
    let kind: Int
    @ObservedObject private var configService = ConfigService.shared

    @State private var detected: String?
    @State private var didDetect = false
    @State private var translated: String?
    @State private var showingTranslation = false
    @State private var isTranslating = false
    @State private var failed = false
    @State private var showingSystemSheet = false
    @State private var requestID = 0

    /// Detected languages, by note id. Detection is cheap but rows re-render
    /// constantly while scrolling.
    private static let languageCache = NSCache<NSString, NSString>()
    private static let noLanguage = "-" as NSString

    private var target: String {
        NoteTranslation.targetCode(setting: configService.config.translateTargetLanguage)
    }

    private var text: String {
        NoteTranslation.translatableText(FeedLanguageDetector.text(of: content, kind: kind))
    }

    var body: some View {
        Group {
            if configService.config.showTranslateButton, Self.isSupported,
               didDetect, NoteTranslation.shouldOffer(detected: detected, target: target) {
                VStack(alignment: .leading, spacing: 6) {
                    if showingTranslation, let translated {
                        Text(translated)
                            .font(.appSystem(size: 17))
                            .foregroundColor(.white.opacity(0.92))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.havenPurple.opacity(0.6)).frame(width: 2)
                            }
                    }
                    button
                }
                .modifier(TranslationDriver(
                    text: text, source: detected, target: target, requestID: requestID,
                    showingSystemSheet: $showingSystemSheet,
                    onResult: { result in
                        isTranslating = false
                        if let result {
                            translated = result
                            showingTranslation = true
                            failed = false
                        } else {
                            failed = true
                        }
                    }
                ))
            } else {
                // Something must be on screen for .task to run the detection
                // that decides whether to show the button at all.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: noteID + content) { detect() }
    }

    private var button: some View {
        Button {
            if translated != nil {
                withAnimation(Motion.fade) { showingTranslation.toggle() }
                return
            }
            if Self.isInline {
                isTranslating = true
                failed = false
                requestID += 1
            } else {
                showingSystemSheet = true
            }
        } label: {
            HStack(spacing: 4) {
                if isTranslating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "translate")
                }
                Text(label)
            }
            .font(.appSystem(size: 13, weight: .medium))
            .foregroundColor(failed ? .red.opacity(0.8) : Color.havenPurple)
        }
        .buttonStyle(.plain)
        .disabled(isTranslating)
        .accessibilityLabel(label)
    }

    private var label: String {
        if isTranslating { return "Translating…" }
        if failed { return "Couldn't translate — try again" }
        if showingTranslation { return "Show original only" }
        let name = detected.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? ""
        return name.isEmpty ? "Translate" : "Translate from \(name)"
    }

    private func detect() {
        let key = (noteID + "|" + String(content.count)) as NSString
        if let cached = Self.languageCache.object(forKey: key) {
            detected = cached == Self.noLanguage ? nil : cached as String
        } else {
            let code = FeedLanguageDetector.detect(FeedLanguageDetector.text(of: content, kind: kind))
            Self.languageCache.setObject((code ?? Self.noLanguage as String) as NSString, forKey: key)
            detected = code
        }
        didDetect = true
    }

    static var isInline: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    static var isSupported: Bool {
        if #available(iOS 17.4, macOS 14.4, *) { return true }
        return false
    }
}

/// Wires the button to Apple's Translation framework: an inline session on
/// iOS 18 / macOS 15, the system sheet on iOS 17.4 / macOS 14.4.
private struct TranslationDriver: ViewModifier {
    let text: String
    let source: String?
    let target: String
    let requestID: Int
    @Binding var showingSystemSheet: Bool
    let onResult: (String?) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, macOS 15.0, *) {
            content.modifier(InlineTranslation(text: text, source: source, target: target,
                                               requestID: requestID, onResult: onResult))
        } else if #available(iOS 17.4, macOS 14.4, *) {
            content.translationPresentation(isPresented: $showingSystemSheet, text: text)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, macOS 15.0, *)
private struct InlineTranslation: ViewModifier {
    let text: String
    let source: String?
    let target: String
    let requestID: Int
    let onResult: (String?) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    await MainActor.run { onResult(response.targetText) }
                } catch {
                    await MainActor.run { onResult(nil) }
                }
            }
            .onChange(of: requestID) { _, _ in
                let next = TranslationSession.Configuration(
                    source: source.map { Locale.Language(identifier: $0) },
                    target: Locale.Language(identifier: target)
                )
                if configuration == next {
                    // Same languages again: invalidate re-runs the task.
                    configuration?.invalidate()
                } else {
                    configuration = next
                }
            }
    }
}
#endif

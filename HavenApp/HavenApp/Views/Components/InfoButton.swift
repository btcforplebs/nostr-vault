import SwiftUI

/// The (i) next to a setting: tap it for one or two sentences about what the
/// setting does.
///
/// Settings used to explain themselves in Section footers, some of them four
/// sentences long and covering several controls at once, so the words sat
/// under the wrong row and most people never read them. The explanation now
/// sits on the control it describes and stays hidden until asked for.
///
/// The words live in `SettingsHelp`, keyed the same way as the Android
/// `SettingsHelp`, so both apps say the same thing about the same setting.
/// A topic with no text draws nothing, so a missing string can't ship as an
/// empty bubble.
struct InfoButton: View {
    let topic: SettingsHelp

    @State private var isShown = false

    init(_ topic: SettingsHelp) {
        self.topic = topic
    }

    var body: some View {
        if !topic.text.isEmpty {
            Button {
                isShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.appSubheadline)
                    // A plain grey, not `.secondary`: inside a Button the
                    // hierarchical style resolves against the button's tint,
                    // so the icon came out as a faded accent colour.
                    .foregroundStyle(Color.secondary)
                    .frame(width: hitSize, height: hitSize)
                    .contentShape(Rectangle())
            }
            // Borderless keeps the tap on the icon: inside a Form row a
            // default-style button would claim the whole row.
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(topic.title)")
            .popover(isPresented: $isShown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.title)
                        .font(.appSubheadline.weight(.semibold))
                    Text(topic.text)
                        .font(.appFootnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
                // iPhone would otherwise turn a popover into a full sheet,
                // which is far too heavy for two sentences.
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var hitSize: CGFloat {
        // A full 44pt touch target on iOS; the glyph stays small inside it.
        #if os(iOS)
        return 44
        #else
        return 20
        #endif
    }
}

extension View {
    /// Puts an (i) after a setting's label: `Text("Autoplay").settingInfo(.mediaAutoplay)`.
    func settingInfo(_ topic: SettingsHelp) -> some View {
        HStack(spacing: 2) {
            self
            InfoButton(topic)
        }
    }
}

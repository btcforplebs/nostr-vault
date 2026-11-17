import SwiftUI
import ImagePlayground

/// "Make Genmoji" at the top of the reaction picker. Shown only where this
/// device can make Genmoji (iOS 18.2 / macOS 15.3 with Apple Intelligence:
/// `supportsImagePlayground`) and for an account that can sign; hidden
/// everywhere else (GenmojiSets.showsMakeRow).
@available(iOS 18.2, macOS 15.3, *)
struct GenmojiMakeRow: View {
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @ObservedObject private var configService = ConfigService.shared
    let searching: Bool
    let onTap: () -> Void

    var body: some View {
        if GenmojiSets.showsMakeRow(reacting: true, searching: searching,
                                    canSign: configService.activeAccountCanSign,
                                    canMake: supportsImagePlayground) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "face.smiling.inverse")
                        .font(.appSystem(size: 18))
                        .foregroundColor(.accentText)
                        .frame(width: 28, height: 28)
                    Text("Make Genmoji")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.havenPurple.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Make Genmoji")
            .accessibilityHint("Make a Genmoji or Memoji sticker and react with it")
        }
    }
}

/// Make (or paste) one Genmoji or Memoji sticker, see it, then one button:
/// "React and save publicly" uploads it, adds it to My Genmoji and hands the
/// emoji back to react with (kind 7 + emoji tag, done by the picker's caller).
/// The save is GenmojiSaver, the same as the Emoji page's Add Genmoji.
/// A sheet on iOS; inside the picker popover on the Mac.
@available(iOS 18.2, macOS 15.3, *)
struct GenmojiReactSheet: View {
    let onCancel: () -> Void
    let onReact: (ReactionPick) -> Void

    @ObservedObject private var library = EmojiListService.shared
    @ObservedObject private var nostr = NostrService.shared
    @StateObject private var saver = GenmojiSaver()

    @State private var pick: GenmojiPick?
    @State private var png: Data?
    @State private var unreadable = false

    private var shortcode: String {
        GenmojiSets.shortcode(for: pick?.description ?? "", taken: GenmojiSets.takenShortcodes(library.library))
    }
    private var target: GenmojiSets.Target {
        GenmojiSets.targets(sets: library.library.sets, me: nostr.activeHexPubkey)[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let png, let image = PlatformImage(data: png) {
                        VStack(spacing: 8) {
                            Image(platformImage: image)
                                .resizable().interpolation(.high).scaledToFit()
                                .frame(width: 96, height: 96)
                                .accessibilityLabel(pick?.description ?? "Genmoji")
                            Text(":\(shortcode):")
                                .font(.appSystem(size: 13).monospaced())
                                .foregroundColor(.secondary)
                            Button("Use a different one") { clearPick() }
                                .font(.appSystem(size: 13))
                                .disabled(saver.isWorking)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    } else {
                        GenmojiField { accept($0) }
                            .frame(minHeight: 52)
                    }
                } footer: {
                    if unreadable {
                        Text("That Genmoji's picture couldn't be read. Try another.").foregroundColor(.red)
                    } else if png == nil {
                        #if os(iOS)
                        Text("Tap the Genmoji button in the emoji keyboard to make one, pick a Memoji sticker, or paste one.")
                        #else
                        Text("Make one in the emoji viewer (Edit → Emoji & Symbols), or paste one from Messages.")
                        #endif
                    }
                }

                Section {
                    switch saver.state {
                    case .working(let text):
                        HStack { ProgressView(); Text(text).foregroundColor(.secondary) }
                    case .failed(let text):
                        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
                    case .saved, .idle:
                        EmptyView()
                    }
                    Button { react() } label: {
                        Text(GenmojiSets.reactLabel)
                            .font(.appSystem(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(png == nil || saver.isWorking)
                } footer: {
                    Text(GenmojiSets.reactNote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Make Genmoji")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(saver.isWorking)
                }
            }
            .onAppear { EmojiVaultStore.shared.useActiveAccount() }
        }
        .interactiveDismissDisabled(saver.isWorking)
    }

    private func accept(_ new: GenmojiPick) {
        guard !saver.isWorking else { return }
        saver.reset()
        guard let data = GenmojiImage.largestFramePNG(new.imageContent) else {
            unreadable = true
            return
        }
        unreadable = false
        pick = new
        png = data
    }

    private func clearPick() {
        pick = nil
        png = nil
        saver.reset()
    }

    private func react() {
        guard let png else { return }
        let me = nostr.activeHexPubkey
        let code = shortcode
        let target = target
        Task {
            guard let emoji = await saver.save(png: png, shortcode: code, d: target.d, title: target.title) else { return }
            // The account switched after the save: don't react as the other one.
            guard nostr.activeHexPubkey == me else { return }
            onReact(ReactionPick(emoji))
        }
    }
}

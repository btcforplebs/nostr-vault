import SwiftUI

// MARK: - AccountSwitcherView

struct AccountSwitcherView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var unreadStore = AccountUnreadStore.shared
    @Environment(\.dismiss) private var dismiss

    // Key import sheet state
    @State private var importingNpub: String? = nil
    @State private var importNsec: String = ""
    @State private var importPassword: String = ""
    @State private var importConfirm: String = ""
    @State private var importError: String? = nil
    @State private var importSuccess: Bool = false

    private var activeNpub: String {
        let a = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? configService.config.ownerNpub : a
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Accounts")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Account rows
            VStack(spacing: 2) {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 270)
        .background(Color.platformControlBackground)
        .sheet(item: Binding<IdentifiableString?>(
            get: { importingNpub.map { IdentifiableString(id: $0) } },
            set: { importingNpub = $0?.id }
        )) { item in
            importKeySheet(forNpub: item.id)
        }
    }

    @ViewBuilder
    private func accountRow(npub: String) -> some View {
        let isOwner = npub == configService.config.ownerNpub
        let isActive = npub == activeNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? AccountSwitcherIdentity.shortNpub(npub)
        let hasKey = isOwner || configService.hasCredential(forNpub: npub)

        Button(action: {
            configService.switchActiveAccount(to: npub)
            dismiss()
        }) {
            HStack(spacing: 10) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: profile?.pictureURL, pubkey: hex, size: 34)
                        .overlay(
                            Circle()
                                .stroke(
                                    isActive
                                        ? (isOwner ? Color.havenPurple : Color.orange)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                        )
                }

                // Name + badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isOwner {
                            Text("Owner")
                                .font(.appSystem(size: 9, weight: .bold))
                                .foregroundColor(Color.havenPurple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.havenPurple.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    // The key, not the name, is what tells two accounts apart.
                    Text(AccountSwitcherIdentity.shortNpub(npub))
                        .font(.appSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // New notifications for an account you are not on.
                if !isActive, let badge = AccountUnread.badge(unreadStore.count(npub: npub)) {
                    Text(badge)
                        .font(.appSystem(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color.havenPurple))
                        .accessibilityLabel("\(badge) new")
                }

                // Key status / import
                if !hasKey {
                    Button(action: { importingNpub = npub }) {
                        Image(systemName: "key.fill")
                            .font(.appSystem(size: 11))
                            .foregroundColor(.orange)
                            .padding(6)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Import signing key")
                } else {
                    Image(systemName: "key.fill")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary.opacity(0.4))
                }

                // Active checkmark
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 15))
                    .foregroundColor(isActive ? Color.havenPurple : .secondary.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.havenPurple.opacity(0.08) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: - Import Key Sheet

    @ViewBuilder
    private func importKeySheet(forNpub npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(20)) + "..."

        VStack(spacing: 0) {
            // Sheet header
            HStack {
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Key")
                        .font(.appHeadline)
                    Text(displayName)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Private Key") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $importNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(4)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        if importNsec.isEmpty {
                            Text("nsec1...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    Text("Enter the nsec for \(displayName)")
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                }

                Section("Encrypt with Password (NIP-49)") {
                    // Hidden username field anchors AutoFill to the npub so the
                    // nsec text editor above is not captured as the username.
                    TextField("", text: .constant(npub))
                        .textContentType(.username)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    SecureField("Password", text: $importPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $importConfirm)
                        .textContentType(.newPassword)
                    Label("Password saved to Keychain automatically", systemImage: "lock.fill")
                        .font(.appCaption)
                        .foregroundColor(.green)
                }

                if let error = importError {
                    Section {
                        Text(error).font(.appCaption).foregroundColor(.red)
                    }
                }
                if importSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Key imported successfully!").font(.appCaption).fontWeight(.semibold)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    resetImportForm()
                    importingNpub = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    saveImportedKey(forNpub: npub)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importPassword.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
    }

    private func saveImportedKey(forNpub npub: String) {
        let nsecTrimmed = importNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nsecTrimmed.isEmpty else { importError = "Private key cannot be empty"; return }
        guard importPassword == importConfirm else { importError = "Passwords do not match"; return }
        guard importPassword.count >= 8 else { importError = "Password must be at least 8 characters"; return }

        do {
            try NIP49Service.validateImport(nsec: nsecTrimmed, matching: npub)
        } catch {
            importError = error.localizedDescription
            return
        }

        do {
            try configService.setCredential(nsec: nsecTrimmed, password: importPassword, forNpub: npub)
            importSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                resetImportForm()
                importingNpub = nil
            }
        } catch {
            importError = "Failed to encrypt key: \(error.localizedDescription)"
        }
    }

    private func resetImportForm() {
        importNsec = ""
        importPassword = ""
        importConfirm = ""
        importError = nil
        importSuccess = false
    }
}

// MARK: - Telling accounts apart

/// What every account switcher shows next to a name. Profile names are free
/// text, so two accounts can share one; the key cannot. Each row carries the
/// account's own picture and a short npub, and rows are keyed by npub.
enum AccountSwitcherIdentity {
    /// "npub1abc…wxyz": the prefix with the first three key characters, then
    /// the last four.
    static func shortNpub(_ npub: String) -> String {
        guard npub.count > 12 else { return npub }
        return "\(npub.prefix(8))…\(npub.suffix(4))"
    }

    /// The account's picture as a round menu icon, or nil until it is cached.
    /// System menus draw an image at its own size and drop SwiftUI modifiers,
    /// so the size and the circle are baked into the bitmap.
    static func menuIcon(pictureURL: URL?) -> PlatformImage? {
        guard let url = pictureURL else { return nil }
        if let kept = AccountMenuAvatars.shared.icons[url] { return kept }
        guard let image = AvatarImageCache.shared.image(for: url) else { return nil }
        return menuIcon(image)
    }

    static func menuIcon(_ image: PlatformImage) -> PlatformImage {
        #if os(macOS)
        let side: CGFloat = 18
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: aspectFill(image.size, in: rect))
            return true
        }
        #else
        let side: CGFloat = 24
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: rect.size).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: aspectFill(image.size, in: rect))
        }
        return rendered.withRenderingMode(.alwaysOriginal)
        #endif
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Loads every account's picture so a switcher menu has them when it opens,
/// and keeps the round icons itself. The shared avatar cache holds 300
/// pictures, so scrolling a feed pushed the accounts' pictures out, and the
/// menu fell back to the generic icon until the app restarted. A handful of
/// 24 pt icons costs nothing to keep. A menu builds its items once, so this
/// publishes when an icon lands and the menu rebuilds.
final class AccountMenuAvatars: ObservableObject {
    static let shared = AccountMenuAvatars()
    @Published private(set) var icons: [URL: PlatformImage] = [:]

    func prefetch(_ urls: [URL]) {
        let wanted = Set(urls)
        if icons.keys.contains(where: { !wanted.contains($0) }) {
            icons = icons.filter { wanted.contains($0.key) }
        }
        for url in wanted where icons[url] == nil {
            AvatarImageCache.shared.load(url: url) { [weak self] image in
                guard let image else { return }
                self?.icons[url] = AccountSwitcherIdentity.menuIcon(image)
            }
        }
    }

    static func pictureURLs(npubs: [String], profiles: [String: FeedProfile]) -> [URL] {
        npubs.compactMap { npub in
            Bech32.decode(npub).flatMap { profiles[$0.hexString]?.pictureURL }
        }
    }
}

/// One account in a system menu: picture, name, short npub, and a checkmark
/// on the active account. A Toggle so the checkmark and the picture both show;
/// a Label's icon slot only holds one.
struct AccountMenuItem: View {
    let npub: String
    let name: String
    let pictureURL: URL?
    let isActive: Bool
    /// New notifications for this account since its Vault list was viewed
    /// (AccountUnreadStore). Not shown on the active account, whose Vault tab
    /// carries its own dot.
    var unread: Int = 0
    let select: () -> Void

    /// "3 new", or nil when there is nothing to show.
    private var unreadText: String? {
        guard !isActive, let badge = AccountUnread.badge(unread) else { return nil }
        return "\(badge) new"
    }

    var body: some View {
        let short = AccountSwitcherIdentity.shortNpub(npub)
        Toggle(isOn: Binding(get: { isActive }, set: { _ in select() })) {
            #if os(macOS)
            Label {
                // A macOS menu item keeps one line of text.
                Text(unreadText.map { "\(name)  ·  \($0)  \(short)" } ?? "\(name)  \(short)")
            } icon: {
                icon
            }
            #else
            // An iOS menu reads a second Text as the subtitle only when the
            // texts and the image sit directly in the label; inside a Label
            // the subtitle is dropped. A menu row takes no badge view, so the
            // count leads the subtitle.
            Text(name)
            Text(unreadText.map { "\($0) · \(short)" } ?? short)
            icon
            #endif
        }
        .accessibilityLabel(unreadText.map { "\(name), \($0), \(short)" } ?? "\(name), \(short)")
    }

    @ViewBuilder private var icon: some View {
        if let icon = AccountSwitcherIdentity.menuIcon(pictureURL: pictureURL) {
            #if os(macOS)
            Image(nsImage: icon)
            #else
            Image(uiImage: icon)
            #endif
        } else {
            Image(systemName: "person.crop.circle")
        }
    }
}

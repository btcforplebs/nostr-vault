import SwiftUI

struct GroupBrowserView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var relayInput: String = ""

    private var isConnecting: Bool { groupService.browseState == .loading }

    private var joinedGroupIds: Set<String> {
        Set(configService.config.joinedGroups.map {
            GroupIdentifier(relayURL: $0.relayURL, groupId: $0.groupId).canonicalId
        })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Relay URL input
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("wss://groups.example.com", text: $relayInput)
                            .textFieldStyle(.plain)
                            .font(.appSystem(size: 14))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif

                        Button(action: browse) {
                            if isConnecting {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                            } else {
                                Text(String(localized: "group.browser.browse"))
                                    .font(.appSystem(size: 14, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .disabled(relayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Saved relay chips
                    if !configService.config.groupRelayURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(configService.config.groupRelayURLs, id: \.self) { url in
                                    Button(action: {
                                        relayInput = url
                                        browse()
                                    }) {
                                        Text(url.replacingOccurrences(of: "wss://", with: ""))
                                            .font(.appSystem(size: 12, weight: .medium))
                                            .foregroundColor(.havenPurple)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.havenPurple.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.bottom, 8)

                Divider()

                // Group list
                if groupService.availableGroups.isEmpty {
                    browsePlaceholder
                } else {
                    List {
                        ForEach(groupService.availableGroups) { info in
                            GroupBrowserRow(
                                info: info,
                                isJoined: joinedGroupIds.contains(info.id),
                                onJoin: {
                                    Task {
                                        try? await groupService.joinGroup(info.identifier)
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.platformSecondaryGroupedBackground)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.platformWindowBackground.ignoresSafeArea())
            .navigationTitle(String(localized: "group.browser.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "group.browser.close")) { dismiss() }
                }
            }
        }
    }

    /// Shown whenever there are no rows — which covers four different situations,
    /// and used to render as one "enter a relay" prompt for all of them.
    @ViewBuilder
    private var browsePlaceholder: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                Spacer()
                switch groupService.browseState {
                case .idle:
                    placeholderBody(
                        icon: "antenna.radiowaves.left.and.right",
                        message: String(localized: "group.browser.enterRelay")
                    )
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                    Text(String(localized: "group.browser.loading"))
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                case .loaded:
                    placeholderBody(
                        icon: "tray",
                        message: String(localized: "group.browser.empty")
                    )
                case .failed(let message):
                    // Icon carries the error colour; the message stays at full
                    // contrast, since red 14pt body text on this surface does not
                    // clear 4.5:1.
                    VStack(spacing: 16) {
                        placeholderBody(
                            icon: "exclamationmark.triangle.fill",
                            message: message,
                            iconTint: .red,
                            messageTint: .primary
                        )
                    }
                    // Grouped here rather than on the whole placeholder: combining
                    // the Retry button into the same element would take away its
                    // button trait and its action.
                    .accessibilityElement(children: .combine)
                    Button(String(localized: "group.browser.retry"), action: browse)
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .disabled(relayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder
    private func placeholderBody(
        icon: String,
        message: String,
        iconTint: Color = .secondary.opacity(0.5),
        messageTint: Color = .secondary
    ) -> some View {
        Image(systemName: icon)
            .font(.appSystem(size: 40, weight: .light))
            .foregroundColor(iconTint)
        Text(message)
            .font(.appSystem(size: 14))
            .foregroundColor(messageTint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private func browse() {
        let url = relayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        groupService.availableGroups = []
        groupService.browseGroups(on: url)
    }
}

// MARK: - Group Browser Row

struct GroupBrowserRow: View {
    let info: GroupInfo
    let isJoined: Bool
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let url = info.pictureURL {
                AvatarView(url: url, pubkey: info.identifier.groupId)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.havenPurple.opacity(0.15))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .font(.appSystem(size: 18))
                            .foregroundColor(.havenPurple)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.name)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .lineLimit(1)

                    if info.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.orange)
                    }
                    if info.isClosed {
                        Image(systemName: "hand.raised.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.red)
                    }
                }

                if !info.about.isEmpty {
                    Text(info.about)
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isJoined {
                Text(String(localized: "group.browser.joined"))
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Button(action: onJoin) {
                    Text(String(localized: "group.browser.join"))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.havenPurple)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

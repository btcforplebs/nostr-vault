import SwiftUI

struct GroupBrowserView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var relayInput: String = ""
    @State private var isConnecting = false

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
                    GeometryReader { geometry in
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.appSystem(size: 40, weight: .light))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(String(localized: "group.browser.enterRelay"))
                                .font(.appSystem(size: 14))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
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

    private func browse() {
        let url = relayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        isConnecting = true
        groupService.availableGroups = []
        groupService.browseGroups(on: url)

        // Clear connecting state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            isConnecting = false
        }
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

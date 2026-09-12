import SwiftUI

struct GroupInfoView: View {
    let identifier: GroupIdentifier

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editAbout = ""
    @State private var editPicture = ""
    @State private var showingLeaveConfirm = false
    @State private var showingDeleteConfirm = false
    /// The member whose remove button was hit. Removal is published to the
    /// relay immediately, so it asks first — and names who.
    @State private var memberPendingRemoval: GroupMember? = nil
    @State private var actionError: String?

    /// Names for the confirmation copy — a confirmation that says "this member"
    /// is not one you can check before you act on it.
    private var groupName: String {
        conversation?.displayName ?? identifier.groupId
    }

    private func displayName(for member: GroupMember) -> String {
        nostrService.profiles[member.pubkey]?.bestName ?? String(member.pubkey.prefix(8)) + "..."
    }

    private var conversation: GroupConversation? {
        groupService.conversations.first(where: { $0.identifier == identifier })
    }

    private var isAdmin: Bool {
        groupService.isAdmin(in: identifier)
    }

    private var allMembers: [GroupMember] {
        var combined = conversation?.admins ?? []
        let adminPubkeys = Set(combined.map { $0.pubkey })
        for member in conversation?.members ?? [] {
            if !adminPubkeys.contains(member.pubkey) {
                combined.append(member)
            }
        }
        return combined
    }

    var body: some View {
        NavigationStack {
            List {
                // Header
                Section {
                    VStack(spacing: 12) {
                        if let url = conversation?.info?.pictureURL {
                            AvatarView(url: url, pubkey: identifier.groupId)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.havenPurple.opacity(0.15))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Image(systemName: "person.3.fill")
                                        .font(.appSystem(size: 30))
                                        .foregroundColor(.havenPurple)
                                )
                        }

                        Text(conversation?.displayName ?? identifier.groupId)
                            .font(.appSystem(size: 20, weight: .bold))

                        if let about = conversation?.info?.about, !about.isEmpty {
                            Text(about)
                                .font(.appSystem(size: 14))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: 8) {
                            Label(
                                identifier.relayURL
                                    .replacingOccurrences(of: "wss://", with: "")
                                    .replacingOccurrences(of: "ws://", with: ""),
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)

                            if conversation?.info?.isPrivate == true {
                                Label(String(localized: "group.info.private"), systemImage: "lock.fill")
                                    .font(.appSystem(size: 12))
                                    .foregroundColor(.orange)
                            }

                            if conversation?.info?.isClosed == true {
                                Label(String(localized: "group.info.closed"), systemImage: "hand.raised.fill")
                                    .font(.appSystem(size: 12))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                // Members
                if !allMembers.isEmpty {
                    Section(header: Text(String(localized: "group.info.members")) + Text(" (\(allMembers.count))")) {
                        ForEach(allMembers) { member in
                            HStack(spacing: 12) {
                                AvatarView(
                                    url: nostrService.profiles[member.pubkey]?.pictureURL,
                                    pubkey: member.pubkey
                                )
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(nostrService.profiles[member.pubkey]?.bestName ?? String(member.pubkey.prefix(8)) + "...")
                                        .font(.appSystem(size: 14, weight: .medium))
                                    if member.isAdmin {
                                        Text(String(localized: "group.info.admin"))
                                            .font(.appSystem(size: 11, weight: .semibold))
                                            .foregroundColor(.havenPurple)
                                    } else if member.isModerator {
                                        Text(String(localized: "group.info.moderator"))
                                            .font(.appSystem(size: 11, weight: .semibold))
                                            .foregroundColor(.orange)
                                    }
                                }

                                Spacer()

                                if isAdmin && member.pubkey != NostrService.shared.activeHexPubkey {
                                    Button(action: {
                                        memberPendingRemoval = member
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // Admin Actions
                if isAdmin {
                    Section(header: Text(String(localized: "group.info.adminActions"))) {
                        Button(action: {
                            editName = conversation?.info?.name ?? ""
                            editAbout = conversation?.info?.about ?? ""
                            editPicture = conversation?.info?.picture ?? ""
                            isEditing = true
                        }) {
                            Label(String(localized: "group.info.editGroup"), systemImage: "pencil")
                        }

                        Button(action: {
                            Task {
                                try? await groupService.createInvite(forGroup: identifier)
                            }
                        }) {
                            Label(String(localized: "group.info.createInvite"), systemImage: "person.badge.plus")
                        }

                        Button(role: .destructive, action: { showingDeleteConfirm = true }) {
                            Label(String(localized: "group.info.deleteGroup"), systemImage: "trash")
                        }
                    }
                }

                // Leave
                Section {
                    Button(role: .destructive, action: { showingLeaveConfirm = true }) {
                        Label(String(localized: "group.info.leaveGroup"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(String(localized: "group.info.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "group.info.done")) { dismiss() }
                        .foregroundColor(.havenPurple)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "group.info.done")) { dismiss() }
                        .foregroundColor(.havenPurple)
                }
            }
            #endif
            .confirmDestructive(
                "Remove Member",
                item: $memberPendingRemoval,
                consequence: { member in
                    "This removes \(displayName(for: member)) from \(groupName). They lose access to the group until an admin adds them back."
                },
                confirmTitle: "Remove",
                action: { member in
                    Task {
                        try? await groupService.removeUser(member.pubkey, fromGroup: identifier)
                    }
                }
            )
            .confirmDestructive(
                "Leave Group",
                isPresented: $showingLeaveConfirm,
                consequence: "This leaves \(groupName). Its messages are removed from this device, and a closed group needs a new invite to rejoin.",
                confirmTitle: "Leave",
                action: {
                    Task {
                        try? await groupService.leaveGroup(identifier)
                        dismiss()
                    }
                }
            )
            .confirmDestructive(
                "Delete Group",
                isPresented: $showingDeleteConfirm,
                consequence: "This asks the relay to delete \(groupName) for everyone, not just you. It cannot be undone.",
                confirmTitle: "Delete Group",
                action: {
                    Task {
                        try? await groupService.deleteGroup(identifier)
                        dismiss()
                    }
                }
            )
            .sheet(isPresented: $isEditing) {
                GroupEditView(
                    identifier: identifier,
                    name: $editName,
                    about: $editAbout,
                    picture: $editPicture
                )
                .environmentObject(configService)
                #if os(macOS)
                .frame(minWidth: 350, minHeight: 300)
                #endif
            }
        }
    }
}

// MARK: - Group Edit View

struct GroupEditView: View {
    let identifier: GroupIdentifier
    @Binding var name: String
    @Binding var about: String
    @Binding var picture: String

    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(String(localized: "group.edit.details"))) {
                    TextField(String(localized: "group.edit.name"), text: $name)
                    TextField(String(localized: "group.edit.about"), text: $about, axis: .vertical)
                        .lineLimit(3...6)
                    TextField(String(localized: "group.edit.pictureURL"), text: $picture)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            .navigationTitle(String(localized: "group.edit.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "group.edit.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "group.edit.save")) { save() }
                        .disabled(name.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            try? await groupService.editGroupMetadata(
                identifier,
                name: name,
                about: about,
                picture: picture.isEmpty ? nil : picture
            )
            await MainActor.run { dismiss() }
        }
    }
}

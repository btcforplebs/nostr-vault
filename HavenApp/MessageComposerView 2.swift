import SwiftUI
import PhotosUI

struct MessageComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    let recipientPubkey: String?

    @State private var selectedRecipient: String?
    @State private var messageText = ""
    @State private var selectedImage: UIImage?
    @State private var selectedImageData: Data?
    @State private var isSending = false
    @State private var searchText = ""
    @State private var showPhotoPicker = false

    private var searchResults: [String] {
        if searchText.isEmpty {
            return []
        }
        return nostrService.profiles.keys.filter { pubkey in
            let profile = nostrService.profiles[pubkey]
            let name = profile?.bestName ?? ""
            return name.lowercased().contains(searchText.lowercased()) ||
                   pubkey.lowercased().contains(searchText.lowercased())
        }.prefix(10).map(String.init)
    }

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedRecipient != nil || recipientPubkey != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Recipient Selection
                if recipientPubkey == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            TextField("Search users...", text: $searchText)
                                .textFieldStyle(.plain)
                                .padding(12)

                            if !searchText.isEmpty && !searchResults.isEmpty {
                                Divider()
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(searchResults, id: \.self) { pubkey in
                                            Button(action: {
                                                selectedRecipient = pubkey
                                                searchText = ""
                                            }) {
                                                HStack(spacing: 12) {
                                                    AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey)
                                                        .frame(width: 32, height: 32)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(nostrService.profiles[pubkey]?.bestName ?? String(pubkey.prefix(8)))
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .foregroundColor(.primary)
                                                        Text(String(pubkey.prefix(12)) + "…")
                                                            .font(.system(size: 11, design: .monospaced))
                                                            .foregroundColor(.secondary)
                                                    }

                                                    Spacer()
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                            }
                                            .buttonStyle(.plain)

                                            if pubkey != searchResults.last {
                                                Divider()
                                                    .padding(.leading, 44)
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: 200)
                            }
                        }
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(8)
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 16)
                } else if let recipient = selectedRecipient ?? recipientPubkey,
                          let profile = nostrService.profiles[recipient] {
                    HStack(spacing: 12) {
                        AvatarView(url: profile.pictureURL, pubkey: recipient)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.bestName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        Button(action: {
                            if recipientPubkey == nil {
                                selectedRecipient = nil
                                searchText = ""
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Color.platformTertiaryGroupedBackground)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Divider()

                // Message Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Message input
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $messageText)
                                .textEditorStyle(.plain)
                                .font(.system(size: 14))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 100)

                            if messageText.isEmpty {
                                Text("Your message...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .padding(8)
                            }
                        }
                        .padding(12)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(8)

                        // Image preview
                        if let image = selectedImage {
                            VStack(alignment: .trailing, spacing: 8) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxHeight: 200)
                                    .cornerRadius(6)

                                Button(action: {
                                    selectedImage = nil
                                    selectedImageData = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(16)
                }

                // Actions
                HStack(spacing: 12) {
                    #if os(iOS)
                    PhotosPicker(selection: .constant(nil), matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                            .padding(12)
                            .background(Color.havenPurple.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .onChange(of: showPhotoPicker) { _, show in
                        if show {
                            showPhotoPicker = false
                        }
                    }
                    #endif

                    Spacer()

                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(canSend ? Color.havenPurple : Color.havenPurple.opacity(0.4))
                                .cornerRadius(8)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || isSending)
                }
                .padding(16)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.havenPurple)
                }
            }
        }
    }

    private func sendMessage() {
        let recipient = selectedRecipient ?? recipientPubkey
        guard let recipient = recipient else { return }

        isSending = true
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await dmService.sendDM(content: content, to: recipient)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("Failed to send message: \(error)")
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
}

#Preview {
    MessageComposerView(recipientPubkey: nil)
        .environmentObject(NostrService.shared)
        .environmentObject(ConfigService.shared)
}

import SwiftUI
import PhotosUI

#if os(iOS)
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
    @State private var sendError: String?
    @State private var searchText = ""
    @State private var showPhotoPicker = false

    private var searchResults: [String] {
        if searchText.count < 2 {
            return []
        }
        let searchLower = searchText.lowercased()

        // Decode npub to hex pubkey for direct lookup
        if searchLower.hasPrefix("npub1"),
           let decoded = Bech32.decode(searchText),
           decoded.hrp == "npub" {
            return [decoded.hexString]
        }

        return Array(nostrService.profiles.keys.filter { pubkey in
            let profile = nostrService.profiles[pubkey]
            let name = profile?.bestName ?? ""
            return name.lowercased().contains(searchLower) ||
                   pubkey.lowercased().contains(searchLower)
        }.prefix(10))
    }

    var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedRecipient != nil || recipientPubkey != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Recipient Selection
                if let recipient = selectedRecipient ?? recipientPubkey {
                    let profile = nostrService.profiles[recipient]
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: recipient, size: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile?.bestName ?? String(Array(recipient.prefix(8))))
                                .font(.appSystem(size: 13, weight: .semibold))
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
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To:")
                            .font(.appSystem(size: 12, weight: .semibold))
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
                                                    AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(nostrService.profiles[pubkey]?.bestName ?? String(Array(pubkey.prefix(8))))
                                                            .font(.appSystem(size: 13, weight: .semibold))
                                                            .foregroundColor(.primary)
                                                        Text(String(Array(pubkey.prefix(12))) + "…")
                                                            .font(.appSystem(size: 11, design: .monospaced))
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
                }

                Divider()

                // Message Content
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $messageText)
                                    .textEditorStyle(.plain)
                                    .font(.appSystem(size: 15))
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 120)

                                if messageText.isEmpty {
                                    Text("Write a message...")
                                        .font(.appSystem(size: 15))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                            .padding(12)

                            // Image preview
                            if let image = selectedImage {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                    Button(action: {
                                        selectedImage = nil
                                        selectedImageData = nil
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.appSystem(size: 22))
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                    }
                                    .padding(8)
                                }
                                .padding(.horizontal, 12)
                                .id("imagePreview")
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }
                    .onChange(of: selectedImage) { oldValue, newValue in
                        // Scroll to show image when one is added
                        if oldValue == nil && newValue != nil {
                            withAnimation {
                                proxy.scrollTo("imagePreview", anchor: .bottom)
                            }
                        }
                    }
                }

                // Actions
                Divider()
                    .opacity(0.5)

                HStack(spacing: 12) {
                    Spacer()

                    if isSending {
                        ProgressView()
                            .frame(height: 36)
                    } else {
                        Button(action: sendMessage) {
                            HStack(spacing: 6) {
                                Text("Send")
                                    .font(.appSystem(size: 14, weight: .semibold))
                                Image(systemName: "paperplane.fill")
                                    .font(.appSystem(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(canSend ? Color.havenPurple : Color.havenPurple.opacity(0.3))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.platformWindowBackground.ignoresSafeArea())
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
            .alert("Failed to Send", isPresented: Binding<Bool>(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )) {
                Button("OK") { sendError = nil }
            } message: {
                if let sendError = sendError {
                    Text(sendError)
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
                #if DEBUG
                print("Failed to send message: \(error)")
                #endif
                await MainActor.run {
                    isSending = false
                    sendError = error.localizedDescription
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
#endif

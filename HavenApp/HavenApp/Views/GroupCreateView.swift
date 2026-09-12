import SwiftUI

struct GroupCreateView: View {
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var about: String = ""
    @State private var selectedRelay: String = ""
    @State private var isPrivate: Bool = false
    @State private var isClosed: Bool = false
    @State private var isCreating: Bool = false
    @State private var createError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(String(localized: "group.create.details"))) {
                    TextField(String(localized: "group.create.name"), text: $name)
                    TextField(String(localized: "group.create.about"), text: $about, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section(header: Text(String(localized: "group.create.relay"))) {
                    if configService.config.groupRelayURLs.isEmpty {
                        Text(String(localized: "group.create.noRelays"))
                            .font(.appSystem(size: 14))
                            .foregroundColor(.secondary)
                    } else {
                        Picker(String(localized: "group.create.relayPicker"), selection: $selectedRelay) {
                            Text(String(localized: "group.create.selectRelay")).tag("")
                            ForEach(configService.config.groupRelayURLs, id: \.self) { url in
                                Text(url.replacingOccurrences(of: "wss://", with: "")).tag(url)
                            }
                        }
                    }
                }

                Section(header: Text(String(localized: "group.create.privacy"))) {
                    Toggle(String(localized: "group.create.private"), isOn: $isPrivate)
                    Toggle(String(localized: "group.create.closed"), isOn: $isClosed)
                }
            }
            .navigationTitle(String(localized: "group.create.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "group.create.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "group.create.create")) { createGroup() }
                        .disabled(name.isEmpty || selectedRelay.isEmpty || isCreating)
                }
            }
            .alert(String(localized: "group.create.failed"), isPresented: Binding<Bool>(
                get: { createError != nil },
                set: { if !$0 { createError = nil } }
            )) {
                Button(String(localized: "group.create.ok")) { createError = nil }
            } message: {
                if let createError = createError {
                    Text(createError)
                }
            }
        }
    }

    private func createGroup() {
        isCreating = true
        Task {
            do {
                try await groupService.createGroup(
                    on: selectedRelay,
                    name: name,
                    about: about,
                    isPrivate: isPrivate,
                    isClosed: isClosed
                )
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    isCreating = false
                    createError = error.localizedDescription
                }
            }
        }
    }
}

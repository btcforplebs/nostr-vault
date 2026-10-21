import SwiftUI

#if os(iOS)
/// FIPS Mesh → Advanced: the plumbing. Finder relays carry the offers your
/// devices use to find each other; the middle server links this phone to a
/// browser page that can't reach it directly.
struct FipsMeshAdvancedView: View {
    @State private var relays = FipsMeshSettings.finderRelays
    @State private var middle = FipsMeshSettings.middleServer
    @State private var newRelay = ""

    var body: some View {
        List {
            Section {
                ForEach(relays, id: \.self) { relay in
                    Text(relay).font(.appSystem(size: 13, design: .monospaced))
                }
                .onDelete { offsets in
                    // At least one: the engine's own defaults carry no offers here.
                    guard relays.count - offsets.count >= 1 else { return }
                    relays.remove(atOffsets: offsets)
                    FipsMeshSettings.finderRelays = relays
                }
                HStack {
                    TextField("wss://…", text: $newRelay)
                        .font(.appSystem(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit(addRelay)
                    Button("Add", action: addRelay)
                        .disabled(MeshDevicesLogic.normalizedFinderRelay(newRelay) == nil)
                }
            } header: {
                Text("Finder Relays")
            } footer: {
                Text("Your devices post where they are here, so the others can find them. They see this phone's IP address the way any relay does. Swipe to remove; one must stay.")
            }

            Section {
                Picker("Middle server", selection: Binding(
                    get: { middle },
                    set: { value in
                        middle = value
                        FipsMeshSettings.middleServer = value
                    }
                )) {
                    ForEach(MeshMiddleServer.allCases) { server in
                        Text(server.label).tag(server)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Middle Server")
            } footer: {
                Text("Links this phone to a browser page that can't reach it directly, and sees this phone's IP address. With None, a browser page only connects on the same network.")
            }

            Section {
                Button("Reset to defaults") {
                    FipsMeshSettings.resetAdvanced()
                    relays = FipsMeshSettings.finderRelays
                    middle = FipsMeshSettings.middleServer
                }
            } footer: {
                Text("Changes apply the next time the mesh starts.")
            }
        }
        .listStyle(.insetGrouped)
        .tint(Color.havenPurple)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRelay() {
        guard let relay = MeshDevicesLogic.normalizedFinderRelay(newRelay) else { return }
        if !relays.contains(relay) {
            relays.append(relay)
            FipsMeshSettings.finderRelays = relays
        }
        newRelay = ""
    }
}
#endif

import SwiftUI

/// Edit the iPad rail: drag the sections and favourites into any order,
/// remove favourites (the sections stay), and add a list, person, hashtag or
/// relay. Saved for the account and synced with the web (`SpaceLayoutStore`).
struct RailEditSheet: View {
    @ObservedObject private var store = SpaceLayoutStore.shared
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    private var pins: [SpaceLayout.Pin] { store.layout.shownPins(sections: SpaceLayoutStore.railSections) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pins) { pin in
                        HStack(spacing: 12) {
                            icon(pin).frame(width: 28)
                            Text(title(pin))
                            Spacer()
                            if pin.isSection {
                                Text("Section").font(.appCaption).foregroundColor(.secondary)
                            }
                        }
                        .deleteDisabled(pin.isSection)
                    }
                    .onMove { store.movePins(from: $0, to: $1) }
                    .onDelete { offsets in
                        for i in offsets where pins.indices.contains(i) { store.removePin(pins[i].id) }
                    }
                } footer: {
                    Text("Drag to reorder. Sections can move but not go. Your rail is kept on your account, so the web vault shows it too.")
                }
                Section {
                    Button { adding = true } label: {
                        Label("Add a list, person, hashtag or relay", systemImage: "plus")
                    }
                    .disabled(store.layout.favouriteCount >= SpaceLayout.maxFavourites)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit rail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) { AddPinSheet() }
        }
    }

    @ViewBuilder
    private func icon(_ pin: SpaceLayout.Pin) -> some View {
        switch pin.kind {
        case .section(let id):
            Image(systemName: RailSection.symbol(id)).foregroundColor(.havenPurple)
        case .person(let p):
            AvatarView(url: nostrService.profiles[p]?.pictureURL, pubkey: p, size: 26)
        default:
            Image(systemName: RailPin.symbol(pin.kind)).foregroundColor(.havenPurple)
        }
    }

    private func title(_ pin: SpaceLayout.Pin) -> String {
        if case .section(let id) = pin.kind { return RailSection.title(id) }
        return RailPin.label(pin, profiles: nostrService.profiles)
    }
}

/// The rail's sections: their names and icons.
enum RailSection {
    static func title(_ id: String) -> String {
        switch id {
        case "feed": return "Feed"
        case "search": return "Search"
        case "profile": return "Profile"
        case "wot": return "WoT"
        case "vault": return "Vault"
        default: return id.capitalized
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "feed": return "person.2.wave.2"
        case "search": return "magnifyingglass"
        case "profile": return "person.crop.circle"
        case "wot": return TrustMap.Layer.everyone.symbolName
        case "vault": return VaultDashboard.symbol
        default: return "square"
        }
    }
}

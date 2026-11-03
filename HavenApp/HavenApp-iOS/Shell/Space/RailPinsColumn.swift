import SwiftUI

/// The iPad rail's contents, top to bottom: `top` (the account picture), the
/// sections and favourites in the account's order, and Edit. A favourite
/// opens its feed in a sheet, or the person's profile.
struct RailPinsColumn<Top: View>: View {
    @ObservedObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var store = SpaceLayoutStore.shared
    /// A section's rail item, built by `BottomTabBar` (it owns the tabs).
    let section: (String) -> AnyView
    @ViewBuilder var top: () -> Top

    @State private var editing = false
    @State private var openPin: SpaceLayout.Pin?

    var body: some View {
        VStack(spacing: 0) {
            top()
                .padding(.bottom, 20)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 22) {
                    ForEach(store.layout.shownPins(sections: SpaceLayoutStore.railSections)) { pin in
                        if case .section(let id) = pin.kind {
                            section(id)
                        } else {
                            RailPinItem(pin: pin, nostrService: nostrService) { open(pin) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button { editing = true } label: {
                Image(systemName: "pencil")
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .accessibilityLabel("Edit rail")
            .accessibilityHint("Reorder sections and pin lists, people, hashtags or relays")
        }
        .sheet(isPresented: $editing) {
            RailEditSheet()
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $openPin) { pin in
            Group {
                if case .hashtag(let tag) = pin.kind {
                    HashtagFeedView(tag: tag)
                } else if let feed = PinFeedView(pin: pin) {
                    feed
                }
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    private func open(_ pin: SpaceLayout.Pin) {
        if case .person(let p) = pin.kind {
            NotificationCenter.default.post(name: .havenOpenProfile, object: p)
        } else {
            openPin = pin
        }
    }
}

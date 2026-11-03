import SwiftUI

/// How a favourite pin looks on the iPad rail, and what a tap opens.
enum RailPin {
    static func symbol(_ kind: SpaceLayout.Pin.Kind) -> String {
        switch kind {
        case .list: return "person.3"
        case .person: return "person.crop.circle"
        case .hashtag: return "number"
        case .relay: return "antenna.radiowaves.left.and.right"
        case .section, .unknown: return "square"
        }
    }

    static func fallbackLabel(_ kind: SpaceLayout.Pin.Kind) -> String {
        switch kind {
        case .list(let a): return String(a.split(separator: ":").last ?? "List")
        case .person(let p): return String(p.prefix(8))
        case .hashtag(let t): return "#\(t)"
        case .relay(let url): return URL(string: url)?.host ?? url
        case .section(let id): return id
        case .unknown: return ""
        }
    }

    @MainActor
    static func label(_ pin: SpaceLayout.Pin, profiles: [String: FeedProfile]) -> String {
        switch pin.kind {
        case .person(let p): return profiles[p]?.bestName ?? pin.name ?? fallbackLabel(pin.kind)
        case .hashtag, .relay: return fallbackLabel(pin.kind)
        default: return pin.name ?? fallbackLabel(pin.kind)
        }
    }
}

/// A favourite on the rail: its icon (a person's picture) and a one-line label.
struct RailPinItem: View {
    let pin: SpaceLayout.Pin
    @ObservedObject var nostrService: NostrService
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Group {
                    if case .person(let p) = pin.kind {
                        AvatarView(url: nostrService.profiles[p]?.pictureURL, pubkey: p, size: 24)
                    } else {
                        Image(systemName: RailPin.symbol(pin.kind))
                            .font(.appSystem(size: 18, weight: .regular))
                    }
                }
                .frame(height: 24)
                Text(RailPin.label(pin, profiles: nostrService.profiles))
                    .font(.appSystem(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RailPin.label(pin, profiles: nostrService.profiles))
        .onAppear {
            if case .person(let p) = pin.kind, nostrService.profiles[p] == nil { nostrService.fetchMissingProfiles(for: [p]) }
        }
    }
}

import SwiftUI

extension TrustWebView {
    // MARK: - Globe

    /// Clipped to its box everywhere but the WOT tab, where it runs to the
    /// screen's edges.
    /// The WoT tutorial's first card points at the middle of the globe, you
    /// and the faces nearest you. The whole globe is nearly the screen's
    /// height, which leaves the card no room above or below it.
    var globeTutorialAnchor: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.5
            Color.clear
                .frame(width: side, height: side)
                .tutorialAnchor(TutorialContent.wotGlobe)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder var globeArea: some View {
        if isWOTTab { globeLayers } else { globeLayers.clipped() }
    }

    private var globeLayers: some View {
        ZStack(alignment: .bottomLeading) {
            TrustGlobeCanvas(frame: frame, center: centerKey, me: me, author: author,
                             myFollows: myFollows, haze: haze, closeHaze: closeHaze, ringFaces: ringFaces,
                             layerFaces: layerFaces,
                             filterLit: filterLit,
                             running: profilePubkey == nil,
                             layer: isWOTTab && centerKey == me ? layer : .everyone,
                             summary: summary,
                             avatar: avatar, name: name, onTap: tapped,
                             focus: card,
                             focusBridges: cardPath?.all ?? [],
                             onEmptyTap: { closeCard(); searchFocused = false },
                             liveArcs: isWOTTab)
                .ignoresSafeArea(edges: isWOTTab ? .all : [])
            // Moving onto someone keeps the globe up: the trail's chip spins
            // instead. Only the very first globe has nothing to show.
            if frame == nil, centerKey == me {
                statusPill("Loading \(name(centerKey))'s follows…", face: centerKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadingMyFollows {
                statusPill("Loading your follows…", face: me)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mappingWeb, card == nil, !isWOTTab {
                statusPill("Mapping your wider web…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 14)
            }
            if let card {
                if cardIsSidePanel {
                    // iPad, wide: the card docks down the trailing side, where
                    // it does not sit on the globe it is explaining.
                    trustCard(card)
                        .frame(width: AdaptiveLayout.sidePanelWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    trustCard(card).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if !isWOTTab, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                GeometryReader { geo in
                    // With the keyboard up the floating tab bar rides on it,
                    // over the bottom of the globe.
                    searchResults(maxHeight: max(120, min(380, geo.size.height - (searchFocused ? tabBarHeight : 0) - 20)))
                }
            }
        }
        .overlay(alignment: .top) { if !isWOTTab { refreshBar } }
    }

    /// Your own globe, before your follow list has come in.
    private var loadingMyFollows: Bool {
        guard centerKey == me, let frame, frame.ring.isEmpty else { return false }
        return contactsLoading || refreshStep == 1
    }

    /// Your follows are in but the wider web around them isn't yet.
    var mappingWeb: Bool {
        guard isWOTTab, centerKey == me, haze.isEmpty, let frame, !frame.ring.isEmpty else { return false }
        return !webWaitedOut || refreshStep == 2
    }

    /// A loading state you can't miss: a spinner, what is loading, and whose.
    private func statusPill(_ text: String, face: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let face {
                AvatarView(url: nostrService.profiles[face]?.pictureURL, pubkey: face, size: 28)
            }
            ProgressView().controlSize(.small).tint(.white)
            Text(text)
                .font(.appSystem(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.leading, face == nil ? 14 : 6)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

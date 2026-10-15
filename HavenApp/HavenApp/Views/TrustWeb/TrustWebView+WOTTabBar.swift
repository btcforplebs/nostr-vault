import SwiftUI

extension TrustWebView {
    // MARK: - WOT tab bar

    @ToolbarContentBuilder var toolbarItems: some ToolbarContent {
        #if os(iOS)
        if isWOTTab {
            ToolbarItem(placement: .navigationBarLeading) {
                ChromeMorphCapsule(alignment: .leading, isEnabled: false) {
                    layerMenu.tutorialAnchor(TutorialContent.wotLayers)
                }
            }
            .hidingSharedToolbarBackground()
            ToolbarItem(placement: .navigationBarTrailing) {
                ChromeMorphCapsule(alignment: .trailing, isEnabled: false) {
                    // Narrower buttons before the bar would fold the whole
                    // pill into "•••" (an iPhone 17 Pro did, at 36 pt).
                    ViewThatFits(in: .horizontal) {
                        trailingPill(buttonWidth: 36, spacing: 4)
                        trailingPill(buttonWidth: 30, spacing: 0)
                        trailingPill(buttonWidth: 26, spacing: 0)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                }
            }
            .hidingSharedToolbarBackground()
        }
        #else
        if isWOTTab {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(refreshStep != nil)
                    .accessibilityLabel(Text("Update your Web of Trust"))
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) { ForEach(TrustMap.Filter.allCases, id: \.self) { filterButton($0) } }
            }
            ToolbarItem(placement: .primaryAction) { liveArcsButton }
        }
        #endif
    }

    #if os(iOS)
    /// Search, the filters, then the antenna.
    private func trailingPill(buttonWidth: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            IconFilterButton(icon: "magnifyingglass", tooltip: "Find someone",
                             isSelected: searchOpen, color: .havenPurple) { toggleSearch() }
                .tutorialAnchor(TutorialContent.wotSearch)
            Divider().frame(height: 20).padding(.horizontal, spacing == 0 ? 2 : 4)
            ForEach(TrustMap.Filter.allCases, id: \.self) { filterButton($0) }
            Divider().frame(height: 20).padding(.horizontal, spacing == 0 ? 2 : 4)
            liveArcsButton
        }
        .environment(\.filterButtonWidth, buttonWidth)
    }
    #endif

    var layerCounts: [TrustMap.Layer: Int] {
        TrustMap.layerCounts(me: me, follows: myFollows, web: web, vouches: vouches)
    }

    /// The feed picker's shape: the layer's icon, its name and a chevron, with
    /// the rare Rebuild at the bottom after a divider.
    private var layerMenu: some View {
        let counts = layerCounts
        return Menu {
            Picker(selection: $layer) {
                ForEach(TrustMap.layers(hasVouches: vouches != nil), id: \.self) { item in
                    // Compact counts (15K) keep each row on one line; a menu
                    // row drops a second Text, so there's no subtitle.
                    let count = (counts[item] ?? 0).formatted(.number.notation(.compactName))
                    Label("\(item.title) · \(count)", systemImage: item.symbolName)
                        .tag(item)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Button { refresh() } label: {
                Label(refreshStep == nil ? "Rebuild your web" : "Rebuilding…", systemImage: "arrow.clockwise")
            }
            .disabled(refreshStep != nil)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: layer.symbolName)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                HStack(spacing: 3) {
                    Text(layer.title)
                        .font(.appSystem(size: 17, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.leading, 8)
                .padding(.trailing, 12)
            }
            .padding(.leading, 7)
            .padding(.vertical, 7)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Showing: \(layer.title)")
        .accessibilityValue("\((counts[layer] ?? 0).formatted()) people")
        .accessibilityHint("Pick which part of your web to light up, or rebuild it")
    }

    private func toggleSearch() {
        if searchOpen {
            clearSearch()
            withAnimation(Motion.fade) { searchOpen = false }
        } else {
            closeCard()
            withAnimation(Motion.fade) { searchOpen = true }
            searchFocused = true
        }
    }

    /// Under the bar: the search when it's open, the way back once you've
    /// moved off yourself, and the live pill.
    func wotTopRows(height: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if searchOpen {
                searchField.padding(.horizontal)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults(maxHeight: max(120, min(380, height - 90 - (searchFocused ? tabBarHeight : 0))))
                        .padding(.top, -6)
                }
            }
            if crumbs.count > 1 { crumbRow }
            livePill
        }
        .padding(.top, 8)
        .filterNoteHost(filterNote)
        .transition(.opacity)
    }

    /// The feed's purple "New Posts" pill, for a rebuild: its steps while it
    /// runs and how it ended. Nothing when no rebuild is running.
    @ViewBuilder private var livePill: some View {
        if refreshStep != nil || mappingWeb || liveRebuild {
            HStack(spacing: 8) {
                if refreshStep != nil, refreshValue >= 3 {
                    // How the Rebuild button's run ended.
                    Image(systemName: refreshFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.appSystem(size: 13, weight: .bold))
                    Text(refreshCaption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else if refreshStep != nil {
                    // The Rebuild button's steps.
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(refreshCaption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Mapping your web")
                }
            }
            .font(.appSystem(size: 13, weight: .bold))
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: 340)
            .background(
                Capsule()
                    .fill(Color.havenPurple)
                    .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            )
            .foregroundColor(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(refreshStep != nil ? refreshCaption : "Your web is updating")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Follows the relay's rebuilds while the WOT tab is open, whoever started
    /// them (the daily timer, the boot check or the dropdown): newcomers fade
    /// in as stars, and the saved web loads when the rebuild ends.
    func followRebuilds() async {
        var cursor = 0
        while !Task.isCancelled {
            let progress = await Task.detached { WotRefresh.progress() }.value
            if let progress, progress.running {
                if !liveRebuild {
                    liveRebuild = true
                    cursor = 0
                    arrivals = []
                }
                let from = cursor
                if let batch = await Task.detached(operation: { WotRefresh.newcomers(from: from) }).value {
                    cursor = batch.total
                    if !batch.pubkeys.isEmpty {
                        arrivals.formUnion(batch.pubkeys)
                        recomputeHaze()
                    }
                }
            } else if liveRebuild {
                liveRebuild = false
                cursor = 0
                // Saved: the new map has everyone that lit up. Stopped: the
                // old one stays, and the stars that came in fade back out.
                arrivals = []
                FeedService.shared.loadWotPubkeys()
                recomputeHaze()
            }
            // Every few seconds, rebuilding or not: newcomers arrive in
            // batches, and each check that finds some wakes the globe.
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

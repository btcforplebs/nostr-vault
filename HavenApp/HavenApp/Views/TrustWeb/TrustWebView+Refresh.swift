import SwiftUI

extension TrustWebView {
    // MARK: - Refresh

    @ViewBuilder var refreshBar: some View {
        if refreshStep != nil {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: min(refreshValue, 3), total: 3)
                    .tint(.havenPurple)
                    .animation(.easeOut(duration: 0.3), value: refreshValue)
                Text(refreshCaption)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    /// The refresh button: your follow list again, a rebuild of your web
    /// by the relay (the same one it runs daily), then the faces' pictures.
    func refresh() {
        guard refreshStep == nil else { return }
        withAnimation {
            refreshStep = 0
            refreshValue = 0.05
            refreshCaption = "Updating your follows…"
            refreshFailed = false
        }
        Task {
            await FeedService.shared.refreshContactList()
            refreshStep = 1
            refreshValue = 1
            refreshCaption = "Rebuilding your web…"
            let saved = await rebuildWeb()
            let outcome = refreshCaption
            await FeedService.shared.loadWotPubkeysInBackground()
            recomputeHaze()
            refreshStep = 2
            refreshValue = 2
            refreshCaption = "Loading profile pictures…"
            await loadEngagement(force: true)
            try? await Task.sleep(for: .milliseconds(900))
            refreshValue = 3
            refreshFailed = !saved
            refreshCaption = saved ? "Up to date" : outcome
            try? await Task.sleep(for: .milliseconds(saved ? 700 : 3500))
            withAnimation { refreshStep = nil }
        }
    }

    /// Asks the relay to rebuild the graph now and follows its progress until
    /// it is saved. A relay that isn't running leaves the graph as it is.
    /// - Returns: whether the relay saved a new web.
    private func rebuildWeb() async -> Bool {
        let started = await Task.detached { RefreshWotC() == 1 }.value
        guard started else {
            refreshCaption = "Relay isn't running. Showing your last saved web."
            try? await Task.sleep(for: .seconds(1.5))
            return false
        }
        // The relay gives up on a slow fetch itself; this only stops a
        // hung poll from holding the bar forever.
        let start = Date()
        var phase = "", phaseStart = start
        for _ in 0..<720 {
            try? await Task.sleep(for: .milliseconds(500))
            let progress = await Task.detached { WotRefresh.progress() }.value
            guard let progress else { continue }
            // A new phase or a finished batch restarts the creep.
            let step = "\(progress.phase)-\(progress.batchesDone)"
            if step != phase { phase = step; phaseStart = Date() }
            refreshValue = 1 + progress.fraction(phaseSeconds: Date().timeIntervalSince(phaseStart))
            refreshCaption = progress.running
                ? "\(progress.caption) · \(Int(Date().timeIntervalSince(start)))s"
                : progress.caption
            if !progress.running { return progress.phase == "saved" }
        }
        refreshCaption = "The rebuild is taking too long. Showing your last saved web."
        return false
    }
}

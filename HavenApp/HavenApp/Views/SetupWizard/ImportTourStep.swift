import SwiftUI

// MARK: - Import tour

/// First run's setup job (ImportJobs) starts as soon as this shows: the
/// vault runs and serves, and setup brings in their own notes, follows and
/// current lists, in seconds. Over it, the import tour's lesson cards at the
/// reader's own pace, then a Ready card with real counts. Setup done or
/// partial: "Jump in" shows under any card. The long items (replies, older
/// relays, wider network, list history) are the Vault tab's "Still to bring
/// in", run only when tapped (Logen 2026-11-05).
struct ImportTourStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var jobs = ImportJobsService.shared
    let isReadOnly: Bool
    /// Their own servers picked in the relay check, read for this import
    /// only (not saved).
    var alsoFrom: [String] = []
    /// `keptRunning`: they left with the import still going.
    let onEnter: (_ keptRunning: Bool) -> Void

    @State private var index = 0
    @State private var counts: (notes: Int, likes: Int, all: Int)?
    /// Not every relay answered the count, so there are no numbers to show.
    @State private var countFailed = false
    @State private var started = false

    /// Same as the config default. 2021 was tried: the import walks the
    /// history in 10-day windows, each waiting on every relay, and a fresh
    /// key spent ~10 s per empty window on the simulator (2026-10-07), so
    /// two more years cost minutes for everyone. Older notes can be pulled
    /// from Settings → Import.
    static let importStartDate = "2023-01-01"

    private var lessons: [TutorialStep] { TutorialContent.importTour }
    /// The small orange label over each lesson (mockup).
    static let kickers = ["WHY IMPORT", "HOW IT WORKS", "RELAYS", "OPTIONAL", "FEEDS"]
    private var lastIndex: Int { lessons.count }  // the Ready card
    /// Setup let them in: done, or partial (a slow or silent relay, whose
    /// range waits under "Older and slower relays").
    private var done: Bool {
        if case .finished = jobs.setupStage { return true }
        return false
    }
    private var partial: Bool { jobs.setupStage == .finished(partial: true) }
    /// Setup failed, was cancelled or never started: Try again.
    private var couldNotFinish: String? {
        if case .couldNotFinish(let reason) = jobs.setupStage { return ImportJobs.couldNotFinishText(reason: reason) }
        return nil
    }
    private var stageText: String {
        if let couldNotFinish { return couldNotFinish }
        if partial { return Self.partialLine }
        return done ? "Done. Your notes are in." : "Bringing in your notes…"
    }
    static let partialLine = "Your notes are in. Some relays were slow: the rest is in the Vault tab under Still to bring in."

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text("Bringing your notes home")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            progressHeader
            if couldNotFinish != nil {
                ImportCouldNotStartButton(action: tryAgain)
            }
            card
            if done && index < lastIndex {
                doneBar
            }
        }
        .onAppear(perform: startImportOnce)
        .onChange(of: done) { _, isDone in
            if isDone { loadCounts() }
        }
    }

    // MARK: Progress

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stageText)
                .font(.appSystem(size: 13, weight: .medium))
                .foregroundColor(couldNotFinish != nil ? .orange : done ? WizardColors.success : WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // setup reports no progress of its own, and takes seconds.
            if done || couldNotFinish != nil {
                ProgressView(value: 1)
                    .tint(couldNotFinish != nil ? .orange : WizardColors.success)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(WizardColors.accentPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Bringing in your notes"))
        .accessibilityValue(Text(stageText))
    }

    // MARK: Cards

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if index < lastIndex {
                let lesson = lessons[index]
                Text(Self.kickers[index])
                    .font(.appSystem(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(WizardColors.accentPrimary)
                Text(lesson.title)
                    .font(.appSystem(size: 20, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(lesson.body)
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ImportTourArt(lesson: index)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else {
                Text("READY")
                    .font(.appSystem(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(WizardColors.accentPrimary)
                readyCard
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { index -= 1 }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .opacity(index == 0 ? 0 : 1)
                    .disabled(index == 0)
                    .foregroundColor(WizardColors.textSecondary)
                Spacer()
                pips
                Spacer()
                if index < lastIndex {
                    Button { index += 1 } label: {
                        Text("Next")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(WizardColors.accentGradient)
                            .cornerRadius(12)
                    }
                } else {
                    Button { enter(keptRunning: false) } label: {
                        Text("Enter")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(WizardColors.accentGradient)
                            .cornerRadius(12)
                            .opacity(done ? 1 : 0.4)
                    }
                    .disabled(!done)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(WizardColors.bgCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WizardColors.borderSubtle, lineWidth: 1))
        .animation(WizardAnimations.fadeIn, value: index)
    }

    private var pips: some View {
        HStack(spacing: 6) {
            ForEach(0...lastIndex, id: \.self) { i in
                Circle()
                    .fill(i == index ? WizardColors.accentPrimary : WizardColors.borderSubtle)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Card \(index + 1) of \(lastIndex + 1)"))
    }

    @ViewBuilder
    private var readyCard: some View {
        Text(couldNotFinish != nil ? "Your notes aren't in yet" : done ? "Your notes are home" : "Almost there")
            .font(.appSystem(size: 20, weight: .semibold))
            .foregroundColor(WizardColors.textPrimary)
        if let couldNotFinish {
            Text(couldNotFinish)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if done {
            Text(partial ? Self.partialLine : "Your notes are saved on this device. Replies, older relays and more are in the Vault tab under Still to bring in.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let counts {
                HStack(spacing: 10) {
                    countTile(counts.notes, "notes")
                    countTile(counts.likes, "likes")
                    countTile(counts.all, "in all")
                }
            } else if countFailed {
                Text("Couldn't count them just now. The dashboard shows the totals.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
            }
            if isReadOnly {
                Text("Read-only for now. Add your private key in Settings to post.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
            }
        } else {
            Text("Still bringing in your notes. You can wait here or keep it running in the background.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Keep it running in the background") { enter(keptRunning: true) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .buttonStyle(.plain)
        }
    }

    private func countTile(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.appSystem(size: 18, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
            Text(label)
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(WizardColors.bgElevated)
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    private var doneBar: some View {
        HStack {
            Label(partial ? "Your notes are in. Some relays were slow." : "Done. Your notes are in.",
                  systemImage: partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(partial ? .orange : WizardColors.success)
            Spacer()
            Button("Jump in") { enter(keptRunning: false) }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(WizardColors.accentGradient)
                .cornerRadius(10)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background((partial ? Color.orange : WizardColors.success).opacity(0.12))
        .cornerRadius(12)
    }

    // MARK: Actions

    private func startImportOnce() {
        guard !started else { return }
        started = true
        if done { loadCounts(); return }
        configService.config.importStartDate = Self.importStartDate
        configService.save()
        relayManager.startFirstRun(config: configService.config, alsoFrom: alsoFrom)
    }

    private func tryAgain() {
        relayManager.startFirstRun(config: configService.config, alsoFrom: alsoFrom)
    }

    /// Seeing every lesson card finishes the tour (and covers Vault and
    /// Pocket relay); leaving before the last one counts as skipped.
    private func enter(keptRunning: Bool) {
        let account = Bech32.decode(npubForAccount)?.hexString ?? ""
        if index >= lastIndex {
            TutorialCenter.shared.finish(.importTour, account: account)
        } else {
            TutorialCenter.shared.skip(.importTour, account: account)
        }
        // Kept running: setup carries on in the relay (and resumes by
        // itself if the relay stops before it ends).
        relayManager.endFirstRun()
        onEnter(keptRunning)
    }

    private var npubForAccount: String { configService.config.ownerNpub }

    private func loadCounts() {
        Task {
            _ = await relayManager.ensureRelayReady(timeout: 30)
            guard let byKind = await StatsService.shared.fetchCountsByKind() else {
                countFailed = true
                return
            }
            counts = (byKind[1] ?? 0, byKind[7] ?? 0, byKind[-1] ?? 0)
        }
    }
}

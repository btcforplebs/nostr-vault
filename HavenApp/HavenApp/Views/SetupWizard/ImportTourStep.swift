import SwiftUI

// MARK: - Import tour

/// Import starts as soon as this shows. Over it, the import tour's lesson
/// cards at the reader's own pace, then a Ready card with real counts.
/// Import done first: "Jump in" shows under any card. Cards done first: the
/// app can open with the import still running (it lives in
/// `RelayProcessManager`, not this view).
struct ImportTourStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
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
    private var done: Bool { relayManager.importCompleted && !relayManager.isImporting }
    private var stage: ImportTourStage {
        ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: done)
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text("Bringing your notes home")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            progressHeader
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
            HStack {
                Text(stage.text)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(done ? WizardColors.success : WizardColors.textSecondary)
                Spacer()
                Text("\(stage.step) of \(ImportTourStage.stepCount)")
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
            ProgressView(value: done ? 1 : max(relayManager.importProgress, 0.02))
                .tint(done ? WizardColors.success : WizardColors.accentPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Import"))
        .accessibilityValue(Text(stage.text))
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
        Text(done ? "Your notes are home" : "Almost there")
            .font(.appSystem(size: 20, weight: .semibold))
            .foregroundColor(WizardColors.textPrimary)
        if done {
            Text("Everything we found is saved on this device.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
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
            Text("Still importing. That's normal for a long history, so you can wait here or keep it running in the background.")
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
            Label("Import done. Your notes are home.", systemImage: "checkmark.circle.fill")
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(WizardColors.success)
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
        .background(WizardColors.success.opacity(0.12))
        .cornerRadius(12)
    }

    // MARK: Actions

    private func startImportOnce() {
        guard !started else { return }
        started = true
        if done { loadCounts(); return }
        guard !relayManager.isImporting else { return }
        configService.config.importStartDate = Self.importStartDate
        configService.save()
        relayManager.importNotes(config: configService.config, alsoFrom: alsoFrom)
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

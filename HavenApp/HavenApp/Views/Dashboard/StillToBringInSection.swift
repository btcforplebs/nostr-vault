import SwiftUI

/// The Vault tab's "Still to bring in" (Logen 2026-11-05): the long import
/// items first run leaves out, each with what it is, how long, how it last
/// went and Run / Cancel. Nothing starts on its own. A partial run lists what
/// it could not read, relay by relay. The list is the relay's own
/// (ImportJobsC), re-read on every IMPORT_JOB line (ImportJobsService).
struct StillToBringInSection: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var jobs = ImportJobsService.shared

    /// Unread ranges shown per item before "and n more".
    private static let unreadShown = 4

    var body: some View {
        DashboardSection(title: "Still to bring in") {
            let items = rows
            ForEach(Array(items.enumerated()), id: \.element.id) { index, job in
                row(job)
                if index < items.count - 1 { DashboardDivider() }
            }
            if items.isEmpty {
                DashboardRow(icon: "tray.and.arrow.down", title: "Still to bring in",
                             detail: relayManager.isRunning ? "Loading…" : "Start your vault to see what's left to bring in.",
                             state: .info) { EmptyView() }
            }
            if let refusal = jobs.runRefusal {
                Text(refusal)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .onAppear { jobs.refresh() }
        .onChange(of: relayManager.isRunning) { _, _ in jobs.refresh() }
    }

    /// The card's jobs, in the engine's order; one the engine doesn't list
    /// yet shows as not run.
    private var rows: [ImportJobs.Job] {
        guard let list = jobs.list else { return [] }
        return ImportJobs.cardJobs.map { name in
            list.job(name) ?? ImportJobs.Job(name: name, status: "never")
        }
    }

    private func isRunningNow(_ job: ImportJobs.Job) -> Bool { jobs.runningJob == job.name }

    @ViewBuilder
    private func row(_ job: ImportJobs.Job) -> some View {
        let running = isRunningNow(job)
        let detail = [ImportJobs.blurb(job.name), ImportJobs.statusText(job, runningNow: running)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        VStack(alignment: .leading, spacing: 0) {
            DashboardRow(icon: icon(job.name), title: ImportJobs.title(job.name), detail: detail,
                         state: job.status == "done" ? .done : job.status == "partial" || job.status == "failed" ? .todo : .info) {
                if running {
                    RowButton(title: "Cancel") { jobs.cancel(job.name) }
                } else {
                    RowButton(title: ImportJobs.runTitle(job)) { jobs.run(job.name) }
                        .disabled(!relayManager.isRunning || jobs.runningJob != nil)
                }
            }
            .accessibilityIdentifier("stillToBringIn.\(job.name)")
            if running {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.havenPurple)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
            let unread = ImportJobs.unreadLines(job)
            if !running, !unread.isEmpty {
                unreadList(unread)
            }
        }
    }

    private func unreadList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Not read:")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(lines.prefix(Self.unreadShown), id: \.self) { line in
                Text(line)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lines.count > Self.unreadShown {
                Text("and \(lines.count - Self.unreadShown) more")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 56)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private func icon(_ name: String) -> String {
        switch name {
        case "replies": return "bubble.left.and.bubble.right.fill"
        case "older_relays": return "clock.arrow.circlepath"
        case "wider_network": return "globe"
        case "list_history": return "list.bullet.rectangle"
        default: return "tray.and.arrow.down"
        }
    }
}

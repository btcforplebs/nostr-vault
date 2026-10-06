import SwiftUI
import UniformTypeIdentifiers

// The dashboard's console in plain language, built on `PlainLog`.
//
// The raw relay log lives in Settings › Logs for people debugging. These views
// answer "is my relay OK, and if not, what do I do?": one line per thing that
// happened, repeats folded into a count, problems carrying a hint. Copy and
// Export only ever hand out `PlainLog.exportText`, which is built from the
// translated items and scrubbed of keys, ids, IPs and paths.
//
// Each view observes `LogStore` itself so log traffic redraws the console and
// nothing else on the dashboard.

// MARK: - Shared pieces

extension PlainLog.Severity {
    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .headsUp: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .good: return .havenOnline
        case .headsUp: return .orange
        case .problem: return .red
        }
    }

    /// Sentence for the status pill and window banner.
    var summary: String {
        switch self {
        case .good: return "Everything looks fine"
        case .headsUp: return "Working, with a few hiccups"
        case .problem: return "Something needs your attention"
        }
    }
}

/// Status pill: the worst thing since the relay last came up.
struct RelayHealthPill: View {
    let health: PlainLog.Severity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: health.symbol)
                .font(.appSystem(size: 9, weight: .bold))
            Text(health.label)
                .font(.appSystem(size: 10, weight: .semibold))
        }
        .foregroundColor(health.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(health.tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Relay status: \(health.label)"))
    }
}

/// One translated log item. `compact` is the dashboard card; the window and
/// the wide console use the roomier layout.
struct RelayActivityRow: View {
    let item: PlainLog.Item
    var compact = false

    private var showsHint: Bool { item.severity != .good && item.hint != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 10) {
            Image(systemName: item.severity.symbol)
                .font(.appSystem(size: compact ? 11 : 13, weight: .semibold))
                .foregroundColor(item.severity.tint)
                .frame(width: compact ? 14 : 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(compact ? .appSystem(size: 12, weight: .medium) : .appSubheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(compact ? 1 : 3)
                        .fixedSize(horizontal: false, vertical: true)

                    if item.count > 1 {
                        Text("×\(item.count)")
                            .font(.appSystem(size: compact ? 10 : 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }

                    Spacer(minLength: 4)

                    Text(item.lastSeen, style: .time)
                        .font(.appSystem(size: compact ? 10 : 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if showsHint, let hint = item.hint {
                    Text(hint)
                        .font(compact ? .appSystem(size: 11) : .appFootnote)
                        .foregroundColor(.secondary)
                        .lineLimit(compact ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: !compact)
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 6 : 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = ["\(item.severity.label): \(item.title)"]
        if item.count > 1 { parts.append("\(item.count) times") }
        if showsHint, let hint = item.hint { parts.append(hint) }
        return parts.joined(separator: ". ")
    }
}

/// Copy and Export, shared by the wide console and the window. Both hand out
/// `PlainLog.exportText` only — never the raw log.
struct RelayActivityShareButtons: View {
    let items: [PlainLog.Item]
    /// Icon-only for tight headers; labelled in the window toolbar.
    var iconOnly = false

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: iconOnly ? 12 : 8) {
            Button(action: copy) {
                label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .help("Copy a privacy-safe report to the clipboard")
            .accessibilityLabel(Text(didCopy ? "Copied" : "Copy report"))

            #if os(macOS)
            Button(action: export) {
                label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Save a privacy-safe report as a text file")
            .accessibilityLabel(Text("Export report"))
            #else
            // ShareLink rather than a sheet: a sheet hung off a toolbar item
            // doesn't present reliably on iOS. The file is written only when
            // the user picks a destination.
            ShareLink(
                item: RelayReportFile(text: RelayActivityReport.text(items)),
                preview: SharePreview("Relay report")
            ) {
                label("Export", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(Text("Export report"))
            #endif
        }
        .buttonStyle(.plain)
        .foregroundColor(.havenPurple)
    }

    @ViewBuilder
    private func label(_ title: String, systemImage: String) -> some View {
        if iconOnly {
            Image(systemName: systemImage)
                .font(.appSystem(size: 11, weight: .semibold))
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        } else {
            Label(title, systemImage: systemImage)
                .font(.appSystem(size: 13, weight: .semibold))
        }
    }

    private func copy() {
        PlatformClipboard.copy(RelayActivityReport.text(items))
        withAnimation(Motion.fade) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(Motion.fade) { didCopy = false }
        }
    }

    #if os(macOS)
    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Relay Report"
        panel.nameFieldStringValue = RelayActivityReport.fileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RelayActivityReport.text(items).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // NSAlert, not .alert: these buttons sit in a toolbar item, where
            // SwiftUI presentations don't reliably show.
            NSAlert(error: error).runModal()
        }
    }
    #endif
}

/// The report as a .txt for the share sheet, written to a temp file only
/// when the user picks where it goes.
struct RelayReportFile: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { report in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(RelayActivityReport.fileName())
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// The text Copy and Export hand out: app version and OS on top, then the
/// scrubbed plain items. Nothing about the user's identity or network.
enum RelayActivityReport {
    static func text(_ items: [PlainLog.Item]) -> String {
        PlainLog.exportText(items, header: header)
    }

    static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "nostr-vault-relay-report-\(f.string(from: now)).txt"
    }

    private static var header: [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return [
            "App: \(version) (\(build))",
            "System: \(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
    }
}

/// Empty state shared by the card, the wide console and the window.
private struct RelayActivityEmpty: View {
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.appSystem(size: compact ? 18 : 26))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Nothing to report yet")
                .font(compact ? .appSystem(size: 12, weight: .medium) : .appCallout)
                .foregroundColor(.secondary)
            Text("Relay activity and any problems will show up here.")
                .font(compact ? .appSystem(size: 11) : .appCaption)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Newest-at-bottom list that follows new activity.
private struct RelayActivityList: View {
    let items: [PlainLog.Item]
    var compact = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        RelayActivityRow(item: item, compact: compact)
                            .id(item.id)
                    }
                }
                .padding(.vertical, compact ? 2 : 4)
            }
            // A repeat moves its item to the end without changing the count,
            // so follow the last id rather than the count.
            .onChange(of: items.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Motion.isReduced ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Dashboard card

/// The compact console on the dashboard: status pill, the latest few items,
/// and "View All" into the window.
struct RelayActivityCard: View {
    @ObservedObject var logStore: LogStore
    let onViewAll: () -> Void

    var body: some View {
        let items = PlainLog.summarize(logStore.logs)
        VStack(alignment: .leading, spacing: 0) {
            RelayConsoleHeader(title: "RELAY ACTIVITY", health: PlainLog.health(items)) {
                Button(action: onViewAll) {
                    Text("View All")
                        .font(.appSystem(size: 10, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.platformCardBorder)

            Group {
                if items.isEmpty {
                    RelayActivityEmpty(compact: true)
                } else {
                    RelayActivityList(items: Array(items.suffix(30)), compact: true)
                }
            }
            .frame(height: 140)
        }
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.havenOnline.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Wide console (macOS dashboard)

/// The full-height console in the wide macOS layout. Same content as the
/// window, with Copy/Export in the header.
struct RelayActivityPanel: View {
    @ObservedObject var logStore: LogStore

    var body: some View {
        let items = PlainLog.summarize(logStore.logs)
        VStack(alignment: .leading, spacing: 0) {
            RelayConsoleHeader(title: "RELAY ACTIVITY", health: PlainLog.health(items)) {
                RelayActivityShareButtons(items: items, iconOnly: true)
                    .disabled(items.isEmpty)
            }

            Divider().background(Color.platformCardBorder)

            if items.isEmpty {
                RelayActivityEmpty()
            } else {
                RelayActivityList(items: items)
                    .frame(maxHeight: .infinity)
            }

            RelayPrivacyFooter()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.havenOnline.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Window

/// "View All": the whole plain log with a status banner, a Problems filter,
/// Copy/Export, and a way through to the raw log for power users.
struct RelayActivityWindow: View {
    @ObservedObject var logStore: LogStore
    let onDone: () -> Void

    @State private var issuesOnly = false

    var body: some View {
        let items = PlainLog.summarize(logStore.logs)
        let health = PlainLog.health(items)
        let shown = issuesOnly ? items.filter { $0.severity != .good } : items

        VStack(spacing: 0) {
            statusBanner(health: health, items: items)

            Picker("Show", selection: $issuesOnly) {
                Text("Everything").tag(false)
                Text("Needs attention").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider().background(Color.platformCardBorder)

            if shown.isEmpty {
                if issuesOnly && !items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.appSystem(size: 26))
                            .foregroundColor(.havenOnline.opacity(0.7))
                        Text("Nothing needs attention")
                            .font(.appCallout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RelayActivityEmpty()
                }
            } else {
                RelayActivityList(items: shown)
            }

            Divider().background(Color.platformCardBorder)

            HStack {
                RelayPrivacyFooter(padded: false)
                Spacer(minLength: 8)
                NavigationLink {
                    // macOS: Done here too. The root's Done leaves with the
                    // push, and a sheet has no other way out. iOS has Back.
                    LogsView(logStore: logStore)
                        #if os(macOS)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done", action: onDone)
                            }
                        }
                        #endif
                } label: {
                    Text("Open full logs")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .buttonStyle(.plain)
                .help("The raw relay log, for troubleshooting")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .navigationTitle("Relay Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
            }
            ToolbarItem(placement: .primaryAction) {
                RelayActivityShareButtons(items: items)
                    .disabled(items.isEmpty)
            }
        }
    }

    private func statusBanner(health: PlainLog.Severity, items: [PlainLog.Item]) -> some View {
        let lastUp = items.first { $0.key == "running" }?.lastSeen ?? .distantPast
        let current = items.filter { $0.severity == health && $0.lastSeen >= lastUp && health != .good }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: health.symbol)
                .font(.appSystem(size: 22, weight: .semibold))
                .foregroundColor(health.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(health.summary)
                    .font(.appHeadline)
                if let top = current.last {
                    Text(top.hint.map { "\(top.title). \($0)" } ?? top.title)
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your relay is running normally.")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(health.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(health.tint.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header / footer

struct RelayConsoleHeader<Trailing: View>: View {
    let title: String
    let health: PlainLog.Severity
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.appSystem(size: 10, weight: .bold))
                .foregroundColor(.havenOnline)

            Text(title)
                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)

            RelayHealthPill(health: health)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.platformConsoleHeaderBackground)
    }
}

/// States what Copy/Export leave out, so people know a report is safe to share.
private struct RelayPrivacyFooter: View {
    var padded = true

    var body: some View {
        Label("Copies leave out keys, IDs, IP addresses and file paths.", systemImage: "lock.shield")
            .font(.appSystem(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, padded ? 12 : 0)
            .padding(.vertical, padded ? 7 : 0)
    }
}

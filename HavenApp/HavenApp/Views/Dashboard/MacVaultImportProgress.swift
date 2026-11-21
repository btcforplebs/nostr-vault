#if os(macOS)
import SwiftUI

/// Vault Dashboard › Keep it full, Mac only: the detail the Mac relay
/// console's Import Progress and Media Import sections showed beyond the
/// phone rows' bar and status line (DashboardView+ImportSections): the import
/// percentage, the media copy's live log, and Dismiss once the copy is done.
/// Shown only while one of them has something to show.
struct MacVaultImportProgress: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var mirrorService = MirrorService.shared

    static func isVisible(relayManager: RelayProcessManager, mirror: MirrorService) -> Bool {
        relayManager.isImporting || mirror.state != .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if relayManager.isImporting {
                HStack {
                    Text("Importing notes")
                    Spacer()
                    Text("\(Int(relayManager.importProgress * 100))%")
                        .font(.appSystem(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentText)
                }
                .font(.appSystem(size: 13, weight: .semibold))
            }
            if mirrorService.state != .idle {
                HStack {
                    Text(mirrorService.state == .complete ? "Media import done" : "Importing media")
                    Spacer()
                    if let prog = mirrorService.progress {
                        Text("\(prog.completed)/\(prog.total)")
                            .font(.appSystem(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.havenOnline)
                    }
                }
                .font(.appSystem(size: 13, weight: .semibold))
                if !mirrorService.logEntries.isEmpty { mirrorLog }
                if mirrorService.state == .complete {
                    Button("Dismiss") {
                        mirrorService.state = .idle
                        mirrorService.logEntries = []
                    }
                    .buttonStyle(.plain)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.accentText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var mirrorLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(mirrorService.logEntries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.timestamp, style: .time)
                                .font(.appSystem(size: 9, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .frame(width: 55, alignment: .leading)
                            Text(entry.level)
                                .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.logLevel(entry.level))
                                .frame(width: 35, alignment: .leading)
                            Text(entry.message)
                                .font(.appSystem(size: 10, design: .monospaced))
                                .foregroundColor(.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(entry.id)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 160)
            .background(Color.platformTertiaryGroupedBackground, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: mirrorService.logEntries.count) { _, _ in
                if let lastId = mirrorService.logEntries.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }
}
#endif

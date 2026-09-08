import SwiftUI

struct LogsView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    /// Observe the separate LogStore so only this view redraws on log changes.
    @ObservedObject var logStore: LogStore
    var hideHeader: Bool = false
    @State private var showCopiedScrub = false
    @State private var filterLevel: String = "ALL"

    private static let levelOrder = ["DEBUG", "INFO", "WARN", "ERROR"]

    private var filteredLogs: [RelayProcessManager.LogEntry] {
        guard filterLevel != "ALL",
              let minIndex = Self.levelOrder.firstIndex(of: filterLevel) else {
            return logStore.logs
        }
        return logStore.logs.filter { entry in
            guard let entryIndex = Self.levelOrder.firstIndex(of: entry.level) else { return true }
            return entryIndex >= minIndex
        }
    }

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        ScrollViewReader { proxy in
            List(filteredLogs) { log in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(log.level)
                            .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(colorFor(level: log.level).opacity(0.2))
                            .foregroundColor(colorFor(level: log.level))
                            .cornerRadius(4)

                        Text(log.timestamp, style: .time)
                            .font(.appSystem(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer()
                    }

                    Text(log.message)
                        .font(.appSystem(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(log.id)
                .listRowSeparator(.hidden)
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .navigationTitle("System Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        filterPicker
                        Button(action: copyLogs) {
                            if showCopiedScrub {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }
            }
            .onChange(of: filteredLogs.count) { _, _ in
                if let lastId = filteredLogs.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastId = filteredLogs.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
    #endif

    private var macOSBody: some View {
        VStack(spacing: 0) {
            if !hideHeader {
                // Header with inline controls
                HStack(spacing: 12) {
                    Text("System Logs")
                        .font(.appHeadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    filterPicker

                    relayLogLevelPicker

                    Button(action: copyLogs) {
                        if showCopiedScrub {
                            Label("Copied!", systemImage: "checkmark")
                        } else {
                            Label("Copy Logs", systemImage: "doc.on.doc")
                        }
                    }
                    .disabled(filteredLogs.isEmpty)
                    .help("Copy visible logs to clipboard")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
            }

            if filteredLogs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    if logStore.logs.isEmpty {
                        Text("No logs yet")
                            .font(.appCallout)
                            .foregroundColor(.secondary)
                        Text("Logs will appear here once the relay is running.")
                            .font(.appCaption)
                            .foregroundColor(.secondary.opacity(0.7))
                    } else {
                        Text("No \(filterLevel) logs")
                            .font(.appCallout)
                            .foregroundColor(.secondary)
                        Text("Try a less restrictive filter level.")
                            .font(.appCaption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(filteredLogs) { log in
                        HStack(alignment: .top) {
                            Text(log.timestamp, style: .time)
                                .font(.appCaption2)
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .leading)

                            Text(log.level)
                                .font(.appCaption2)
                                .fontWeight(.bold)
                                .foregroundColor(colorFor(level: log.level))
                                .frame(width: 50, alignment: .leading)

                            Text(log.message)
                                .font(.appCallout.monospaced())
                                .textSelection(.enabled)
                        }
                        .id(log.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: filteredLogs.count) { _, _ in
                        if let lastId = filteredLogs.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let lastId = filteredLogs.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Controls

    private var filterPicker: some View {
        Picker("Filter", selection: $filterLevel) {
            Text("All").tag("ALL")
            Text("Info+").tag("INFO")
            Text("Warn+").tag("WARN")
            Text("Errors").tag("ERROR")
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .help("Filter displayed log entries by minimum level")
    }

    private var relayLogLevelPicker: some View {
        HStack(spacing: 4) {
            Text("Relay:")
                .font(.appCaption)
                .foregroundColor(.secondary)
            Picker("", selection: $configService.config.logLevel) {
                Text("Debug").tag("DEBUG")
                Text("Info").tag("INFO")
                Text("Warn").tag("WARN")
                Text("Error").tag("ERROR")
            }
            .frame(width: 80)
            .help("Log level sent to the relay process (takes effect on restart)")
        }
    }

    // MARK: - Actions

    func copyLogs() {
        let snapshot = filteredLogs
        DispatchQueue.global(qos: .userInitiated).async {
            let logString = snapshot.map { log in
                let dateStr = log.timestamp.formatted(.dateTime.hour().minute().second())
                return "[\(dateStr)] [\(log.level)] \(log.message)"
            }.joined(separator: "\n")

            DispatchQueue.main.async {
                PlatformClipboard.copy(logString)
                showCopiedScrub = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    showCopiedScrub = false
                }
            }
        }
    }

    func colorFor(level: String) -> Color { .logLevel(level) }
}

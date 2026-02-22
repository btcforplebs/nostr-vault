import SwiftUI

struct LogsView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showCopiedScrub = false
    
    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }
    
    private var iOSBody: some View {
        ScrollViewReader { proxy in
            List(relayManager.logs) { log in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(log.level)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(colorFor(level: log.level).opacity(0.2))
                            .foregroundColor(colorFor(level: log.level))
                            .cornerRadius(4)
                        
                        Text(log.timestamp, style: .time)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    
                    Text(log.message)
                        .font(.system(size: 13, design: .monospaced))
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
                    Button(action: copyLogs) {
                        if showCopiedScrub {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
            .onChange(of: relayManager.logs.count) { newValue in
                if let lastId = relayManager.logs.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastId = relayManager.logs.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
    
    private var macOSBody: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("System Logs")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: copyLogs) {
                    if showCopiedScrub {
                        Label("Copied!", systemImage: "checkmark")
                    } else {
                        Label("Copy Logs", systemImage: "doc.on.doc")
                    }
                }
                .disabled(relayManager.logs.isEmpty)
                .help("Copy logs to clipboard")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            Divider()
            
            ScrollViewReader { proxy in
                List(relayManager.logs) { log in
                    HStack(alignment: .top) {
                        Text(log.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        
                        Text(log.level)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(colorFor(level: log.level))
                            .frame(width: 50, alignment: .leading)
                        
                        Text(log.message)
                            .font(.system(size: 15, design: .monospaced))
                    }
                    .id(log.id)
                }
                .listStyle(.plain)
                .onChange(of: relayManager.logs.count) { _ in
                    if let lastId = relayManager.logs.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // Copy all logs functionality for debugging
    func copyLogs() {
        let logsSnapshot = relayManager.logs
        DispatchQueue.global(qos: .userInitiated).async {
            let logString = logsSnapshot.map { log in
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
    
    func colorFor(level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "DEBUG": return .gray
        default: return .blue
        }
    }
}

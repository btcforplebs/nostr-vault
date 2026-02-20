import SwiftUI

struct LogsView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    var body: some View {
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
                            .font(.callout)
                            .fontDesign(.monospaced)
                    }
                    .id(log.id) // Important for identifying the row
                }
                .listStyle(.plain)
                .padding(.bottom, 20)
                .onChange(of: relayManager.logs.count) { oldValue, newValue in
                    // Auto-scroll to bottom directly
                    if let lastId = relayManager.logs.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                // Also scroll on appear just in case
                .onAppear {
                    if let lastId = relayManager.logs.last?.id {
                         proxy.scrollTo(lastId, anchor: .center)
                    }
                }
            }
        }
    }
    
    @State private var showCopiedScrub = false
    
    // Copy all logs functionality for debugging
    func copyLogs() {
        let logsSnapshot = relayManager.logs
        #if DEBUG
        print("DEBUG: Copying \(logsSnapshot.count) logs...")
        #endif
        
        DispatchQueue.global(qos: .userInitiated).async {
            let logString = logsSnapshot.map { log in
                let dateStr = log.timestamp.formatted(.dateTime.hour().minute().second())
                return "[\(dateStr)] [\(log.level)] \(log.message)"
            }.joined(separator: "\n")
            
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                let success = NSPasteboard.general.setString(logString, forType: .string)
                #if DEBUG
                print("DEBUG: Copy to pasteboard success: \(success)")
                #endif
                
                if success {
                    showCopiedScrub = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showCopiedScrub = false
                    }
                }
            }
        }
    }
    
    func colorFor(level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .primary
        }
    }
}

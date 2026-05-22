import SwiftUI

public struct UGCReportingDialog: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    
    let eventId: String?
    let pubkey: String
    let onReport: () -> Void
    
    @State private var selectedReason = "spam"
    @State private var description = ""
    @State private var isReporting = false
    
    public init(eventId: String?, pubkey: String, onDismiss: (() -> Void)? = nil, onReport: @escaping () -> Void) {
        self.eventId = eventId
        self.pubkey = pubkey
        self.onDismiss = onDismiss
        self.onReport = onReport
    }
    
    let reasons = [
        ("Spam", "spam"),
        ("Nudity / Sexual Content", "nudity"),
        ("Violence / Harm", "violence"),
        ("Illegal Content", "illegal"),
        ("Impersonation", "impersonation"),
        ("Other", "other")
    ]
    
    public var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Why are you reporting this?")
                        .font(.headline)
                        .padding(.top)
                    
                    VStack(spacing: 8) {
                        ForEach(reasons, id: \.1) { label, value in
                            ReasonRow(label: label, value: value, selectedValue: $selectedReason)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional details (optional)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $description)
                            .frame(height: 80)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.orange)
                            Text("Reporting will also automatically block this user for you.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding()
            }
            
            footer
        }
        .frame(minWidth: 400, maxWidth: 500, minHeight: 500, maxHeight: 650)
        .background(Color.platformControlBackground)
    }
    
    private var header: some View {
        HStack {
            Text("Report Content")
                .font(.system(size: 18, weight: .bold))
            Spacer()
            Button(action: { performDismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
    }
    
    private var footer: some View {
        HStack(spacing: 16) {
            Button("Cancel") {
                performDismiss()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            Button(action: performReport) {
                if isReporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Report & Block")
                }
            }
            .buttonStyle(.plain)
            .disabled(isReporting)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.8))
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
    }
    
    private func performReport() {
        isReporting = true
        
        // 1. Send Kind 1984 event
        if let eventId = eventId {
            nostrService.reportEvent(eventId: eventId, pubkey: pubkey, reason: selectedReason, description: description)
        } else {
            nostrService.reportUser(pubkey: pubkey, reason: selectedReason, description: description)
        }
        
        // 2. Add to local blacklist
        blockUser(hexPubkey: pubkey)
        
        // 3. Callback and dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isReporting = false
            onReport()
            performDismiss()
        }
    }
    
    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
    
    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
    }
}

struct ReasonRow: View {
    let label: String
    let value: String
    @Binding var selectedValue: String
    
    var body: some View {
        Button(action: { selectedValue = value }) {
            HStack {
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                if selectedValue == value {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(selectedValue == value ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedValue == value ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

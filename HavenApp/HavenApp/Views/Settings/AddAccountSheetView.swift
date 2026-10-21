import SwiftUI

struct AddAccountSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    @State private var addInput = ""
    @State private var addError: String? = nil

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    performDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Text("Add Account")
                    .font(.appHeadline)
                
                Spacer()
                
                Button("Add") {
                    processAddAccount()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(addInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Npub")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                
                TextEditor(text: $addInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .padding(6)
                    .background(Color.platformControlBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                
                if let error = addError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.appCaption)
                }
            }
            .padding(20)
            
            Spacer()
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 460, height: 210)
        #else
        NavigationStack {
            Form {
                Section("Npub") {
                    TextEditor(text: $addInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
                if let error = addError { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { performDismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { processAddAccount() } }
            }
        }
        #endif
    }

    private func processAddAccount() {
        let input = addInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.starts(with: "npub") else {
            addError = "Must be an npub"; return
        }
        if !configService.config.whitelistedNpubs.contains(input) {
            configService.config.whitelistedNpubs.append(input)
        }
        configService.save()
        performDismiss()
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

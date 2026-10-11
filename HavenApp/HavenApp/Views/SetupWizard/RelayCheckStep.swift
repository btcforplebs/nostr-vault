import SwiftUI

// MARK: - Relay check

/// Between Your key and the import tour: checks which relays answer and
/// have this person's notes, so the import can't hang on a dead one.
/// "Start import" saves the picks to `importSeedRelays`, which is what the
/// import reads.
struct RelayCheckStep: View {
    @EnvironmentObject var configService: ConfigService
    let npub: String
    let onStart: () -> Void

    @State private var rows: [RelayCheck.Row] = []
    @State private var isChecking = true
    @State private var editing = false
    @State private var newRelay = ""
    @State private var started = false

    private var pubkey: String { Bech32.decode(npub)?.hexString ?? "" }
    private var onCount: Int { rows.filter(\.isOn).count }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text(isChecking ? "Checking your relays" : "Ready to import")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            Text(isChecking ? "Looking for your notes. This takes a few seconds." : RelayCheck.summary(rows))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach($rows) { $row in
                    relayRow($row)
                    if row.id != rows.last?.id {
                        Divider().background(WizardColors.borderSubtle)
                    }
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

            if editing {
                addRow
            }

            WizardPrimaryButton(title: "Start import", action: start, disabled: isChecking || onCount == 0)

            Button(editing ? "Done" : "Change import relays") { editing.toggle() }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(minHeight: 44)
                .disabled(isChecking)
                .buttonStyle(.plain)
        }
        .task {
            guard !started else { return }
            started = true
            await runCheck()
        }
    }

    private func relayRow(_ row: Binding<RelayCheck.Row>) -> some View {
        let value = row.wrappedValue
        let dot: Color = switch value.result {
        case .checking: WizardColors.textMuted
        case .ready: WizardColors.success
        case .slow: WizardColors.accentPrimary
        case .notAnswering, .refused, .needsSignIn: WizardColors.error
        }
        return HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(value.url.replacingOccurrences(of: "wss://", with: ""))
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(1)
                    if value.isYours {
                        Text("yours")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(WizardColors.accentPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WizardColors.accentPrimary.opacity(0.15))
                            .cornerRadius(6)
                    }
                }
                Text(value.result.label)
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textSecondary)
            }
            Spacer(minLength: 0)
            if editing {
                Toggle("Import from \(value.url)", isOn: row.isOn)
                    .labelsHidden()
                    .tint(WizardColors.accentPrimary)
                    .disabled(!value.result.canImport)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: editing ? .contain : .combine)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Add a relay, e.g. relay.example.com", text: $newRelay)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 14))
                .foregroundColor(WizardColors.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .submitLabel(.done)
                .onSubmit(addRelay)
            Button("Add", action: addRelay)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(RelayCheck.normalize(newRelay) == nil)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(WizardColors.bgCard)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WizardColors.borderSubtle, lineWidth: 1))
    }

    // MARK: Actions

    private func runCheck() async {
        // Their relay list says where their notes are; the defaults are
        // where most people's notes also land.
        let list = await NostrService.shared.fetchNewestReplaceable(
            kind: 10002, for: pubkey, alsoAsk: configService.config.importSeedRelays
        )
        rows = RelayCheck.rows(relayListTags: list?.tags ?? [], defaults: HavenConfig().importSeedRelays)
        await withTaskGroup(of: (String, RelayCheck.Result).self) { group in
            for row in rows {
                group.addTask { @MainActor in
                    (row.url, await RelayCheckProbe.check(url: row.url, pubkey: pubkey))
                }
            }
            for await (url, result) in group {
                if let i = rows.firstIndex(where: { $0.url == url }) {
                    rows[i].result = result
                    rows[i].isOn = result.onByDefault
                }
            }
        }
        isChecking = false
    }

    private func addRelay() {
        guard let url = RelayCheck.normalize(newRelay), !rows.contains(where: { $0.url == url }) else { return }
        newRelay = ""
        rows.append(RelayCheck.Row(url: url, isYours: false))
        Task {
            let result = await RelayCheckProbe.check(url: url, pubkey: pubkey)
            if let i = rows.firstIndex(where: { $0.url == url }) {
                rows[i].result = result
                rows[i].isOn = result.onByDefault
            }
        }
    }

    private func start() {
        configService.config.importSeedRelays = RelayCheck.importList(rows)
        configService.save()
        onStart()
    }
}

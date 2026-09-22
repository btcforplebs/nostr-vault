import SwiftUI

struct ContentView: View {
    @StateObject private var model = FipsModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.running ? .green : .secondary)
                                .frame(width: 8, height: 8)
                            Text(model.running ? "running" : "stopped")
                        }
                    }
                    if model.running {
                        LabeledContent("Uptime", value: "\(model.uptime)s")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This device").font(.caption).foregroundStyle(.secondary)
                            Text(model.npub)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Text(model.address)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Memory", value: String(format: "%.0f MB", model.memoryMB))

                    if !model.running {
                        Button("Start FIPS endpoint") { model.start() }
                            .disabled(model.busy)
                    } else {
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                }

                Section("Provider") {
                    TextField("npub from `fips_serve` on your Mac", text: $model.peerNpub)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Open loopback proxy") { model.connect() }
                        .disabled(!model.running || model.busy)

                    if let port = model.loopbackPort {
                        LabeledContent("Proxy", value: "127.0.0.1:\(port)")
                    }
                }

                Section("Fetch over the mesh") {
                    Button {
                        Task { await model.fetch() }
                    } label: {
                        if model.busy {
                            HStack { ProgressView(); Text("working…") }
                        } else {
                            Text("GET /blob via URLSession")
                        }
                    }
                    .disabled(model.loopbackPort == nil || model.busy)

                    Text("Fetches through the loopback proxy with a stock URLSession — the same path AVURLAsset and AsyncImage would take.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Log") {
                    ForEach(model.log) { line in
                        HStack(alignment: .top, spacing: 6) {
                            if let ok = line.ok {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                                    .font(.caption)
                            }
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("FIPS Probe")
        }
    }
}

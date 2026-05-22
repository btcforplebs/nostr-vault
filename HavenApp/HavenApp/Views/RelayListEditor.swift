import SwiftUI

struct RelayListEditor: View {
    @Binding var relays: [String]
    @State private var newRelay = ""
    
    var body: some View {
        Group {
            #if os(iOS)
            iOSContent
            #else
            macOSContent
            #endif
        }
    }
    
    #if os(iOS)
    private var iOSContent: some View {
        Group {
            ForEach(relays, id: \.self) { relay in
                HStack {
                    Text(relay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        relays.removeAll(where: { $0 == relay })
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .onDelete(perform: delete)
            
            HStack {
                TextField("wss://relay.example.com", text: $newRelay)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                
                Button(action: addRelay) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.havenPurple)
                        .font(.title3)
                }
                .disabled(newRelay.isEmpty)
            }
        }
    }
    #endif

    private var macOSContent: some View {
        VStack(spacing: 0) {
            List {
                ForEach(relays, id: \.self) { relay in
                    HStack {
                        Text(relay)
                        Spacer()
                        Button(action: {
                            relays.removeAll(where: { $0 == relay })
                        }) {
                            Image(systemName: "minus.circle")
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete(perform: delete)
            }
            .listStyle(.inset)
            .frame(minHeight: 100)
            
            Divider()
            
            HStack {
                TextField("wss://relay.example.com", text: $newRelay)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRelay() }

                Button(action: addRelay) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .disabled(newRelay.isEmpty)
            }
            .padding(8)
            .background(Color.platformControlBackground)
        }
        .background(Color.platformControlBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func addRelay() {
        var trimmed = newRelay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !trimmed.hasPrefix("wss://") && !trimmed.hasPrefix("ws://") {
                trimmed = "wss://" + trimmed
            }
            
            if !relays.contains(trimmed) {
                relays.append(trimmed)
                newRelay = ""
            }
        }
    }
    
    private func delete(at offsets: IndexSet) {
        relays.remove(atOffsets: offsets)
    }
}

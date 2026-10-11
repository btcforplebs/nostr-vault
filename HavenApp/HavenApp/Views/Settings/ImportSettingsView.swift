import SwiftUI

struct ImportSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    private var importDateBinding: Binding<Date> {
        Binding<Date>(
            get: {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = TimeZone(identifier: "UTC")
                return fmt.date(from: configService.config.importStartDate) ?? Date()
            },
            set: { newDate in
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = TimeZone(identifier: "UTC")
                configService.config.importStartDate = fmt.string(from: newDate)
            }
        )
    }

    var body: some View {
        Form {
            // No "Seed Relays File" field: the app writes that file from the
            // list below on every relay start, so a typed path was ignored.
            Section {
                DatePicker(selection: importDateBinding, displayedComponents: .date) {
                    Text("Start Date").settingInfo(.relayImport)
                }
            } footer: {
                Text("Import pulls from the relays with Import on, in Settings > Relays.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

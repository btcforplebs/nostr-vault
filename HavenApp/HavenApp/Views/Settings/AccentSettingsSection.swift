import SwiftUI

/// Settings › Appearance › Accent: eight ready-made colours and the system
/// colour wheel, with a small preview of the pick in both modes
/// (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md; web twin: net/accent.js).
struct AccentSettingsSection: View {
    @EnvironmentObject var configService: ConfigService

    private var pickedHex: String { AccentPalette.hex(fromSetting: configService.config.themeColor) }

    private var wheel: Binding<Color> {
        Binding(
            get: { AccentPalette.swatch(pickedHex) },
            set: { pick(AccentPalette.hex(of: $0)) }
        )
    }

    var body: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(AccentPalette.presets, id: \.hex) { preset in
                    swatch(preset.hex, name: preset.name)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            ColorPicker(selection: wheel, supportsOpacity: false) {
                Label("Any Colour", systemImage: "paintpalette")
            }
            .accessibilityIdentifier("appearance.accentWheel")

            HStack(spacing: 10) {
                preview(.dark)
                preview(.light)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Accent")
        } footer: {
            Text(AccentPalette.shiftsInLight(pickedHex)
                 ? "This colour is too pale to read as text on white, so in Light mode links and #tags use a deeper shade. Buttons keep the colour."
                 : "Buttons, links and highlights use this colour. Dark mode shows a brighter, neon version.")
        }
    }

    private func swatch(_ hex: String, name: String) -> some View {
        let on = hex == pickedHex
        return Button { pick(hex) } label: {
            Circle()
                .fill(AccentPalette.swatch(hex))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(Color.ink, lineWidth: on ? 2 : 0).padding(-4))
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One mode's look: a filled button and a link, on that mode's card.
    private func preview(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scheme == .dark ? "Dark" : "Light")
                .font(.appCaption)
                .foregroundColor(.ink.opacity(0.6))
            Text("Follow")
                .font(.appSubheadline.weight(.semibold))
                .foregroundColor(.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.havenPurple))
            Text("nostrvault.app")
                .font(.appFootnote)
                .foregroundColor(.accentText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface0))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.borderHairline, lineWidth: 1))
        .environment(\.colorScheme, scheme)
        .accessibilityElement(children: .combine)
    }

    private func pick(_ hex: String) {
        let setting = AccentPalette.setting(forHex: hex)
        guard setting != configService.config.themeColor else { return }
        configService.config.themeColor = setting
        configService.save()
    }
}

import SwiftUI

/// Shown while the keychain will not take the owner's key
/// (ConfigService.ownerKeyNotSaved): the key is in memory only, and the app
/// cannot open it after it closes. A plaintext key is never written to
/// config.json instead (PlainOwnerKeyAtRest). Comes back if the key goes
/// unsaved again after it was saved. Twin of Android's OwnerKeyNotSavedDialog.
struct OwnerKeyNotSavedAlert: ViewModifier {
    @EnvironmentObject private var configService: ConfigService
    @State private var dismissed = false

    private static var device: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: configService.ownerKeyNotSaved) { _, notSaved in
                if !notSaved { dismissed = false }
            }
            .alert("Your key isn't saved on this \(Self.device)", isPresented: Binding(
                get: { configService.ownerKeyNotSaved && !dismissed },
                set: { if !$0 { dismissed = true } }
            )) {
                Button("OK", role: .cancel) { dismissed = true }
            } message: {
                Text("This \(Self.device)'s keychain didn't take your key, so it is only kept until the app closes. Keep your nsec, or your encrypted key and its password: you'll need one to sign in again.")
            }
    }
}

extension View {
    func ownerKeyNotSavedAlert() -> some View { modifier(OwnerKeyNotSavedAlert()) }
}

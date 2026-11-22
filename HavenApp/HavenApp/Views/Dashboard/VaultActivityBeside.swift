import SwiftUI

private struct VaultActivityBesideKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The Vault Dashboard's live activity is drawn beside it, as a full-height
    /// panel (a wide Mac window, MacVaultDashboardPage), so the dashboard
    /// leaves out its own activity card.
    var vaultActivityBeside: Bool {
        get { self[VaultActivityBesideKey.self] }
        set { self[VaultActivityBesideKey.self] = newValue }
    }
}

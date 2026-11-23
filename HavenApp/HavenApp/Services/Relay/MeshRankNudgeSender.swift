#if os(macOS)
import Foundation

/// Mac: after a trust rank pass (`RANK_BUILT`), tells each paired device so
/// the ones that copy from this Mac catch up now (MeshRankNudge). Signed by
/// this Mac's mesh key, never the account key. A device that is asleep or
/// off the mesh misses it and catches up at its hourly check; one that does
/// not copy from this Mac answers 404.
@MainActor
final class MeshRankNudgeSender {
    static let shared = MeshRankNudgeSender()

    private var lastSent = 0
    private var sending: Task<Void, Never>?

    func rankBuilt() {
        let now = Int(Date().timeIntervalSince1970)
        guard sending == nil, now - lastSent >= MeshRankNudge.nudgeGap else { return }
        lastSent = now
        let devices = ConfigService.shared.config.meshDevices.map(\.npub)
        guard !devices.isEmpty else { return }
        sending = Task { [weak self] in
            for npub in devices { await Self.nudge(npub) }
            self?.sending = nil
        }
    }

    private static func nudge(_ npub: String) async {
        guard let base = await MacFipsMeshService.shared.ingressURL(meshNpub: npub),
              let url = MeshRankNudge.nudgeURL(base: base),
              let tags = MeshRankNudge.tags(base: base, receiver: npub),
              let auth = MeshKeySigner.authorization(kind: 27235, content: "", tags: tags) else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
        // Never log the URL: its path holds the ingress token.
        let code = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 204 {
            RelayProcessManager.shared.addLog("Mesh: told a device about the new trust rank")
        }
    }
}
#endif

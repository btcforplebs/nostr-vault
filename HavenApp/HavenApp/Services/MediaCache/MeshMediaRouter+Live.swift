import Foundation
import SwiftUI

extension MeshMediaRouter {
    static let shared = MeshMediaRouter(.live)
}

extension MeshMediaRouter.Dependencies {
    /// The app's follows, 10063 cache and mesh engine. The Mac app has no
    /// mesh engine yet, so there every read falls through to the URL.
    static var live: Self {
        Self(
            mayDial: { author in
                await MainActor.run {
                    FeedService.shared.followedPubkeySet.contains(author)
                        || author == NostrService.shared.activeHexPubkey
                }
            },
            serverList: { author in
                await MainActor.run { NostrService.shared.serverLists[author] }
            },
            requestServerList: { author in
                await MainActor.run { NostrService.shared.fetchMissingProfiles(for: [author], force: true) }
            },
            ingress: { npub in
                #if os(iOS)
                return await FipsMeshService.shared.ingressURL(meshNpub: npub)
                #else
                return nil
                #endif
            },
            get: { url, maxBytes in await MeshMediaGet.get(url, maxBytes: maxBytes) }
        )
    }
}

/// A whole-blob GET over a loopback mesh ingress, streamed to disk so an
/// oversized or endless body never sits in memory.
private enum MeshMediaGet {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // A quiet vault gives up like a slow server; a big photo may still trickle in.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, maxBytes: Int) async -> MeshMediaRouter.Reply? {
        // A Range answer could never match the hash: plain GET, all of it.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxBytes else { return .init(status: status, data: nil) }
            return .init(status: status, data: try Data(contentsOf: file))
        } catch {
            return nil
        }
    }
}

extension MediaCacheService {
    /// `fetchData`, plus the note author's own vault on the FIPS mesh (NIP-F1).
    /// A `.fips` photo is read over the mesh first; any other photo with a
    /// known hash only when its URL fails. A mesh read is cached under the
    /// note's URL, so scrolling back never dials again.
    func fetchData(url: URL, meshAuthor: String?) async -> Data? {
        guard let author = meshAuthor,
              let plan = MeshMediaRouter.plan(url: url, imetaSha256: MediaHints.shared.hint(for: url)?.sha256)
        else { return await fetchData(url: url) }

        if plan.meshFirst {
            if let cached = loadFromCache(url: url) { return cached }
            if let data = await readOverMesh(plan: plan, author: author, url: url) { return data }
            // Someone running a FIPS daemon can still open the URL as it is.
            return await fetchData(url: url)
        }
        if let data = await fetchData(url: url) { return data }
        return await readOverMesh(plan: plan, author: author, url: url)
    }

    private func readOverMesh(plan: MeshMediaRouter.Plan, author: String, url: URL) async -> Data? {
        guard let data = await MeshMediaRouter.shared.read(plan: plan, author: author) else { return nil }
        // print reaches relay.log, the file pulled off a device.
        print("FipsMesh: read \(plan.sha256.prefix(8)) over the mesh (\(data.count) bytes)")
        saveToCache(url: url, data: data)
        return data
    }
}

// MARK: - Which note a photo belongs to

private struct MeshMediaAuthorKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The author (hex) of the note whose media is drawn below: the only vault
    /// a photo may be read from over the mesh. nil keeps media off the mesh.
    var meshMediaAuthor: String? {
        get { self[MeshMediaAuthorKey.self] }
        set { self[MeshMediaAuthorKey.self] = newValue }
    }
}

extension View {
    /// Let the photos below be read from `pubkey`'s vault on the FIPS mesh.
    func meshMediaAuthor(_ pubkey: String?) -> some View {
        environment(\.meshMediaAuthor, pubkey)
    }
}

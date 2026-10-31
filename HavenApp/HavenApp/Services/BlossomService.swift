import Foundation
import CryptoKit
import os.log

/// BUD-02 Blob Descriptor returned by Blossom servers on successful upload
public struct BlobDescriptor: Codable {
    public let url: String
    public let sha256: String?
    public let size: Int?
    public let type: String?
    public let uploaded: Int?

    public init(url: String, sha256: String?, size: Int?, type: String?, uploaded: Int?) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.type = type
        self.uploaded = uploaded
    }
}

/// Source for a Blossom upload — either in-memory data or an on-disk file.
/// File uploads stream from disk, avoiding loading large videos into memory.
enum UploadSource {
    case data(Data)
    case file(URL)

    var byteCount: Int {
        switch self {
        case .data(let d):
            return d.count
        case .file(let url):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int) ?? 0
        }
    }
}

/// Handles uploading media to local and external Blossom servers
class BlossomService: @unchecked Sendable {
    let configService: ConfigService
    let nostrService: NostrService
    let logger = Logger(subsystem: "com.bitvora.haven", category: "blossom")
    let localhostSession: URLSession
    let remoteSession: URLSession

    // One pair of sessions for the whole app. A BlossomService is made at
    // each call site (each viewer page, each action), and each used to build
    // two URLSessions that were never invalidated: they leaked, and no
    // connection was reused, so every request paid a fresh TLS handshake.
    private static let sharedLocalhostDelegate = LocalhostTrustDelegate()

    // Trusts self-signed certs for localhost.
    private static let sharedLocalhostSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600  // 10 minutes
        config.timeoutIntervalForResource = 900  // 15 minutes
        return URLSession(configuration: config, delegate: sharedLocalhostDelegate, delegateQueue: nil)
    }()

    // Remote mirrors.
    private static let sharedRemoteSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600  // 10 minutes
        config.timeoutIntervalForResource = 900  // 15 minutes
        config.waitsForConnectivity = true  // Wait for network availability
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    init(configService: ConfigService, nostrService: NostrService) {
        self.configService = configService
        self.nostrService = nostrService
        self.localhostSession = Self.sharedLocalhostSession
        self.remoteSession = Self.sharedRemoteSession
    }

    /// Mirror a message into the app's own log as well as OSLog.
    ///
    /// Everything in this file logged only to OSLog, which is invisible from
    /// the Logs screen, invisible in the log file we pull off a device, and
    /// unreadable without Console.app attached at the moment of failure. A
    /// user reporting "the upload failed" therefore came with no evidence at
    /// all, and neither did the file. These are low-frequency, one line per
    /// upload decision, so they cost nothing next to the relay's own output.
    func appLog(_ message: String, level: String = "INFO") {
        // Two sinks on purpose. addLog reaches the in-app Logs screen, which is
        // what a user can read — but that store is in memory and a relaunch
        // wipes it. print() reaches relay.log via the stdout redirect, which is
        // the file we copy off a device after the fact. Writing to only the
        // first is how I shipped diagnostics I then could not read myself.
        RelayProcessManager.shared.addLog("Blossom: " + message, level: level)
        print("Blossom: \(message)")
    }
}

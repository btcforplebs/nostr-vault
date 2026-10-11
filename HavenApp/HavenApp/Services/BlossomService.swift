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
    private let localhostDelegate: LocalhostTrustDelegate
    let localhostSession: URLSession
    let remoteSession: URLSession

    init(configService: ConfigService, nostrService: NostrService) {
        self.configService = configService
        self.nostrService = nostrService

        // Create a session that trusts self-signed certs for localhost
        // Store delegate as property to ensure it stays alive for the lifetime of the session
        let localhostConfig = URLSessionConfiguration.default
        localhostConfig.timeoutIntervalForRequest = 600  // 10 minutes
        localhostConfig.timeoutIntervalForResource = 900  // 15 minutes
        self.localhostDelegate = LocalhostTrustDelegate()
        self.localhostSession = URLSession(configuration: localhostConfig, delegate: localhostDelegate, delegateQueue: nil)

        // Create a session for remote mirrors with proper timeout configuration
        let remoteConfig = URLSessionConfiguration.default
        remoteConfig.timeoutIntervalForRequest = 600  // 10 minutes
        remoteConfig.timeoutIntervalForResource = 900  // 15 minutes
        remoteConfig.waitsForConnectivity = true  // Wait for network availability
        self.remoteSession = URLSession(configuration: remoteConfig, delegate: nil, delegateQueue: nil)
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

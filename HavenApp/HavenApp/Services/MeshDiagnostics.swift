import Foundation
import os.log

/// Mesh diagnosis lines (Logen 2026-11-05: "we need to diagnose"), in the
/// system log next to the FIPS engine's own lines, readable on the Mac with
/// `log show --predicate 'subsystem == "com.bitvora.haven" AND category == "fips-mesh"'`
/// (the Mac app's relay.log sits in its sandbox container, out of reach).
/// Logging only. Lines name a peer by its first characters and a reason;
/// never a URL or base (an ingress base holds its token).
enum MeshDiagnostics {
    private static let logger = Logger(subsystem: "com.bitvora.haven", category: "fips-mesh")

    static func log(_ line: String) {
        logger.error("\(line, privacy: .public)")
    }
}

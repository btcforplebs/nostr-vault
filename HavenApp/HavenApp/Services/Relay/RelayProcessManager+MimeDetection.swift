import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    // Detect MIME type from file magic bytes (the "proof")
    nonisolated func detectMimeFromBytes(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "application/octet-stream" }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 64)
        guard header.count >= 4 else { return "application/octet-stream" }
        let bytes = [UInt8](header)

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        } else if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        } else if bytes.count >= 12,
                  bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            if bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                return "image/webp"
            } else if bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
                return "audio/wav"
            }
        } else if bytes.count >= 12,
                  bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return classifyFtyp(bytes)
        } else if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return "video/webm"
        } else if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        } else if bytes.starts(with: [0x49, 0x44, 0x33]) {
            return "audio/mpeg"
        } else if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return "audio/mpeg"
        } else if bytes.count >= 4,
                  bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 0x2A, bytes[3] == 0x00 {
            return "image/tiff"
        } else if bytes.count >= 4,
                  bytes[0] == 0x4D, bytes[1] == 0x4D, bytes[2] == 0x00, bytes[3] == 0x2A {
            return "image/tiff"
        } else if bytes.starts(with: [0x42, 0x4D]) {
            return "image/bmp"
        } else if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return "audio/flac"
        } else if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            return "audio/ogg"
        } else if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "application/zip"
        } else if bytes.starts(with: [0x1F, 0x8B]) {
            return "application/gzip"
        }
        return "application/octet-stream"
    }

    // Classify an ftyp box by scanning major brand + all compatible brands
    private nonisolated func classifyFtyp(_ bytes: [UInt8]) -> String {
        // ftyp box size is at bytes 0-3 (big-endian)
        let boxSize = min(
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]),
            bytes.count
        )

        // Collect all 4-byte brand strings: major brand @ 8, compatible brands @ 16,20,24...
        var brands: [String] = []
        // Major brand at offset 8
        if boxSize >= 12 {
            brands.append(String(bytes: bytes[8..<12], encoding: .ascii) ?? "")
        }
        // Compatible brands start at offset 16 (after 4-byte minor version)
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? "")
            offset += 4
        }

        let brandSet = Set(brands)

        // Check most specific first
        if brandSet.contains("avif") || brandSet.contains("avis") {
            return "image/avif"
        }
        if brandSet.contains("heic") || brandSet.contains("heix") {
            return "image/heic"
        }
        // Check QuickTime brand BEFORE HEVC - macOS screen recordings use HEVC in MOV container
        if brandSet.contains("qt  ") {
            return "video/quicktime"
        }
        if brandSet.contains("hevc") || brandSet.contains("hev1") || brandSet.contains("hvc1") {
            return "video/mp4"
        }
        return "video/mp4"
    }

    // Fetch MIME type from the running relay via HEAD request (the "claim")
    nonisolated func fetchMimeFromRelay(config: HavenConfig, sha256: String) async -> String? {
        guard let url = URL(string: "\(config.webURL)/\(sha256)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await TLSSkipSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                // Strip parameters (e.g. "image/jpeg; charset=utf-8" → "image/jpeg")
                return ct.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            }
        } catch {
            // Silently ignore timeout/connection issues
        }
        return nil
    }

    // Resolve claim (relay) vs proof (magic bytes) using trust-but-verify
    nonisolated func resolveMime(claim: String?, proof: String) -> String {
        guard let claim = claim else { return proof }
        if claim == proof { return claim }

        // octet-stream from bytes means we couldn't identify it — trust the relay
        if proof == "application/octet-stream" { return claim }

        // Check if proof allows claim as a valid refinement
        if let allowed = mimeSubsetRules[proof] {
            if allowed.isEmpty || allowed.contains(claim) {
                return claim
            }
        }

        // Same broad category (e.g. both video/*, both image/*) — trust relay
        let proofType = proof.components(separatedBy: "/").first
        let claimType = claim.components(separatedBy: "/").first
        if proofType == claimType { return claim }

        // Hard mismatch — trust the bytes
        return proof
    }

    // Convert MIME type to file extension
    nonisolated func mimeToExtension(_ mime: String) -> String {
        if let utType = UTType(mimeType: mime),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        return Self.extensionFallbacks[mime] ?? "bin"
    }
}

// Broad MIME types that allow more specific refinements from relay metadata
private let mimeSubsetRules: [String: Set<String>] = [
    "application/zip": [
        "application/vnd.android.package-archive",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/java-archive",
    ],
    "video/mp4": [
        "audio/mp4", "audio/x-m4a", "audio/aac",
    ],
    "application/octet-stream": [], // empty set = allow anything
]

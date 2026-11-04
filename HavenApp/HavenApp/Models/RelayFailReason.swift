import Foundation

/// Why a relay didn't connect, in a few plain words for the Relays page
/// (Logen 2026-11-04, from the NDK check: show the real reason, not just
/// "not answering"). Twin of Android `RelayFailReason.kt`.
enum RelayFailReason {
    /// The probe's own wait ran out (RelayProbe.timeout).
    static func noAnswer(after seconds: TimeInterval) -> String { "no answer in \(Int(seconds)) s" }

    /// `httpStatus`: what the server answered the WebSocket upgrade with, if
    /// it answered at all. `urlErrorCode`: the NSURLErrorDomain code.
    static func text(httpStatus: Int?, urlErrorCode: Int?) -> String {
        if let status = httpStatus, status != 101, status > 0 {
            switch status {
            case 401, 403: return "refused (HTTP \(status))"
            case 404: return "no relay at this address (HTTP 404)"
            case 429: return "rate-limited (HTTP 429)"
            case 200...299: return "not a relay (answered with a web page)"
            case 500...599: return "server error (HTTP \(status))"
            default: return "HTTP \(status)"
            }
        }
        switch urlErrorCode {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "no such host"
        case NSURLErrorCannotConnectToHost: return "connection refused"
        case NSURLErrorTimedOut: return "timed out"
        case NSURLErrorNotConnectedToInternet: return "you're offline"
        case NSURLErrorNetworkConnectionLost: return "connection dropped"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "certificate problem"
        case NSURLErrorBadServerResponse: return "bad answer from the server"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "not a relay address"
        default: return "not answering"
        }
    }

    /// The reason for a failed probe: the HTTP answer when there was one, else the error.
    static func text(response: URLResponse?, error: Error) -> String {
        let ns = error as NSError
        return text(httpStatus: (response as? HTTPURLResponse)?.statusCode,
                    urlErrorCode: ns.domain == NSURLErrorDomain ? ns.code : nil)
    }
}

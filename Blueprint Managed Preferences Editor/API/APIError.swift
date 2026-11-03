import Foundation

/// The app's own errors. Errors from Jamf come as JTKit's `JamfPlatform.APIError`,
/// in the format every app shows: the HTTP status line, one
/// `CODE (field): description` line per error, the Trace ID and hints.
nonisolated enum APIError: Error, LocalizedError, Sendable {
    case missingCredentials
    /// Stop during a wait before a retry, while one Blueprint was read.
    case stoppedWaiting

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No complete connection is configured. Open Settings and add a region, Environment ID, Client ID and Client Secret."
        case .stoppedWaiting:
            return "You stopped waiting for Jamf, so the Blueprint wasn’t loaded."
        }
    }
}

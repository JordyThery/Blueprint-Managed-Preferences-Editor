import Foundation

/// The app's own errors. Errors from Jamf come as JTKit's `JamfPlatformError`,
/// in the format every app shows: the HTTP status line, one
/// `CODE (field): description` line per error, the Trace ID and hints.
nonisolated enum APIError: Error, LocalizedError, Sendable {
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No complete connection is configured. Open Settings and add a region, Environment ID, Client ID and Client Secret."
        }
    }
}

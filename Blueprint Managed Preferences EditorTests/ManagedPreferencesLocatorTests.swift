import Foundation
import JTKit
import Testing
@testable import Blueprint_Managed_Preferences_Editor

@Suite("Managed Preferences discovery")
struct ManagedPreferencesLocatorTests {
    @Test func findsPayloadAtExpectedLocation() throws {
        let detail = try JamfPlatform.BlueprintDetail(data: Data(sampleBlueprintJSON.utf8))
        #expect(detail.containsManagedPreferences)
        let location = try #require(detail.managedPreferencePayloads.first)
        #expect(location.path.pathString == "steps[0].components[1].configuration.payloadContent[0]")
        #expect(location.payloadDisplayName == "MAU")
        #expect(location.domains == ["com.microsoft.autoupdate2", "com.example.other"])
        #expect(location.shapeWarnings.isEmpty)
        #expect(detail.overview.deploymentState?.state == .deployed)
        #expect(detail.overview.updated == "2026-09-30T14:02:11.987654Z")
        #expect(detail.rawData == Data(sampleBlueprintJSON.utf8))
    }

    @Test func findsPayloadInUnexpectedShapeWithWarnings() throws {
        let json = #"{"id":"x","steps":[{"components":[{"identifier":"other","configuration":{"payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","PayloadContent":["not","an","object"]}]}}]}]}"#
        let detail = try JamfPlatform.BlueprintDetail(data: Data(json.utf8))
        let location = try #require(detail.managedPreferencePayloads.first)
        #expect(location.domains.isEmpty)
        #expect(location.shapeWarnings.count == 2)
    }

    @Test func blueprintWithoutPayloadIsNotAMatch() throws {
        let detail = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"x","name":"n","steps":[]}"#.utf8))
        #expect(!detail.containsManagedPreferences)
    }
}

/// Errors from Jamf come as JTKit's `JamfPlatformError`; the app relies on
/// its codes, its Trace ID line and its redaction.
@Suite("API errors")
struct APIErrorTests {
    private func statusError(_ status: Int, _ body: String) -> JamfPlatformError {
        JamfPlatformError(.status(status, body: JamfPlatform.ErrorBody(data: Data(body.utf8)), text: body,
                                  method: "PATCH", path: "/blueprints/v1/blueprints/abc"))
    }

    @Test func readsTheDivisionCodeAndTraceID() {
        let error = statusError(409, #"{"httpStatus":409,"traceId":"abc-123","errors":{"code":"DIVISION_PATCH_NOT_ALLOWED","field":null,"description":"Assigned to a division"}}"#)
        #expect(error.hasCode(.divisionPatchNotAllowed))
        #expect(error.localizedDescription.contains("Trace ID: abc-123"))
        #expect(error.localizedDescription.contains("assigned to a division"))
    }

    @Test func readsAnErrorArray() {
        let error = statusError(400, #"{"httpStatus":400,"errors":[{"code":"A"},{"code":"B","field":"steps"}]}"#)
        #expect(error.body?.errors.map(\.code) == ["A", "B"])
        #expect(error.localizedDescription.contains("B (steps)"))
    }

    /// Error messages shown to the user go through JTKit's redaction.
    @Test func errorMessagesAreRedacted() {
        let error = JamfPlatformError(.status(400, body: nil, text: #"{"message":"bad request","access_token":"tok-123"}"#,
                                              method: "GET", path: "/blueprints/v1/blueprints"))
        #expect(!error.localizedDescription.contains("tok-123"))
        let signIn = JamfPlatformError(.signIn(status: 401, body: nil, text: #"{"client_secret":"s3cr3t"}"#))
        #expect(!signIn.localizedDescription.contains("s3cr3t"))
    }
}

import Foundation
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// A blueprint detail in compact form, exactly as this app's serializer writes it.
/// Includes the DDM component with fields the app must never touch, mixed number
/// literals, unicode and escapes.
let sampleBlueprintJSON = #"{"id":"6f0c1e2a-0000-4000-8000-000000000001","name":"Microsoft AutoUpdate – Legacy","description":"Migrated from \"Classic\" profile","created":"2025-11-02T09:15:00.123Z","updated":"2026-09-30T14:02:11.987654Z","deploymentState":{"state":"DEPLOYED","lastDeployment":{"started":"2026-09-30T14:03:00Z","state":"SUCCEEDED"}},"scope":{"deviceGroups":["a1","b2"]},"steps":[{"name":"Step 1","activationPredicate":null,"components":[{"identifier":"com.jamf.ddm.passcode","configuration":{"minLength":6,"ratio":1.0,"big":12345678901234567890123,"exp":1e5,"neg":-0,"enabled":true,"tags":[],"meta":{}}},{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadDisplayName":"MAU","payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","PayloadContent":{"com.microsoft.autoupdate2":{"Forced":[{"mcx_preference_settings":{"HowToCheck":"AutomaticDownload","UpdateCheckFrequency":720,"EnableCheckForUpdatesButton":false,"Ratio":0.5,"Channels":["Production","Preview"],"Nested":{"a":"é😀/","b":"line\nbreak"}}}]},"com.example.other":{"Set-Once":[{"mcx_data_timestamp":"2024-01-01T00:00:00Z","mcx_preference_settings":{"Key":"Value"}}]}}}]}}]}]}"#

@Suite("JSONValue round trip")
struct JSONValueRoundTripTests {
    @Test func compactRoundTripIsByteIdentical() throws {
        let data = Data(sampleBlueprintJSON.utf8)
        let parsed = try JSONValue(data: data)
        #expect(parsed.serialized() == data)
    }

    @Test func stepsRoundTripIsByteIdentical() throws {
        let parsed = try JSONValue(string: sampleBlueprintJSON)
        let steps = try #require(parsed["steps"])
        let stepsData = steps.serialized()
        // Steps re-parsed and re-serialized are unchanged.
        #expect(try JSONValue(data: stepsData).serialized() == stepsData)
        // The steps bytes appear verbatim in the original document.
        #expect(sampleBlueprintJSON.contains(String(decoding: stepsData, as: UTF8.self)))
    }

    @Test func prettyAndCompactProduceSameTree() throws {
        let compact = try JSONValue(string: sampleBlueprintJSON)
        let pretty = try JSONValue(data: compact.serialized(pretty: true))
        #expect(pretty == compact)
        #expect(pretty.serialized() == Data(sampleBlueprintJSON.utf8))
    }

    @Test(arguments: ["1.0", "1e5", "1E+5", "-0", "0.1", "12345678901234567890123", "-1.25e-10", "720"])
    func numberLiteralsArePreserved(literal: String) throws {
        let json = "[\(literal)]"
        #expect(try JSONValue(string: json).serializedString() == json)
    }

    @Test func keyOrderAndDuplicateKeysArePreserved() throws {
        let json = #"{"z":1,"a":2,"m":3,"a":4}"#
        let parsed = try JSONValue(string: json)
        #expect(parsed.objectValue?.keys == ["z", "a", "m", "a"])
        #expect(parsed.serializedString() == json)
    }

    @Test func escapesAreDecoded() throws {
        let parsed = try JSONValue(string: #"["\u00e9\n\ud83d\ude00\/\"\\\t"]"#)
        #expect(parsed[0]?.stringValue == "é\n😀/\"\\\t")
        // Only required escapes are written back.
        #expect(parsed.serializedString() == #"["é\n😀/\"\\\t"]"#)
    }

    @Test func controlCharactersAreEscaped() {
        let value = JSONValue.string("a\u{01}b")
        #expect(value.serializedString() == #""a\u0001b""#)
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"unterminated", "tru", "[1] x", "\"\\ud800\""])
    func invalidJSONThrowsInsteadOfCrashing(input: String) {
        #expect(throws: JSONParseError.self) { try JSONValue(string: input) }
    }

    @Test func excessiveNestingThrows() {
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        #expect(throws: JSONParseError.self) { try JSONValue(string: deep) }
    }
}

@Suite("JSONValue editing")
struct JSONValueEditingTests {
    private let settingsPath: [JSONPathComponent] = [
        .key("steps"), .index(0), .key("components"), .index(1), .key("configuration"),
        .key("payloadContent"), .index(0), .key("PayloadContent"), .key("com.microsoft.autoupdate2"),
        .key("Forced"), .index(0), .key("mcx_preference_settings"),
    ]

    @Test func editingOneKeyChangesOnlyThatKey() throws {
        let original = try JSONValue(string: sampleBlueprintJSON)
        var edited = original
        let path = settingsPath + [.key("UpdateCheckFrequency")]
        let didSet = edited.setValue(.number(JSONNumber(240)), at: path)
        #expect(didSet)

        let expected = sampleBlueprintJSON.replacingOccurrences(
            of: #""UpdateCheckFrequency":720"#,
            with: #""UpdateCheckFrequency":240"#
        )
        #expect(edited.serializedString() == expected)
        #expect(edited.value(at: path) == .number(JSONNumber(240)))

        // Every other component is untouched.
        let otherComponent: [JSONPathComponent] = [.key("steps"), .index(0), .key("components"), .index(0)]
        #expect(edited.value(at: otherComponent) == original.value(at: otherComponent))
    }

    @Test func editedKeyKeepsItsPosition() throws {
        var value = try JSONValue(string: #"{"a":1,"b":2,"c":3}"#)
        value.setValue(.string("x"), at: [.key("b")])
        #expect(value.serializedString() == #"{"a":1,"b":"x","c":3}"#)
    }

    @Test func settingThroughAMissingPathFails() throws {
        var value = try JSONValue(string: sampleBlueprintJSON)
        let before = value
        let setMissingIndex = value.setValue(.null, at: [.key("steps"), .index(9), .key("name")])
        let setMissingKey = value.setValue(.null, at: [.key("missing"), .key("deeper")])
        #expect(!setMissingIndex)
        #expect(!setMissingKey)
        #expect(value == before)
    }
}

@Suite("Managed Preferences discovery")
struct ManagedPreferencesLocatorTests {
    @Test func findsPayloadAtExpectedLocation() throws {
        let detail = try BlueprintDetail(data: Data(sampleBlueprintJSON.utf8))
        #expect(detail.containsManagedPreferences)
        let location = try #require(detail.managedPreferencePayloads.first)
        #expect(location.matchesExpectedStructure)
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
        let detail = try BlueprintDetail(data: Data(json.utf8))
        let location = try #require(detail.managedPreferencePayloads.first)
        #expect(!location.matchesExpectedStructure)
        #expect(location.domains.isEmpty)
        #expect(location.shapeWarnings.count == 2)
    }

    @Test func blueprintWithoutPayloadIsNotAMatch() throws {
        let detail = try BlueprintDetail(data: Data(#"{"id":"x","name":"n","steps":[]}"#.utf8))
        #expect(!detail.containsManagedPreferences)
    }
}

@Suite("API errors")
struct APIErrorTests {
    @Test func parsesErrorObject() throws {
        let body = #"{"httpStatus":409,"traceId":"abc-123","errors":{"code":"DIVISION_PATCH_NOT_ALLOWED","field":null,"description":"Assigned to a division"}}"#
        let details = try #require(PlatformErrorDetails(data: Data(body.utf8)))
        #expect(details.traceId == "abc-123")
        #expect(details.contains(code: "DIVISION_PATCH_NOT_ALLOWED"))
        let error = APIError.http(status: 409, details: details, body: body)
        #expect(error.hasErrorCode("DIVISION_PATCH_NOT_ALLOWED"))
        #expect(error.localizedDescription.contains("abc-123"))
    }

    @Test func parsesErrorArray() throws {
        let body = #"{"httpStatus":400,"errors":[{"code":"A"},{"code":"B","field":"steps"}]}"#
        let details = try #require(PlatformErrorDetails(data: Data(body.utf8)))
        #expect(details.errors.map(\.code) == ["A", "B"])
    }

    @Test func redactsSecrets() {
        #expect(LogRedactor.formBody("grant_type=client_credentials&client_id=id&client_secret=s3cr3t")
            == "grant_type=client_credentials&client_id=id&client_secret=<redacted>")
        let body = LogRedactor.body(Data(#"{"access_token":"tok","expires_in":900}"#.utf8)) ?? ""
        #expect(!body.contains("tok\""))
        #expect(body.contains("<redacted>"))
        let headers = LogRedactor.headers(["Authorization": "Bearer abc"])
        #expect(headers.first?.1 == "Bearer <redacted>")
    }
}

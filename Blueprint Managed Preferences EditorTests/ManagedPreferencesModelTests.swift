import Foundation
import Testing
@testable import Blueprint_Managed_Preferences_Editor

private func document(_ json: String) throws -> BlueprintEditDocument {
    BlueprintEditDocument(detail: try BlueprintDetail(data: Data(json.utf8)))
}

/// Extracts the exact `"steps":[...]` bytes from a compact response.
private func rawSteps(of json: String) throws -> String {
    let value = try JSONValue(string: json)
    let steps = try #require(value["steps"]).serializedString()
    #expect(json.contains("\"steps\":" + steps))
    return steps
}

@Suite("Blueprint fixture round trip")
struct BlueprintFixtureRoundTripTests {
    @Test(arguments: [selfServiceBlueprintJSON, emailBlueprintJSON, rosettaBlueprintJSON, sampleBlueprintJSON])
    func unchangedDocumentProducesByteIdenticalSteps(json: String) throws {
        let doc = try document(json)
        #expect(!doc.hasChanges)
        let steps = try #require(doc.updatedSteps)
        #expect(steps.serializedString() == (try rawSteps(of: json)))
        // The whole document is byte-identical too.
        #expect(doc.updatedBlueprintJSON.serialized() == Data(json.utf8))
        #expect(doc.changes.isEmpty)
    }

    @Test func patchBodyContainsOnlySteps() throws {
        let doc = try document(emailBlueprintJSON)
        let body = try JSONValue(data: try #require(doc.patchBody))
        #expect(body.objectValue?.keys == ["steps"])
        #expect(String(decoding: try #require(doc.patchBody), as: UTF8.self) == "{\"steps\":\(try rawSteps(of: emailBlueprintJSON))}")
    }

    @Test func parsesRealShape() throws {
        let doc = try document(emailBlueprintJSON)
        #expect(doc.payloads.count == 2)
        #expect(doc.payloads.map(\.isEditable) == [true, true])
        #expect(doc.payloads.flatMap(\.domains).map(\.name) == ["com.microsoft.office", "com.microsoft.Outlook"])
        let office = try #require(doc.payloads[0].domains.first?.entries?.first)
        #expect(office.mode == "Forced")
        #expect(office.settings.map(\.key) == ["OfficeAutoSignIn", "OfficeActivationEmailAddress"])
        #expect(office.settings[0].value == .boolean(true))
        #expect(office.settings[1].value == .string("$EMAIL"))
    }
}

@Suite("Editing")
struct EditingTests {
    @Test func editingOneKeyChangesOnlyThatKey() throws {
        var doc = try document(emailBlueprintJSON)
        let domain = try #require(doc.payloads[1].domains.first)
        let entry = try #require(domain.entries?.first)
        let nodeID = try #require(entry.settings.first { $0.key == "DefaultEmailAddressOrDomain" }?.id)

        doc.modifySettings(domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .string("example.com") }
        }

        let expected = try rawSteps(of: emailBlueprintJSON).replacingOccurrences(
            of: #""DefaultEmailAddressOrDomain":"$EMAIL""#,
            with: #""DefaultEmailAddressOrDomain":"example.com""#
        )
        #expect(doc.updatedSteps?.serializedString() == expected)
        #expect(doc.hasChanges)

        let changes = doc.changes
        #expect(changes.count == 1)
        #expect(changes.first?.domain == "com.microsoft.Outlook")
        #expect(changes.first?.keyPath == "Forced › DefaultEmailAddressOrDomain")
        #expect(changes.first?.oldValue == #""$EMAIL""#)
        #expect(changes.first?.newValue == #""example.com""#)
    }

    @Test func revertingAnEditRestoresOriginalBytes() throws {
        var doc = try document(rosettaBlueprintJSON)
        let domain = try #require(doc.payloads.first?.domains.first)
        let entry = try #require(domain.entries?.first)
        let nodeID = try #require(entry.settings.first?.id)
        doc.modifySettings(domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .boolean(true) }
        }
        #expect(doc.hasChanges)
        doc.modifySettings(domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .boolean(false) }
        }
        #expect(!doc.hasChanges)
        #expect(doc.updatedBlueprintJSON.serialized() == Data(rosettaBlueprintJSON.utf8))
    }

    @Test func nestedEditChangesOnlyNestedValue() throws {
        var doc = try document(selfServiceBlueprintJSON)
        let domain = try #require(doc.payloads.first?.domains.first)
        let entry = try #require(domain.entries?.first)
        guard case .dictionary(let configs) = try #require(entry.settings.first).value,
              case .dictionary(let connect) = try #require(configs.first).value,
              case .dictionary(let leafs) = try #require(connect.first).value else {
            Issue.record("Unexpected shape")
            return
        }
        let leafID = try #require(leafs.first?.id)
        doc.modifySettings(domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: leafID) { $0.value = .boolean(false) }
        }
        #expect(doc.updatedSteps?.serializedString() == (try rawSteps(of: selfServiceBlueprintJSON)).replacingOccurrences(
            of: #""HideMenubarIcon":true"#, with: #""HideMenubarIcon":false"#
        ))
        #expect(doc.changes.map(\.keyPath) == ["Forced › blueprint › configs › connect › HideMenubarIcon"])
    }

    @Test func domainRenameModeSwitchAndAdd() throws {
        var doc = try document(rosettaBlueprintJSON)
        let domain = try #require(doc.payloads.first?.domains.first)
        let entry = try #require(domain.entries?.first)

        doc.modifyDomain(withID: domain.id) { $0.name = "com.apple.applicationaccess.new" }
        doc.modifyDomain(withID: domain.id) { domain in
            guard case .entries(var entries) = domain.content else { return }
            entries[0].mode = "Set-Once"
            domain.content = .entries(entries)
        }
        doc.payloads[0].domains.append(.new(name: "com.example.added", settings: [PlistNode(key: "A", value: .integer(JSONNumber(1)))]))

        let content = try #require(doc.updatedBlueprintJSON.value(at: doc.payloads[0].path + [.key("PayloadContent")]))
        #expect(content.serializedString() == #"{"com.apple.applicationaccess.new":{"Set-Once":[{"mcx_preference_settings":{"allowRosettaUsageAwareness":false}}]},"com.example.added":{"Forced":[{"mcx_preference_settings":{"A":1}}]}}"#)
        // Everything outside PayloadContent is unchanged.
        var restored = doc.updatedBlueprintJSON
        restored.setValue(try #require(doc.base.json.value(at: doc.payloads[0].path + [.key("PayloadContent")])), at: doc.payloads[0].path + [.key("PayloadContent")])
        #expect(restored == doc.base.json)
        _ = entry
    }

    @Test func extraItemKeysAndModesArePreserved() throws {
        // sampleBlueprintJSON has a Set-Once item with mcx_data_timestamp before the settings.
        var doc = try document(sampleBlueprintJSON)
        let domain = try #require(doc.payloads.first?.domains.first { $0.name == "com.example.other" })
        let entry = try #require(domain.entries?.first)
        #expect(entry.mode == "Set-Once")
        doc.modifySettings(domainID: domain.id, entryID: entry.id) { nodes in
            nodes.append(PlistNode(key: "New", value: .string("x")))
        }
        let expected = sampleBlueprintJSON.replacingOccurrences(
            of: #""mcx_data_timestamp":"2024-01-01T00:00:00Z","mcx_preference_settings":{"Key":"Value"}"#,
            with: #""mcx_data_timestamp":"2024-01-01T00:00:00Z","mcx_preference_settings":{"Key":"Value","New":"x"}"#
        )
        #expect(doc.updatedBlueprintJSON.serializedString() == expected)
    }

    @Test func unsupportedDomainShapeIsKeptVerbatim() throws {
        let json = #"{"id":"x","steps":[{"components":[{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","PayloadContent":{"weird":{"Forced":"not-an-array"},"ok":{"Forced":[{"mcx_preference_settings":{"a":1}}]}}}]}}]}]}"#
        let doc = try document(json)
        let domains = try #require(doc.payloads.first?.domains)
        #expect(!domains[0].isEditable)
        #expect(domains[1].isEditable)
        #expect(doc.updatedBlueprintJSON.serializedString() == json)
    }
}

@Suite("Plist values")
struct PlistValueTests {
    @Test func inferenceOnLoad() throws {
        let value = PlistValue(json: try JSONValue(string: #"{"s":"a","i":1000,"r":0.5,"b":true,"d":"2024-01-01T00:00:00Z","a":[1],"n":null}"#))
        guard case .dictionary(let nodes) = value else { Issue.record(); return }
        #expect(nodes.map(\.value.type) == [.string, .integer, .real, .boolean, .string, .array, nil])
    }

    @Test func validation() {
        #expect(PlistParsing.value(from: "42", as: .integer) == .success(.integer(JSONNumber(42))))
        #expect(PlistParsing.value(from: "007", as: .integer) == .success(.integer(JSONNumber(7))))
        #expect((try? PlistParsing.value(from: "4.2", as: .integer).get()) == nil)
        #expect(PlistParsing.value(from: "5", as: .real) == .success(.real(JSONNumber(literal: "5.0"))))
        #expect(PlistParsing.value(from: "2.50", as: .real) == .success(.real(JSONNumber(literal: "2.50"))))
        #expect((try? PlistParsing.value(from: "abc", as: .real).get()) == nil)
        #expect(PlistParsing.value(from: "2026-01-31T09:00:00Z", as: .date) == .success(.date("2026-01-31T09:00:00Z")))
        #expect((try? PlistParsing.value(from: "31/01/2026", as: .date).get()) == nil)
        #expect(PlistParsing.value(from: "aGVsbG8=", as: .data) == .success(.data("aGVsbG8=")))
        #expect((try? PlistParsing.value(from: "not base64!", as: .data).get()) == nil)
    }

    @Test func dateAndDataTravelAsStrings() {
        let nodes: [PlistNode] = [
            PlistNode(key: "When", value: .date("2026-01-31T09:00:00Z")),
            PlistNode(key: "Blob", value: .data("aGVsbG8=")),
        ]
        #expect(JSONValue.object(nodes.jsonObject).serializedString() == #"{"When":"2026-01-31T09:00:00Z","Blob":"aGVsbG8="}"#)
    }

    @Test func typeConversion() {
        #expect(PlistValue.string("12").converted(to: .integer) == .integer(JSONNumber(12)))
        #expect(PlistValue.string("x").converted(to: .integer) == .integer(JSONNumber(0)))
        #expect(PlistValue.integer(JSONNumber(1)).converted(to: .boolean) == .boolean(true))
        #expect(PlistValue.string("aGVsbG8=").converted(to: .data) == .data("aGVsbG8="))
        #expect(PlistValue.string("2026-01-31T09:00:00Z").converted(to: .date) == .date("2026-01-31T09:00:00Z"))
        let id = UUID()
        #expect(PlistValue.dictionary([PlistNode(id: id, key: "k", value: .string("v"))]).converted(to: .array)
            == .array([PlistNode(id: id, key: "", value: .string("v"))]))
    }

    @Test func treeOperations() {
        let child = PlistNode(key: "", value: .string("c"))
        let array = PlistNode(key: "list", value: .array([child]))
        let other = PlistNode(key: "other", value: .boolean(false))
        var nodes = [array, other]

        #expect(nodes.location(of: child.id) == PlistNodeLocation(parentID: array.id, index: 0))
        nodes.moveNode(withID: other.id, by: -1)
        #expect(nodes.map(\.key) == ["other", "list"])
        nodes.modifyChildren(of: array.id) { children, isArray in
            #expect(isArray)
            children.append(PlistNode(key: "", value: .string("d")))
        }
        #expect(nodes.node(withID: array.id)?.value.children?.count == 2)
        nodes.removeNodes(withIDs: [child.id])
        #expect(nodes.node(withID: array.id)?.value.children?.map(\.value) == [.string("d")])
        #expect(nodes.uniqueKey(base: "other") == "other 2")
    }
}

@Suite("Import and export")
struct ImportExportTests {
    @Test func plistRoundTripKeepsTypes() throws {
        let nodes: [PlistNode] = [
            PlistNode(key: "Count", value: .integer(JSONNumber(3))),
            PlistNode(key: "Enabled", value: .boolean(true)),
            PlistNode(key: "Ratio", value: .real(JSONNumber(literal: "0.5"))),
            PlistNode(key: "When", value: .date("2026-01-31T09:00:00Z")),
            PlistNode(key: "Blob", value: .data("aGVsbG8=")),
            PlistNode(key: "List", value: .array([PlistNode(key: "", value: .string("a"))])),
        ]
        let data = try PlistExporter.xmlData(for: nodes)
        let imported = try PlistImporter.domains(from: data, fileName: "com.example.app.plist")
        #expect(imported.count == 1)
        #expect(imported[0].name == "com.example.app")
        let byKey = Dictionary(uniqueKeysWithValues: imported[0].settings.map { ($0.key, $0.value) })
        #expect(byKey["Count"] == .integer(JSONNumber(3)))
        #expect(byKey["Enabled"] == .boolean(true))
        #expect(byKey["Ratio"] == .real(JSONNumber(literal: "0.5")))
        #expect(byKey["When"] == .date("2026-01-31T09:00:00Z"))
        #expect(byKey["Blob"] == .data("aGVsbG8="))
        #expect(byKey["List"]?.children?.first?.value == .string("a"))
    }

    @Test func mobileconfigWithManagedClientPayload() throws {
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadContent": [[
                "PayloadType": "com.apple.ManagedClient.preferences",
                "PayloadContent": [
                    "com.microsoft.OneDrive": ["Forced": [["mcx_preference_settings": ["OpenAtLogin": true]]]],
                ],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let imported = try PlistImporter.domains(from: data, fileName: "x.mobileconfig")
        #expect(imported == [ImportedDomain(name: "com.microsoft.OneDrive", mode: "Forced", settings: imported.first?.settings ?? [])])
        #expect(imported.first?.settings.map(\.key) == ["OpenAtLogin"])
    }

    @Test func mobileconfigWithCustomPayload() throws {
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadContent": [["PayloadType": "com.example.app", "PayloadUUID": "X", "Key": "Value"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let imported = try PlistImporter.domains(from: data, fileName: "x.mobileconfig")
        #expect(imported.first?.name == "com.example.app")
        #expect(imported.first?.settings.map(\.key) == ["Key"])
    }
}

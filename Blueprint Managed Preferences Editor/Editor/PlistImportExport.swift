import Foundation
import JTKit
import Security

// MARK: - Foundation property list conversion

nonisolated extension PlistValue {
    /// Converts a Foundation property-list object. Dates become ISO 8601 `.date`
    /// values and Data becomes Base64 `.data`, keeping their types explicit.
    /// Dictionary keys are sorted, since property lists have no key order.
    init(propertyList object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .boolean(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(LosslessJSON.Number(number.doubleValue) ?? LosslessJSON.Number(literal: "0.0"))
                if case .real(let real) = self, real.isInteger {
                    self = .real(LosslessJSON.Number(literal: real.literal + ".0"))
                }
            } else {
                self = .integer(LosslessJSON.Number(literal: String(number.int64Value)))
            }
        case let date as Date:
            self = .date(PlistParsing.isoString(from: date))
        case let data as Data:
            self = .data(data.base64EncodedString())
        case let array as [Any]:
            self = .array(array.map { PlistNode(key: "", value: PlistValue(propertyList: $0)) })
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.keys.sorted().map { key in
                PlistNode(key: key, value: PlistValue(propertyList: dictionary[key]!))
            })
        default:
            self = .string(String(describing: object))
        }
    }

    /// Converts to a Foundation property-list object. Returns nil for `.null`,
    /// which property lists cannot represent.
    var propertyListObject: Any? {
        switch self {
        case .string(let text):
            return text
        case .integer(let number):
            if let int = Int(number.literal) { return NSNumber(value: int) }
            return NSNumber(value: number.doubleValue ?? 0)
        case .real(let number):
            return NSNumber(value: number.doubleValue ?? 0)
        case .boolean(let value):
            return NSNumber(value: value)
        case .date(let text):
            return JamfPlatform.date(from: text) ?? text
        case .data(let text):
            return Data(base64Encoded: text) ?? text
        case .array(let nodes):
            return nodes.compactMap(\.value.propertyListObject)
        case .dictionary(let nodes):
            var dictionary: [String: Any] = [:]
            for node in nodes {
                if let object = node.value.propertyListObject { dictionary[node.key] = object }
            }
            return dictionary
        case .null:
            return nil
        }
    }
}

// MARK: - Import

/// One domain's worth of settings read from a .plist or .mobileconfig.
nonisolated struct ImportedDomain: Sendable, Equatable {
    var name: String
    var mode: String
    var settings: [PlistNode]
}

nonisolated enum PlistImporter {
    struct ImportError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Parses a .plist (one domain named after the file) or a .mobileconfig
    /// (signed or unsigned). From a mobileconfig, Managed Preferences payloads are
    /// unpacked per domain and mode; if there are none, every other payload is
    /// imported as a domain named after its PayloadType, without Payload* keys.
    static func domains(from data: Data, fileName: String) throws -> [ImportedDomain] {
        let root = try propertyList(from: data)
        guard let dictionary = root as? [String: Any] else {
            throw ImportError(message: "The file’s top level is not a dictionary.")
        }

        if dictionary["PayloadType"] as? String == "Configuration",
           let payloads = dictionary["PayloadContent"] as? [[String: Any]] {
            let managed = payloads.filter { $0["PayloadType"] as? String == ManagedPreferencesLocator.payloadType }
            if !managed.isEmpty {
                return managed.flatMap(domainsFromManagedClientPayload)
            }
            return payloads.compactMap { payload in
                guard let type = payload["PayloadType"] as? String else { return nil }
                let settings = payload.filter { !$0.key.hasPrefix("Payload") }
                guard case .dictionary(let nodes) = PlistValue(propertyList: settings) else { return nil }
                return ImportedDomain(name: type, mode: "Forced", settings: nodes)
            }
        }

        if dictionary["PayloadType"] as? String == ManagedPreferencesLocator.payloadType {
            return domainsFromManagedClientPayload(dictionary)
        }

        guard case .dictionary(let nodes) = PlistValue(propertyList: dictionary) else { return [] }
        let name = (fileName as NSString).deletingPathExtension
        return [ImportedDomain(name: name.isEmpty ? "com.example.imported" : name, mode: "Forced", settings: nodes)]
    }

    /// Which imported settings "Replace Settings from File…" uses for one entry.
    enum SettingsMatch: Equatable {
        /// The same domain: with the entry's mode if the file has it.
        case sameDomain(ImportedDomain)
        /// The file has no settings for this domain; its first domain could be
        /// used, but only after asking.
        case otherDomain(ImportedDomain)
        case none
    }

    static func settingsMatch(forDomain name: String, mode: String, in imported: [ImportedDomain]) -> SettingsMatch {
        if let match = imported.first(where: { $0.name == name && $0.mode == mode })
            ?? imported.first(where: { $0.name == name }) {
            return .sameDomain(match)
        }
        return imported.first.map(SettingsMatch.otherDomain) ?? .none
    }

    private static func domainsFromManagedClientPayload(_ payload: [String: Any]) -> [ImportedDomain] {
        guard let content = payload["PayloadContent"] as? [String: Any] else { return [] }
        var result: [ImportedDomain] = []
        for domain in content.keys.sorted() {
            guard let modes = content[domain] as? [String: Any] else { continue }
            for mode in modes.keys.sorted() {
                for item in modes[mode] as? [[String: Any]] ?? [] {
                    let settings = item["mcx_preference_settings"] as? [String: Any] ?? [:]
                    if case .dictionary(let nodes) = PlistValue(propertyList: settings) {
                        result.append(ImportedDomain(name: domain, mode: mode, settings: nodes))
                    }
                }
            }
        }
        return result
    }

    /// Reads XML, binary or CMS-signed property lists.
    static func propertyList(from data: Data) throws -> Any {
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return object
        }
        if let unsigned = cmsContent(of: data),
           let object = try? PropertyListSerialization.propertyList(from: unsigned, format: nil) {
            return object
        }
        throw ImportError(message: "The file is not a property list or configuration profile.")
    }

    /// Extracts the content of a signed (CMS) configuration profile without verifying the signature.
    private static func cmsContent(of data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }
}

// MARK: - Export

nonisolated enum PlistExporter {
    /// Serializes a domain's settings as an XML property list.
    static func xmlData(for settings: [PlistNode]) throws -> Data {
        let object = PlistValue.dictionary(settings).propertyListObject ?? [String: Any]()
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
}

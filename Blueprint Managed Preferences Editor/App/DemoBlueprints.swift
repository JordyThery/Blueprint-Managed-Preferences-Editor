import Foundation
import JTKit

/// The app's own sample Blueprints for demo mode, added to JTKit's demo server
/// next to its six Contoso Blueprints (which have no Managed Preferences).
/// Three migrated profiles with four preference domains: Forced, Set-Once and
/// Often in Microsoft AutoUpdate; a second payload (Outlook) beside it; a
/// nested dictionary and an array in Chrome; plain values in a helpdesk app.
///
/// Written in the form the service stores them (payload UUID = identifier,
/// version, organization and display name present), so they read back as
/// from a tenant. IDs are in JTKit's fake range, addresses on
/// `contoso.example`; a test checks both.
nonisolated enum DemoBlueprints {
    static let microsoft365ID = DemoSamples.uuid(0xb101)
    static let chromeID = DemoSamples.uuid(0xb102)
    static let helpdeskID = DemoSamples.uuid(0xb103)

    static var all: [LosslessJSON.Object] {
        [helpdesk, chrome, microsoft365].compactMap { try? LosslessJSON(string: $0).objectValue }
    }

    // Oldest first: the list shows the newest first.

    static let helpdesk = blueprint(
        id: helpdeskID, name: "Contoso – Helpdesk App (migrated)",
        description: "Support links for the Contoso Helpdesk app. Not deployed yet.",
        groups: [DemoSamples.uuid(0xd601)], created: "2026-10-20T09:12:04.120Z", updated: "2026-10-20T09:12:04.120Z",
        deployment: #"{"state":"NOT_DEPLOYED"}"#,
        configurationID: DemoSamples.uuid(0xc103), profileName: "Contoso Helpdesk",
        payloads: [payload(
            identifier: "com.contoso.example.helpdesk.settings", name: "Helpdesk",
            content: #"{"com.contoso.example.helpdesk":{"Forced":[{"mcx_preference_settings":{"SupportURL":"https://help.contoso.example","SupportEmail":"helpdesk@contoso.example","ShowStatusMenu":true,"RefreshInterval":15,"WindowOpacity":0.85}}]}}"#)])

    static let chrome = blueprint(
        id: chromeID, name: "Contoso – Chrome (migrated)",
        description: "Browser settings for Design and Engineering. Changed since the last deployment.",
        groups: [DemoSamples.uuid(0xd602), DemoSamples.uuid(0xd603)],
        created: "2026-10-21T14:30:51.008Z", updated: "2026-10-24T08:02:17.440Z",
        deployment: #"{"state":"OUT_OF_DATE","lastDeployment":{"started":"2026-10-22T07:45:00.000Z","state":"SUCCEEDED"}}"#,
        configurationID: DemoSamples.uuid(0xc102), profileName: "Contoso Chrome",
        payloads: [payload(
            identifier: "com.contoso.example.chrome.settings", name: "Chrome",
            content: #"{"com.google.Chrome":{"Forced":[{"mcx_preference_settings":{"HomepageLocation":"https://intranet.contoso.example","HomepageIsNewTabPage":false,"URLBlocklist":["games.contoso.example","file://*"],"ExtensionSettings":{"*":{"installation_mode":"blocked"},"contosoexamplepasswordmanagerext":{"installation_mode":"force_installed","update_url":"https://extensions.contoso.example/update.xml"}},"BrowserSignin":0}}]}}"#)])

    static let microsoft365 = blueprint(
        id: microsoft365ID, name: "Contoso – Microsoft 365 (migrated)",
        description: "Microsoft AutoUpdate and Outlook for every Mac.",
        groups: [DemoSamples.uuid(0xd601)], created: "2026-10-22T10:05:33.271Z", updated: "2026-10-22T10:06:02.915Z",
        deployment: #"{"state":"DEPLOYED","lastDeployment":{"started":"2026-10-22T10:06:02.915Z","state":"SUCCEEDED"}}"#,
        configurationID: DemoSamples.uuid(0xc101), profileName: "Contoso Microsoft 365",
        payloads: [
            payload(
                identifier: "com.contoso.example.microsoft365.autoupdate", name: "Microsoft AutoUpdate",
                content: #"{"com.microsoft.autoupdate2":{"Forced":[{"mcx_preference_settings":{"HowToCheck":"AutomaticDownload","UpdateCheckFrequency":720,"EnableCheckForUpdatesButton":false}}],"Set-Once":[{"mcx_data_timestamp":"2026-10-01T08:00:00Z","mcx_preference_settings":{"AcknowledgedDataCollectionPolicy":"RequiredDataOnly"}}],"Often":[{"mcx_preference_settings":{"StartDaemonOnAppLaunch":true}}]}}"#),
            payload(
                identifier: "com.contoso.example.microsoft365.outlook", name: "Outlook",
                content: #"{"com.microsoft.Outlook":{"Forced":[{"mcx_preference_settings":{"OfficeAutoSignIn":true,"DefaultEmailAddressOrDomain":"contoso.example","HideFoldersOnMyComputerRootInFolderList":true,"WeeksToSync":12}}]}}"#),
        ])

    // MARK: Building blocks, compact JSON in the service's key order

    private static func payload(identifier: String, name: String, content: String) -> String {
        #"{"payloadType":"com.apple.ManagedClient.preferences","payloadUUID":"\#(identifier)","PayloadContent":\#(content),"payloadVersion":1,"payloadIdentifier":"\#(identifier)","payloadDisplayName":"\#(name)","payloadOrganization":"Contoso"}"#
    }

    private static func blueprint(
        id: String, name: String, description: String, groups: [String], created: String, updated: String,
        deployment: String, configurationID: String, profileName: String, payloads: [String]
    ) -> String {
        let scope = groups.map { #""\#($0)""# }.joined(separator: ",")
        return #"{"id":"\#(id)","name":"\#(name)","description":"\#(description)","scope":{"deviceGroups":[\#(scope)]},"created":"\#(created)","updated":"\#(updated)","deploymentState":\#(deployment),"steps":[{"name":"Migrated classic configuration profile","components":[{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadUUID":"\#(configurationID)","payloadContent":[\#(payloads.joined(separator: ","))],"payloadIdentifier":"\#(configurationID)","payloadDisplayName":"\#(profileName)"}}],"activationPredicate":null}]}"#
    }
}

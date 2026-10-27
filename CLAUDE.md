# Blueprint Managed Preferences Editor: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app does

A macOS app for Jamf Pro admins. When Jamf Pro turns a classic profile with an Application & Custom Settings payload into a Blueprint, that payload becomes a legacy Managed Preferences payload (`com.apple.ManagedClient.preferences`) that the Jamf UI shows but can't edit. This app finds every Blueprint with such a payload, edits it in a plist outline editor, and saves it back through the Jamf Platform API. Deploying is a separate, explicit step.

## How to work on it

- App-only work: open `Blueprint Managed Preferences Editor.xcodeproj`. Its notes load there and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Build releases from the app's own project. Never have the app open in both the project and the workspace.
- The project, scheme, target and folders have spaces in their names: quote paths in shell commands.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- The repo is public: no credentials, Environment IDs, tenant names or real Blueprint content in commits, tests or fixtures (the test fixtures are anonymised; keep them that way).

## Architecture

- `App/AppModel`: connections, Blueprint discovery, the backup folder, the JTKit client for the active connection. `App/AboutInfo`: About (no acknowledgements: no third-party code).
- `Blueprints/ManagedPreferencesLocator`: finds payloads by `payloadType` anywhere in the Blueprint JSON, without assuming the shape, and reports shape warnings. Expected place: `steps[i].components[j].configuration.payloadContent[k]` in a `com.jamf.ddm-configuration-profile` component. It accepts both `payloadType`/`PayloadType` and `PayloadContent`/`payloadContent`. `BlueprintDetail+ManagedPreferences`: domains and scope text.
- `Blueprints/BackupStore`: backups.
- `Editor/`: `EditorModel` (undo, save, deploy, restore), `ManagedPreferencesModel` (payload to domains and back; Forced / Set-Once / Often), `PlistModel` (types, validation), `PlistImportExport` (`.plist`, signed or unsigned `.mobileconfig`, pasted text).
- `Core/LosslessJSON+App`: the few JSON helpers JTKit lacks (tree search, type names, number conversions for plists).
- `API/`: `RequestAllowList` and `PlatformAPIClient` (builds JTKit's client with the app's allow-list and hint); `APIError`.
- `Connection/`: `ConnectionProfile`, `ProfileStore` (on JTKit's `ConnectionStore`).
- `ContentView.swift` and `Views/`: SwiftUI (sidebar, Blueprint column, domain editor, plist outline, review, restore, raw JSON).
- Demo mode (ROADMAP step 10): `AppModel.demo` is JTKit's `DemoMode`, saved under `demoMode`. In demo mode `currentClient()` uses JTKit's demo connection ("Contoso (Demo)") with the app's allow-list; the first demo client adds `App/DemoBlueprints` (three Contoso Blueprints with Managed Preferences, in the service's stored form) to JTKit's demo server. `backupRoot` is then the demo's temporary folder; Restore and Show in Finder read `backupRoot` too. Test Connection always uses the real connection and network. Unsaved edits ask before demo mode is switched (`asksBeforeSwitching` + `confirmsDemoModeSwitch`) and before a saved connection is chosen from it. `AppModel.forLaunch()` handles `-JTKitSandbox` (in-memory connections, no update check).

From JTKit: `JamfPlatform` (client, Blueprints list/get/PATCH steps/deploy, error format, `PermissionProblem`, environments), `LosslessJSON`, `JamfRegion`, `RequestRecorder` + `ActivityLog` + `ActivityLogWindow`, `ConnectionStore` + `KeychainSecretStore` + `ConnectionsSettingsTab` + `ConnectionPicker` + `ConnectionCommands`, `AboutWindow`, `SettingsWindow`, `UpdateChecker` + `AppInfoCommands`. Tests use `JTKitTestSupport` (`MockServer`).

App-specific (stays here): the locator, editor, plist model, import/export, backups and allow-list.

Extend JTKit instead of adding another copy. If another app needs one of the `LosslessJSON+App` helpers, move it to JTKit (via the workspace).

**Stored data, never rename:** UserDefaults `connectionProfiles` and `selectedConnectionProfileID`; `ConnectionProfile` field names; region values `us`/`eu`/`apac`; Keychain service `Blueprint Managed Preferences Editor.client-secret`, account = profile UUID; backups in `~/Library/Application Support/Blueprint Managed Preferences Editor/Backups/<blueprint ID>/`.

## Saving: rules

- **Only the edited payload may change.** The Blueprints API applies PATCH as a JSON merge-patch, which replaces arrays wholesale, so every save sends the complete `steps` array and nothing else. Everything except the edited Managed Preferences goes back byte for byte (`LosslessJSON` keeps key order and number text). Never reformat, re-sort or "clean up" JSON. The tests `savingOneEditedPayloadSendsEverythingElseBackByteForByte` (mock server) and `…InDemoMode` (JTKit's demo server) guard this; keep both passing.
- **Save:** fetch again, check the Blueprint is unchanged since it was loaded (`updated`), back up, PATCH steps, reload. If it changed on the server, save nothing and warn.
- **Restore:** the same check, then a fresh backup of the current state, then PATCH the backup's steps.
- **A backup is written before every save and every restore.** Backups are never overwritten: write with `.withoutOverwriting` only (Foundation on macOS 27 traps when it is combined with `.atomic`). The Restore list sorts names numerically without ".json", so same-millisecond "-2" … "-10" backups list in order.
- Never send `divisionId`. A division-locked Blueprint is read-only from the start.
- The allow-list permits only GET, `POST /auth/token`, Blueprint PATCH and deploy. No create, delete or undeploy. Don't widen it without Jordy.
- Request bodies are never recorded in the activity log (JTKit's default, no opt-in), because Managed Preferences can contain licence keys and tokens. Responses are recorded only on errors, redacted.
- Deploy is a separate step with a confirmation showing the Blueprint name and scope (also "Save & Deploy"). Deploy only starts the deployment; the app doesn't watch it.
- Payloads or domains with an unexpected shape are shown read-only and saved back unchanged.
- Clear the undo history whenever an editor is discarded (switching connection, refresh): stale undo actions crashed the app before.

## Known behaviour

- JSON has no Date or Data type: they are sent as ISO 8601 and Base64 strings and load back as String.
- Scope is shown as device group IDs; the app doesn't read device groups (no `device-groups` permission needed).
- After a save, a deployed Blueprint shows Out of Date until it is deployed again.
- Required API client permissions: `blueprints:read`, `blueprints:update`, `blueprints:deploy`. Test Connection names a missing `blueprints:read`; write permissions can't be checked without writing.

## Testing

- **Unit tests** (Swift Testing, `Blueprint Managed Preferences EditorTests`): scheme `Blueprint Managed Preferences Editor`, ⌘U. No real network: JTKit's `MockServer`. Suites cover the allow-list and client, saving (byte-for-byte, conflict, division lock, permission message), the locator, the plist model and import/export, backups (on a temporary folder), saved connections, About and demo mode (`DemoModeTests`: saving, restore and deploy on the demo server, nothing saved read, Test Connection real, the picker, the unsaved-edits question, sample data clearly fake).
- There is no UI test target yet.
- **Release check:** `Scripts/release-check.sh` comes with ROADMAP step 11 (not in this repo yet): own-project build against the published JTKit, unit tests, UI smoke tests in demo mode, and required live checks against sandbox tenants. Tenants come only from the local allow-list outside git. Never name a tenant in this repo.

## Releasing

1. Set the version (`MARKETING_VERSION`, now 1.0.2) and build number (`CURRENT_PROJECT_VERSION`) of the app target.
2. CHANGELOG.md: move "Unreleased" under the new version; short, user-facing bullets. Update README.md if features, permissions or behaviour changed.
3. Build from `Blueprint Managed Preferences Editor.xcodeproj` against the published JTKit. Hardened Runtime stays on; the app is not sandboxed.
4. Jordy does the Developer ID signing and notarisation himself. Zip the notarised app he supplies with `ditto -c -k --keepParent` and attach it to `gh release create`, tagged `vX.Y.Z`.
5. A shields release badge fetched before the release exists stays cached: purge GitHub's camo cache after shields' 5-minute cache has expired.
6. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.

Before any of this, follow the release gate in JTKit/ROADMAP.md.

## Repo conventions

Public MIT repo under github.com/JordyThery, laid out like his other apps (Checkpoint is the model): README with centred `docs/icon.png`, tagline, release/macOS/licence badges, a "Support" section linking buymeacoffee.com/jordythery, and `.github/FUNDING.yml` with `custom: ["https://buymeacoffee.com/jordythery"]`. Bundle IDs start with `be.jordythery.`.

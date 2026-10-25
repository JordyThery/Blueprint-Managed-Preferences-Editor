# Changelog

## Unreleased

- About now comes from JTKit, shared with Jordy's other apps: a window with the version, a short description and a link to the GitHub repository, replacing the standard About panel. It opens only from the app menu and is not listed in the Window menu.
- **Settings › Updates** now holds only the "Check for updates daily" switch; your choice is kept. **Check for Updates…** stays in the app menu, and brings the main window back if it was closed.

## 1.0.2

- Update checker: once a day the app asks GitHub whether a newer release exists and offers the release notes and download. Check manually with **Check for Updates…** in the app menu; turn the daily check off in Settings → Updates.

## 1.0.1

This release contains bugfixes and minor improvements.

- Fixed a potential crash when using Undo after switching connections or refreshing: undo history is now cleared whenever an editor is discarded.
- Blueprints deleted on the server stay listed while they hold unsaved edits, so those edits can still be saved or discarded.
- "Use This Connection" in Settings now warns before discarding unsaved edits, and deleting a connection asks for confirmation.
- Blueprint discovery pages through the full list even when the server returns fewer results per page than requested.
- The review sheet keys its rows per payload, so two payloads with the same display name no longer collide.
- The Raw JSON view leaves the "Pending PATCH Body" tab automatically once the pending changes are saved.
- The blueprint header shows the last deployment time and state again.
- Importing a file that matches the current settings now says so instead of reporting a change.
- Internal cleanup: removed unused code, anonymized test fixtures, and capped the request log's per-entry body size.

## 1.0.0

First release.

- Connect to the Jamf Platform API (US, EU, APAC) with OAuth client credentials; multiple saved connections, secrets in the keychain.
- Discover every blueprint that contains a legacy `com.apple.ManagedClient.preferences` payload.
- Edit preference domains, management modes (Forced, Set-Once, Often) and keys in an outline editor with String, Integer, Real, Boolean, Date, Data, Array and Dictionary types.
- Import from `.plist` and `.mobileconfig` (including signed profiles); export domains as `.plist`.
- Review a per-key diff before saving; save and deploy as separate, explicit actions.
- Optimistic concurrency check, automatic backup before every save, and restore from backup.
- Request log with secrets redacted, and a raw JSON view including the exact PATCH body.

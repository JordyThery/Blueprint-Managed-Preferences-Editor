<p align="center">
  <img src="docs/icon.png" width="128" alt="Blueprint Managed Preferences Editor app icon">
</p>

# Blueprint Managed Preferences Editor

*Edit the Managed Preferences that Jamf Pro’s Blueprint UI can’t.*

[![Latest release](https://img.shields.io/github/v/release/JordyThery/Blueprint-Managed-Preferences-Editor?label=release)](https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor/releases/latest)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## What it does

When Jamf Pro turns a classic configuration profile with an **Application & Custom Settings** payload into a Blueprint, that payload becomes a read-only legacy **Managed Preferences** payload (`com.apple.ManagedClient.preferences`). The Jamf Pro UI shows it but can’t edit it, and points you to the Jamf Platform API instead.

Blueprint Managed Preferences Editor is a macOS app that uses that API for you. It finds every Blueprint with a Managed Preferences payload, lets you edit the payload in an outline editor, and saves your changes back. Deploying stays a separate, explicit step.

![Blueprint Managed Preferences Editor showing the Blueprints that contain Managed Preferences, the preference domain of the selected Blueprint, and its keys in the outline editor](docs/screenshot.png)

## Installation

Download the latest notarized build from [Releases](https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor/releases/latest), unzip it, and move the app to `/Applications`. The app checks for new releases once a day and offers the download; use **Check for Updates…** in the app menu to check right away.

## Features

- **Discovery**: lists every Blueprint that contains Managed Preferences, with its deployment state, last update and preference domains. Search by name, description or domain, switch to **All Blueprints** to see the rest, or use **Fetch by ID** to load one Blueprint you know.
- **Domains**: add, rename and remove preference domains, and switch each one between **Forced**, **Set-Once** and **Often**.
- **Outline editor**: in the style of Xcode’s property list editor, with String, Integer, Real, Boolean, Date, Data, Array and Dictionary types. Add, delete, duplicate, reorder and nest items. Values are validated as you edit.
- **Import and export**: import domains, or replace one domain’s settings, from a `.plist`, a `.mobileconfig` (signed or unsigned) or pasted text, and export any domain as a `.plist`. A file without settings for the domain asks before its other settings are used, and domains with an unexpected shape are left alone.
- **Review before saving**: a diff of old and new values for each domain and key, then **Save** or **Save & Deploy**.
- **Undo and redo** for every edit. Unsaved changes are marked on the window and in the sidebar. **Discard Changes…**, **Reload from Server** and Quit ask before unsaved edits are lost.
- **Multiple connections** to switch between tenants. Changing connections, or a connection’s Environment ID or client ID, clears the Blueprints of the previous one.
- **Demo Mode**: try the app with sample Contoso Blueprints and no Jamf tenant. Turn it on in the connection picker or the Connection menu, or with **Try Demo Mode**. The picker reads “Contoso (Demo)” and window titles end in “— Demo”. Nothing is sent to a tenant and everything resets when the app quits.
- **Settings**: **General** (appearance), **Connections** and **Updates**.
- **Activity log and raw JSON**: every sign-in and API call is logged (Window › Activity Log, ⇧⌘L) with secrets redacted; request contents are never logged. The raw JSON view shows the Blueprint as received (**Pretty** or **Exact Response**) and, with unsaved edits, the **Pending PATCH Body** Save will send, each with **Copy** and **Save…**. Only GET requests, token requests, and Blueprint update and deploy requests are ever sent.

## Saving safely

The Jamf Platform API applies Blueprint updates as a JSON merge-patch, and a merge-patch replaces arrays wholesale. A careless save can therefore delete parts of a Blueprint. The app guards against this:

- **Nothing outside your edit changes.** Every save sends the complete `steps` array, with every step and component exactly as it was received except the Managed Preferences you edited. Unedited content is sent back byte for byte.
- **Concurrent changes are caught.** Just before saving, restoring or deploying, the Blueprint is fetched again. If it changed on the server since you loaded it, nothing is changed or deployed and you’re warned.
- **Every save and restore is backed up first.** The full Blueprint is written to `~/Library/Application Support/Blueprint Managed Preferences Editor/Backups/<Blueprint ID>/` (**Show Backups in Finder**), and **Restore from Backup** puts those steps back.
- **Division-locked Blueprints are left alone.** `divisionId` is never sent. Blueprints assigned to a division are marked read-only.
- **Deployment needs confirmation.** After a save the Blueprint shows *Out of Date* until you deploy it, and deploying asks for confirmation, showing the Blueprint name and its scope.

## Requirements

- macOS 15 or later
- A Jamf Platform API client (US, EU or APAC region) with the `blueprints:read`, `blueprints:update` and `blueprints:deploy` permissions
- Your **Environment ID**: use **Load Environments** in Settings › Connections (organization-scope API clients), or copy it from the integration’s details in Jamf Account.

## Getting started

1. Open **Settings** (⌘,) › **Connections**, add a connection, enter the region, client ID and client secret, choose the Environment ID with **Load Environments** (or paste it), and click **Test Connection**. To look around first, choose **Try Demo Mode** instead.
2. Click **Refresh** (⌘R) to discover Blueprints with Managed Preferences.
3. Select a Blueprint, then a domain, and edit its keys.
4. Click **Save…** (⌘S), review the changes, and save. Deploy when you’re ready.

## Security

- **Credentials** stay on your Mac. Client secrets are stored in the login Keychain; the other connection settings are stored in user defaults.
- **Network**: the app talks only to `{region}.api.jamfcloud.com`, plus one daily request to GitHub asking whether a newer release exists. That request sends nothing else and can be turned off in Settings.
- **Activity log**: kept in memory only, with tokens and secrets redacted. Request contents are never recorded, and responses only when the server reports an error. **Export for Bug Report…** hides serial numbers, emails and device names.
- **Backups** contain the full Blueprint JSON as it was on the server, including any values in its Managed Preferences, such as license keys or tokens, but no Jamf credentials. They are stored unencrypted in your user Library, one per save and restore, and never deleted by the app: remove old ones yourself with **Show Backups in Finder**.
- **No sandbox**: the app is not sandboxed, so backups are written to the exact path above. It runs with the Hardened Runtime.

## Known limitations

- **Date and Data values**: JSON has no Date or Data type, so these are sent as ISO 8601 and Base64 strings. Values you mark as Date or Data load back as String.
- **Scope**: shown as device group IDs. The app doesn’t read device groups, so it needs no `device-groups` permission.
- **Unrecognized payloads**: payloads or domains with an unexpected shape are shown read-only and saved back unchanged.

## Building

Open `Blueprint Managed Preferences Editor.xcodeproj` in Xcode 27 or later and build the `Blueprint Managed Preferences Editor` scheme (⌘R). Run the tests with ⌘U. Depends on [JTKit](https://github.com/JordyThery/JTKit), Jordy’s own shared package; no third-party dependencies.

## Support

If Blueprint Managed Preferences Editor saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)

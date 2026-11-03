# Changelog

## 1.2.0

- When Jamf asks the app to wait before trying a request again, the wait is now shown while Blueprints are read, saved, deployed or restored, and during **Test Connection** and **Load Environments** in Settings, with **Stop** to end it. Each **Stop** ends only the waits shown beside it. A wait lasts at most 60 seconds (it could be two minutes). After Stop, the message says whether anything reached Jamf.
- **Deploy…** now also stops when someone changed the Blueprint’s steps or scope on the server since you loaded it, so a deployment never goes to a scope you didn’t confirm. **Save** and **Restore**, which send only the steps, stop when the steps or the last-updated time changed, and no longer stop for a change of scope alone. The message says what changed.
- While a save, deploy, restore or reload is running, switching the connection or Demo Mode waits until it has finished, with a message saying why, so its backup and its result stay with the connection in use.
- A new **Blueprint** menu holds **Save…** (⌘S), **Save & Deploy…** (⌥⌘S), **Deploy…** (⇧⌘D), **Restore from Backup…** and the domain commands: **New Domain…** (⇧⌘N), **Rename Domain…**, **Remove Domain**, **Import Domains from File…** (⇧⌘I) and **Export Domain…** (⇧⌘E). Each is available when the same action is in the window.
- Results such as “Saved”, “Deployment Started”, “Restored” and import results now appear in the window, beside the Blueprint, instead of in an alert; errors and changes on the server still ask in an alert.
- The main window can be made narrower.
- The domain list’s “Debug” section is now called **Blueprint JSON**, and a domain’s entries are named by their mode (for example “Set-Once”, or “Forced (1 of 2)” when a mode has two).
- A locked Keychain, or one that refuses access, is now reported as a Keychain problem instead of “No complete connection is configured”.
- A Blueprint is marked read-only for a division only when Jamf names a division; an empty division value no longer locks it. A Blueprint whose changes Jamf refuses for a division is still marked read-only.
- After correcting a connection’s region in Settings › Connections, **Test Connection** and **Load Environments** use the stored client secret, without retyping it.
- The Environment ID must be a UUID, as shown in Jamf Account: the connection editor says so under the field, and nothing is sent until it’s corrected.
- Settings no longer has a General tab: the app follows your Mac’s Light or Dark appearance.
- Settings › Connections asks before closing or switching tabs with unsaved connection edits.
- The Activity Log can copy its entries, with or without device identifiers masked.
- Backups are now readable by your user account only. Existing backups stay listed and restorable.
- Deployment state badges and warnings are easier to read, also with Increase Contrast.

## 1.1.0 (2026-10-31)

- **Demo Mode**: try the app without a Jamf tenant. Turn it on in the connection picker or the Connection menu, or with **Try Demo Mode** when no connection is set up. The picker reads "Contoso (Demo)" and every window title ends in "— Demo". Sample Contoso Blueprints with Managed Preferences (Microsoft AutoUpdate with Forced, Set-Once and Often settings, Outlook, Chrome with nested settings and a list, a helpdesk app) can be edited, saved, deployed and restored inside the app; nothing is sent to a tenant, and everything resets when the app quits. Backups made in demo mode go to a temporary folder, never your real Backups folder. Saved connections and Keychain items are never touched, and Test Connection in Settings always uses the real connection. With unsaved edits, turning Demo Mode on or off asks first.
- Fixed: in Demo Mode, the Restore list and **Show Backups in Finder** read your real Backups folder instead of the demo’s temporary one.
- **Deploy…** now reads the Blueprint again first. If it changed on the server since you loaded it (for example a colleague changed its scope), nothing is deployed and you’re asked to reload; the confirmation also says so.
- **Reload from Server** asks before discarding unsaved edits, and **Quit** asks when edits are unsaved or a save, deploy or restore is still running.
- Changing the connection while a save, deploy or restore is running no longer mixes the two connections: the result is shown in the main window, and the old connection’s Blueprint isn’t listed under the new one.
- Editing the active connection’s Environment ID, client ID or region in Settings, or deleting it, now clears the previous tenant’s Blueprints, also with the main window closed. Unsaved edits lost that way are reported.
- **Save & Deploy** reports each step: when deploying fails after a successful save, or reloading fails after it, the message says the save went through, and the saved edits no longer look unsaved.
- Fixed: **New Domain…** could add a second domain with a name already used in the payload, and importing a domain that is read-only because of its unexpected shape added a duplicate the review didn’t show. Both are refused now, and the review lists every change Save would send, a change of key order included.
- Fixed: importing a domain with a management mode it doesn’t have yet (for example Set-Once into a Forced-only domain) overwrote the existing entry; it now adds an entry for that mode.
- **Replace Settings from File…** asks before using the settings of another domain when the file has none for this one.
- **Discard Changes…** goes back to the newest copy read from the server.
- **Fetch Blueprint by ID…** is also in the View menu, next to **Refresh Blueprints** (which is now unavailable without a connection). The New Domain and Rename sheets name their button **Add** or **Rename**, and the icon-only buttons have names for VoiceOver.
- A Managed Preferences payload found outside the Blueprint’s steps is shown read-only, since it can’t be saved.
- Import messages are titled **Imported**, **Nothing Imported** or **Import Failed**, and the Blueprint wording follows Jamf’s ("Blueprint", the division message, "Connected · 3 Blueprints").
- About now comes from JTKit, shared with Jordy’s other apps: a window with the version, a short description and a link to the GitHub repository, replacing the standard About panel. It opens only from the app menu and is not listed in the Window menu.
- **Settings › Updates** now holds only the "Check for updates daily" switch; your choice is kept. **Check for Updates…** stays in the app menu, and brings the main window back if it was closed.
- Fixed: **Deploy…** could throw away unsaved edits. It is now unavailable until the edits are saved, and the "Unsaved changes" note says to save first (**Save & Deploy…** in the review still does both).
- Fixed: **Deploy…** was available on a Blueprint assigned to a division, which can’t be changed through the API. It is now blocked there, like Save.
- Fixed: a new connection made with **+** in Settings › Connections became the active one before it was saved. It now becomes active only once it’s saved with its Environment ID and client ID, and only when no other connection is active; reverting or leaving it blank keeps the selection as it was.

## 1.0.2

- Update checker: once a day the app asks GitHub whether a newer release exists and offers the release notes and download. Check manually with **Check for Updates…** in the app menu; turn the daily check off in Settings › Updates.

## 1.0.1

- Fixed a potential crash when using Undo after switching connections or refreshing: undo history is now cleared whenever an editor is discarded.
- Blueprints deleted on the server stay listed while they hold unsaved edits, so those edits can still be saved or discarded.
- "Use This Connection" in Settings now warns before discarding unsaved edits, and deleting a connection asks for confirmation.
- Blueprint discovery pages through the full list even when the server returns fewer results per page than requested.
- The review sheet keys its rows per payload, so two payloads with the same display name no longer collide.
- The Raw JSON view leaves the "Pending PATCH Body" tab automatically once the pending changes are saved.
- The Blueprint header shows the last deployment time and state again.
- Importing a file that matches the current settings now says so instead of reporting a change.
- Internal cleanup: removed unused code, anonymized test fixtures, and capped the request log’s per-entry body size.

## 1.0.0

First release.

- Connect to the Jamf Platform API (US, EU, APAC) with OAuth client credentials; multiple saved connections, secrets in the keychain.
- Discover every Blueprint that contains a legacy `com.apple.ManagedClient.preferences` payload.
- Edit preference domains, management modes (Forced, Set-Once, Often) and keys in an outline editor with String, Integer, Real, Boolean, Date, Data, Array and Dictionary types.
- Import from `.plist` and `.mobileconfig` (including signed profiles); export domains as `.plist`.
- Review a per-key diff before saving; save and deploy as separate, explicit actions.
- Optimistic concurrency check, automatic backup before every save, and restore from backup.
- Request log with secrets redacted, and a raw JSON view including the exact PATCH body.

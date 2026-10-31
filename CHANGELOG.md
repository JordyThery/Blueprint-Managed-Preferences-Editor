# Changelog

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

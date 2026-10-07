# Changelog

## 1.0.0

First release.

- Connect to the Jamf Platform API (US, EU, APAC) with OAuth client credentials; multiple saved connections, secrets in the keychain.
- Discover every blueprint that contains a legacy `com.apple.ManagedClient.preferences` payload.
- Edit preference domains, management modes (Forced, Set-Once, Often) and keys in an outline editor with String, Integer, Real, Boolean, Date, Data, Array and Dictionary types.
- Import from `.plist` and `.mobileconfig` (including signed profiles); export domains as `.plist`.
- Review a per-key diff before saving; save and deploy as separate, explicit actions.
- Optimistic concurrency check, automatic backup before every save, and restore from backup.
- Request log with secrets redacted, and a raw JSON view including the exact PATCH body.

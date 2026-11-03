# Blueprint Managed Preferences Editor: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Foundation backup-writing trap (Apple):** Foundation on macOS 27 traps when `.withoutOverwriting` is combined with `.atomic`, so backups are written with `.withoutOverwriting` only. Recheck with each macOS update.
- **Blueprint list paging (Jamf):** checked live on 2026-11-03 (`LivePagingTests`, every release check): the Blueprints list (`GET blueprints/v1/blueprints`) sends `totalCount` and no `hasNext`, so JTKit’s list stops by `totalCount`, which matched the Blueprints read page by page. If Jamf starts sending `hasNext`, JTKit lets it win over `totalCount`; the same check then fails when the two disagree. Recheck when Jamf changes the Blueprints API.

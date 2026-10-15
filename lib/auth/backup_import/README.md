# Backup import

Imports are offline and additive. Service type travels with each draft into the
saved configuration; duplicate detection is scoped by region, service type,
normalized address and account. Emby and Jellyfin accounts at the same address
are not interchangeable. Imported identities remain pending until connection
verifies the server; importing never logs in or overwrites existing credentials.

Supported mappings:

| Container | Emby | Jellyfin |
| --- | --- | --- |
| Hills v2 JSON | `isJellyfin: false` or absent | `isJellyfin: true` |
| Rodel common config | `type: "emby"` | `type: "jellyfin"` |
| Rodel native `.rpb` | verified `Config.Type == 3` | not yet mapped |

Other common-config types and unverified native row types are counted as
unsupported, not coerced into Emby. Native `.rpb` Jellyfin support needs a verified
row discriminator and a synthetic regression fixture before it can be enabled.

Encrypted containers still require `BackupImportKeys` supplied by the embedding
application. Common configs can carry their own `_key`; no third-party key is
bundled. Missing keys produce an explicit failure and no writes. Tests use
synthetic keys, accounts and addresses.

# Backup import

Imports are offline and additive. Service type travels with each draft into the
saved configuration; duplicate detection is scoped by region, service type,
normalized address and account. Emby and Jellyfin accounts at the same address
are not interchangeable. Imported identities remain pending until connection
verifies the server; importing never logs in or overwrites existing credentials.

Supported mappings:

| Container | Emby | Jellyfin |
| --- | --- | --- |
| Hills v2/v3 JSON | `isJellyfin: false` or absent | `isJellyfin: true` |
| Rodel common config | `type: "emby"` | `type: "jellyfin"` |
| Rodel native `.rpb` | verified `Config.Type == 3` | not yet mapped |

Other common-config types and unverified native row types are counted as
unsupported, not coerced into Emby. Hills v3 shares the v2 container and
decryption key; its records only add fields (a strict superset), so both
versions parse through the same mapping. Native `.rpb` Jellyfin support needs a verified
row discriminator and a synthetic regression fixture before it can be enabled.

Encrypted containers still require `BackupImportKeys` supplied by the embedding
application. Common configs can carry their own `_key`; no third-party key is
bundled. Missing keys produce an explicit failure and no writes. Tests use
synthetic keys, accounts and addresses.

File reading uses the shared `PickedAppFile.fromXFile` adapter. Android's
file selector supplies an in-memory `XFile.fromData`; passing a stream end
beyond its byte length throws instead of stopping at EOF. Read to EOF and
check the cumulative byte count while consuming the stream. Do not replace
this with an unbounded `readAsBytes` for path-backed files. The regression
coverage in `test/app/file_import_test.dart` uses synthetic backups only.

A file-read fix does not provision decryption keys: the current application
initializes `AuthController.backupImportKeys` with empty keys. Hills imports
therefore still report `decryptionKeyUnavailable` until verified key material
is supplied by the embedding application. A private exported backup must not
be committed as a test fixture.

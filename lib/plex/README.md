# Plex provider

`PlexClient` is a source-scoped `MediaServerClient`. Attach only the selected
server resource token, never a cloud token or device signing key. Its detached
constructor intentionally carries no account authority.

`PlexAuthentication` implements the shared interactive/account contracts. Inject
`readCredential`, `writeCredential`, `deleteCredential` from the owner's credential
store and a `guard` captured by the current authorization transaction. The map
schema preserves `kind` (`device`, `cloud`, `resource`), `deviceId`, `signingKey`
(JSON Ed25519 seed/public key/kid), `accountId`, `accessToken`, `expiresAt`, and
resource `serverId`/`userId`/`homeUserId`. Signing material never enters playback.
The provider does not import resources into the source registry by itself.

The JWK PIN response must be a JWT. A Home switch uses its explicitly returned
scoped token to rediscover resources; it never retries legacy PIN authorization.
Expired cloud tokens refresh with a fresh nonce and an Ed25519 device JWT.

`PlexResolvedPlayback` describes a selected Part. Its `filmTimeline` is only the
full-film mapping. For a universal transcode URL, the shared `timeline` is null,
because that URL plays one Part starting at `partStartPosition`. A consumer must
renegotiate on Part changes and reselect tracks by language: Plex Stream IDs are
Part-specific. T5 owns carrying these fields into the shared execution and IPC
description. PlaybackInfo and the source metadata are not substitutes for a
serialized full playback descriptor. Cleanup by recorded session never creates
a new decision/start request, and lease cleanup retains only the original PMS
origin/token. Source authorization must still be checked around playback commit.

Protocol baseline: official PMS OpenAPI **1.2.3**, fetched 2026-10-11 from
<https://developer.plex.tv/pms/>. This is an API document version, not an observed
server version. The same document specifies JWK/PIN/JWT and nonce refresh, Part
stream selection, universal decision/start, millisecond timeline and BIF preview.
Home switch and signout additionally follow the public `python-plexapi` account
implementation: <https://github.com/pkkid/python-plexapi/blob/master/plexapi/myplex.py>.

`test/plex/fake_plex.dart` fixture v1 implements a separate account/PMS HTTP
service with signature validation, explicit Home/server tokens, controllable
permission failures and owned transcode sessions. `/video/:/transcode/universal/stop`
uses the ordinary client session cleanup convention; it never invokes the admin
terminate-session API. The fake verifies local request, state, isolation and
cleanup behavior. Actual PMS JWT/Home interoperability, ordinary-user transcode
termination, subscriptions, TLS deployments, rendered frames and physical audio
remain unverified until exercised against real services/devices.

Development verification: `flutter test --no-pub test/plex/plex_provider_test.dart`
and `dart analyze lib/plex test/plex`. Full suite, UI wiring and native acceptance
belong to the later workflow tasks and Delivery.

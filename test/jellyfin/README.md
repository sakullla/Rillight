# Jellyfin adapter protocol boundary

`protocol_contract.json` is a reduced, independently extracted route/query/body
oracle from the official stable OpenAPI fetched on 2026-10-11. It records the
full input SHA-256 and `info.version` / `x-jellyfin-version` (`12.2.0`). The fixture
product label `12.2.0-fixture` describes synthetic data; no real Jellyfin instance
or real product build was tested. The adapter is independent of `lib/emby`.

The frozen API uses `/UserViews`, `/UserItems/Resume`, `/Items/{itemId}` and
`/UserPlayedItems/{itemId}`. `/UserFavoriteItems/{itemId}` (POST/DELETE with
`userId`) was added by hand from the same OpenAPI's `MarkFavoriteItem` /
`UnmarkFavoriteItem` operations for the phone favorite toggle; re-extract the
oracle to confirm it against the recorded input. The fake validates routes and allowed parameters and
request body keys against the extracted oracle, and models user state and
separate device playback sessions. Its `resources` map represents session
reservations and ownership, not proof that a real encoder was launched.

## Playback ownership and recovery

Business `PlaybackInfo.playSessionId` is a versioned opaque `jf-play-v1:` handle
containing only the remote session ID and an independent playback device ID.
Consumers must preserve the handle exactly in reports and recovery snapshots.
They must use `ResolvedPlayback.authorization` for all stream requests: the
ordinary catalog session headers intentionally identify a different device.
Every HTTP boundary unpacks the handle and sends only the raw session ID.
Unknown/malformed handles fail closed. They never contain a token or password.

Each negotiation creates a random playback device ID. Its value is present in
the negotiation authorization, the server's untouched stream URL, media resource
authorization, progress, and cleanup. This is needed because Jellyfin's stop
endpoint clears the authenticated *device session* NowPlaying state as well as
killing encoders for the specified device and play session. Reusing the catalog
device would let cancellation of a new preflight affect an older playback.

`reportStopped` and `releasePlayback` coalesce through the same retryable lease.
Preflight release sends only `PlaySessionId`, without an item or position, so it
does not write viewing progress. Normal stop sends the item and actual position.
The lease captures the original source credentials and request guard; changing
user later never substitutes the new user's credentials for cleanup.

Source references were fixed to upstream commit
`a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1`:

- [AuthorizationContext](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs):
  supplied DeviceId is retained; token still determines the authorized user.
- [RequestHelpers](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Jellyfin.Api/Helpers/RequestHelpers.cs):
  device/client/user determines the session used by playback reporting.
- [PlaystateController](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Jellyfin.Api/Controllers/PlaystateController.cs):
  `ReportPlaybackStopped` awaits device + PlaySessionId scoped encoder cleanup.
- [SessionManager](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Emby.Server.Implementations/Session/SessionManager.cs):
  empty ItemId produces no library item and no per-user viewing-state save;
  nevertheless device NowPlaying is unconditionally cleared.
- [MediaInfoController](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Jellyfin.Api/Controllers/MediaInfoController.cs):
  negotiation builds media descriptions; this adapter sets AutoOpenLiveStream
  false. Actual stream access can allocate a transcoder, so leases still need
  cleanup even when a preflight never reports Playing.
- [QuickConnectManager](https://github.com/jellyfin/jellyfin/blob/a45d1415d4da7c9b69d6e7a6895fc63d2d68e8f1/Emby.Server.Implementations/QuickConnect/QuickConnectManager.cs):
  10-minute request timeout; remote 404 expiry is also handled.

The source commit and OpenAPI are independently pinned. Their correspondence to
one released server binary has not been established. Fake tests establish the
client's protocol, isolation and lifecycle behavior only; real upstream
compatibility, encoder termination, native video/audio, and device acceptance
remain unverified.

## Preview and limitations exposed to consumers

Trickplay intervals are milliseconds. The adapter validates tile geometry,
thumbnail count and bounded response sizes; it returns a sprite rectangle rather
than treating a sheet as one frame. Genuine chapter images are the fallback.
MediaSegments contributes Intro/Outro markers only when both real endpoints are
present. No synthetic intro duration is added.

Resume, NextUp and Similar do not accept sorting in this API, so non-null sort
requests explicitly fail with `unsupported` rather than sorting a partial page.
Similar reports that offset pagination is unavailable. Notifications use explicit
page refresh. Quick Connect availability is queried from the server; preview
availability is per item. Transport failures never become empty catalog results.

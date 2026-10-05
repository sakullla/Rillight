# macOS aggregation/private-region handoff

The T7 working-tree developer checks use synthetic Emby clients, Flutter widgets and a `FakeVideoBackend`. The desktop cumulative case launches a genuinely separate Flutter test helper process, uses production per-process file IPC and the main-process `HistoryWriter`; it is **not** a native macOS playback/window, decoder, GPU or physical-audio pass. No macOS native build or SDK/package verification was executed for T7. Earlier platform observations, if any, do not accept this candidate.

## Target-machine procedure (not yet executed)

Use macOS 12+ and the pinned verified universal SDK/core artifact described by the package README. Record the candidate commit, built package and native dependency hashes, machine/OS/GPU, the actually loaded decoder/libraries and raw logs under ignored `build/`. Use disposable synthetic server credentials only.

1. Create two independently authenticated Emby services A/B with a common provider identity, explicit participating library scope, distinct media-version IDs, two verified same-server lines and differing editions/durations/audio/subtitle languages. Leave a third service's scope unknown; verify it is not automatically included.
2. In the actual desktop UI, find and compare the work, open B in the independent player window, observe changing displayed frames and physical sound, and verify B's actual version/line/account in the local ordered history. Check that A's active browsing/login does not change.
3. Switch a same-server line, an edition and a cross-server source separately. Record real position/pause intent and target language/bitrate. Test timeline confirmation/cancel, missing-language selection, identity mismatch, target failure and explicit permitted-original restoration; no automatic cross-server failover or silent clamping is acceptable.
4. Set a PIN through UI, lock, cancel/error/rate-limit/unlock, then restart the packaged app and verify locked startup. Open private detail/search/compare/settings overlays and exercise back/forward. No private name, address, source count, card, image or history may remain in the ordinary projection after lock, including with private unlocked earlier.
5. During a pending switch and during playback, move a service ordinary→private and lock private. Record main/helper PIDs, generation, close-budget timing and mailbox acknowledgements. The helper must stop/exit or be terminated within the configured budget; stale observations, snapshots, image requests, reports and restoration/retries must be rejected. Migration failure must remain explainable, not auto-resume playback.
6. Repeat with mouse/keyboard and at a narrow window. Separately retain display-frame capture, speaker observation, actual decoder evidence and GPU stability. A first-frame event, fake backend or virtual audio sink does not establish these facts.

Result: **unverified on target hardware**. Do not replace the above observations with screenshot captures or a configured CI job.

# Playback network harness

The production `PlaybackHttpProxy`, `SessionReadAhead`, and `SessionByteCache`
run against an isolated synthetic HTTP origin. No personal server, credentials,
native player, or emulator is used.

```powershell
# Windows/macOS/Linux application-level delay, jitter, disconnect and 403 cases
dart run tool/player_network_harness.dart --label candidate --trials 3

# Docker Desktop/Linux: compare committed HEAD with the current working tree
python tool/player_network_checks.py --trials 3
# A focused run, or a different committed baseline
python tool/player_network_checks.py --baseline-ref HEAD --trials 1 --scenarios netem-loss
```

Docker uses the pinned Dart 3.13.3 image. It builds a small Dart package containing
the actual transport sources and their dependencies, without substituting mocks
for the downloader. Each disposable container has `--network none` and
`NET_ADMIN`; only its own loopback network is configured. MTU is 1500 and
TSO/GSO/GRO are disabled. A `tc` source-port filter applies netem only to packets
sent by the synthetic origin, not the proxy-to-player connection. Host interfaces
and personal network connections are untouched.

| Profile | Origin response impairment |
| --- | --- |
| `netem-latency` | 200 ± 20 ms delay, shared 30 Mbit/s ceiling |
| `netem-loss` | Same, plus 1% random packet loss |
| `netem-loss-high` | 300 ± 50 ms delay, 3% loss, shared 20 Mbit/s ceiling |
| `single-stream-403` | Second simultaneous stream returns 403 |
| `startup-handoff` | Decoder opens with read-ahead paused; 250 ms header latency, then playback resumes |
| `startup-cold` | Same sequence without a previously cached prefix |
| `unhealthy-node` | Alternating connections are pinned to a node returning 502 |
| `node-outage` | Six consecutive 502 responses exhaust one attempt batch, then the origin recovers |
| `native-seek` | Seek by closing the old downstream response, without an explicit proxy cancellation call |
| `hls-latency` | VOD segments with 180 ms header delay and paced bodies; decoder reads a burst after one second of presentation |
| `hls-single-stream-403` | Same HLS demand with a one-stream origin limit |
| `hls-netem-loss` | Same HLS demand under the isolated 200 ± 20 ms / 1% loss / 30 Mbit/s network |
| `untagged` | Finite original media without ETag; decoder pauses consumption for one second while source progress is measured |
| `untagged-single-stream-403` | Untagged original media with one allowed upstream stream |
| `untagged-netem-loss` | Untagged original media under the isolated packet-loss profile |

Netem delays are one-way origin egress delay, not a claim about physical network
RTT. The rate ceiling is shared by all origin connections, so parallel requests
cannot multiply the configured link capacity. Actual kernel packet/drop counts
are saved in each row. The ordinary `latency`, `jitter`, and `disconnect` profiles
instead inject application-level pauses/truncated responses; their per-connection
pacing does not model a shared link. `shared-limit` supplies an application-level
aggregate ceiling. `all` excludes profiles requiring Linux netem.

Each profile checks a full sequential read and a seek after cancelling an active
read. Every delivered byte is checked against its absolute offset. Incorrect or
incomplete bytes, leaked authentication failure, exceeded cache/workspace budgets,
and the 90-second read deadline fail the run. The Docker comparison preserves
failed baseline runs and exits unsuccessfully on any failed or missing candidate
run. It alternates baseline/candidate order between trials. Avoid concurrent test,
build or benchmark workloads when collecting performance results.

Artifacts go under ignored `build/player-validation/network-*`:

- `report.json` / `raw.jsonl`: runtime, OS, source SHA256, first-byte and complete
  delivery times, throughput, delivery gaps, connection peaks, cache budgets and
  kernel netem statistics.
- Docker `manifest.json`, build/run logs, source snapshots, `candidate.diff`, and
  `summary.json`: committed baseline identity and per-profile median results.
  Metrics remain null when a group has failed or missing runs.

`upstreamBytes` and `repeatedBytes` in the harness count bytes queued by the
synthetic origin, including bytes later abandoned on cancellation. They are not
TCP retransmission counters. `transport.upstreamBytes` counts bytes actually
delivered to the proxy by Dart. RSS includes the Dart VM, origin and validation
client; it is not application-only player memory. Delivery gaps over 500 ms are
transport gaps, not measured video stalls. These checks establish transport
correctness and local network behavior, not displayed frames, decoder/GPU
performance, physical audio, or Android/TV hardware acceptance.

## Downloader policy under test

- Playback defaults to one continuous download filling the sliding disk window.
  Native decoder open enables that download immediately unless opening paused;
  uncached foreground probes temporarily take precedence over the producer.
  Each serial range remains capped at 32 MiB.
  Startup cache responses are bounded so a movie-sized response cannot stay in
  the 1 MiB gap-fetch loop after playback starts. Harness startup checks use this
  actual decoder-open/pause/play sequence, including subsequent bounded responses.
  Explicit transport tests can opt into up to four disjoint ranges to verify
  refusal handling; ordinary native playback does not enable that mode.
- The serial downloader assembles at most 4 MiB and publishes into the shared
  cache (2 MiB per lane in explicit parallel tests).
  Playback can read live bytes immediately. A stalled lane does not prevent other
  lanes from publishing. Shared disk admission is serialized while the transfer
  and disk work remain concurrent. The existing proxy/cache budgets still apply.
- Seek/close cancel every lane and its response iterator. Validated partial bytes
  survive cancellation; a content validator change invalidates the representation.
- New uncached demux demand beyond the producer's immediate buffered region
  preempts the old transfer, including seeks within an unfinished 32 MiB range.
  Overlapping audio/video readers still share validated live/cache bytes. A
  foreground timeout alone cannot permanently blacklist read-ahead.
  When old and new downstream reads overlap, the newest read owns the producer
  cursor. Waking an older pending read cannot redirect a forward seek back to
  the previous position; remaining readers regain priority when it completes.
- Parallel 403/409/429/503, ignored conditional ranges, or repeated initial
  connection failures switch the session to one lane. A brief grace period lets
  the server release cancelled stream slots; explicit `Retry-After` is respected.
  A serial 403 still propagates as denial of access. 401 is never reinterpreted as
  a concurrency limit.
- A foreground probe rejected during read-ahead also triggers serial fallback.
  Unconsumed response bodies are cancelled explicitly: Dart request.abort() does
  not close a response after its headers arrive. Tests include nonempty 403 bodies
  with keep-alive to cover connection-pool starvation after fallback.
- HLS speculative segment 403/409/429/503 disables further speculation for that
  session. Optional prefetch cannot expire authentication; foreground requests
  retain normal authentication and retry behavior.
- Stable, cacheable HLS VOD can warm four successive segments per playlist
  while the decoder consumes the current segment. The rolling window is capped
  by the configured read-ahead allowance, 32 MiB and a fraction of cache capacity;
  its requests remain sequential per playlist. Foreground demand advances the
  window. Pause, seek and playlist replacement retire the old window. Live,
  uncacheable and incomplete segments do not extend speculation.
  Foreground handoff allows 500 ms for headers, extending up to 2 seconds only
  while bytes keep arriving; stalled work is then preempted. Initialization
  objects share the same byte allowance as media segments.
- Consecutive failure budgets reset on validated byte progress. Interrupted cache
  gaps and read-ahead ranges resume at the exact suffix instead of re-downloading
  their accumulated prefix. Other unsupported or dynamic sources keep the existing
  streaming fallback.
- Finite original media without a strong ETag uses a private buffer for one
  HTTP response. The existing bounded scheduler pulls that response ahead of
  decoder consumption and writes into the session disk cache. Logical 32 MiB
  windows share the same upstream response/connection. Downstream cancellation
  retires obsolete readers while the session retains its bounded producer.
  A cached seek reuses that response and continues downloading ahead of the new
  position. A stopped producer can still serve a protected, bounded snapshot;
  bytes are never spliced from separately fetched unvalidated ranges.
  Small metadata probes bypass this path. Buffers share the existing workspace
  and storage budgets. Source renewal, a new origin representation, eviction,
  and session close retire retained data. Byte coverage is reported with the
  original response offset; it is not an estimated media-time seek map. A single-stream
  refusal retires the old response before the foreground request retries.
- Retryable HTTP errors explicitly retire the failed connection before retrying.
  This lets a connection-based load balancer select another node instead of
  repeatedly using an unhealthy keep-alive connection. It cannot guarantee which
  backend a load balancer selects, or replace server-side health checks.
- 502/504 failover starts with a short jittered retry and backs off to 4 seconds;
  explicit `Retry-After` still wins. Exhausting a read-ahead attempt batch pauses
  the producer for 2 seconds and retries while preserving validated bytes. It
  does not permanently disable prefetch. Authentication and representation
  changes retain their distinct failure handling.
- Successful partial media responses teach a per-resource, per-origin header
  deadline (four times measured latency plus one second, bounded to 5–20 seconds).
  Unknown sources retain 20 seconds. A timeout closes the request and doubles
  the next deadline up to 20 seconds, allowing a previously fast link to slow
  down without becoming permanently unreachable.
- Native playback requests a fresh PlaybackInfo address when a live producer
  has made no progress for 15 seconds while retrying, even though the scheduler
  remains recoverable. Renewal is limited to once per 30 seconds, cancels the
  old producer, and resumes validated cached coverage with the same validator.
  Full/idle caches and publication/disk pressure do not trigger this renewal.

Opt-in native investigation can set `RILLIGHT_TRANSPORT_TRACE` to a writable
local JSONL path before launching the app. Samples contain numeric counters,
boolean states and selected internal reason codes, never URLs, credentials,
resource identities or exception messages. Normal launches do not write traces.
Transport isolate exit/error also writes a `.host.jsonl` sidecar with pending
operation names/ages and Dart source frames, omitting exception messages.

HLS rows record `burstWaitMs` and individual `segmentWaitMs`; the one-second
presentation pause is included in wall-clock throughput but excluded from
`activeDeliveryMiBPerSecond`. First-byte timing measures HTTP delivery only,
not Play-click-to-displayed-frame latency. Each received segment is checked
byte for byte, including after seek. Use multiple trials on an otherwise idle
host when comparing these timings.
HLS fixtures contain ten 256 KiB segments; each run checks five segments
(1.25 MiB). `--size-mib` applies to the continuous-file profiles only.

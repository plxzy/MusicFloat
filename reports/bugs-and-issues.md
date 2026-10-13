# MusicFloat Bugs And Issues

Use this report for runtime bugs, rough edges, and investigation notes that should
survive across agents. Keep entries short, include the exact symptom, and update
the status as fixes land or evidence changes.

## Open

### Network read timeout during provider work

- Status: open
- First noted: 2026-05-24
- Symptom: `nw_read_request_report [C1] Receive failed with error "Operation timed out"`
- Area: Apple Music web lyrics / network provider runtime
- Impact: unknown; this may be a transient network-layer timeout unless it
  correlates with failed lyric fetches or user-visible unavailable states.
- Current mitigation: each uncached public lyrics lookup now gets a short
  privacy-safe `lookup=` token shared across top-level provider stages, Apple
  Music web catalog/endpoint logs, and LRCLIB endpoint logs. Request failures
  also log endpoint family plus safe error class, and transient catalog lookup
  failures are no longer cached as unavailable lyrics. Live run-ledger summaries
  now also extract privacy-safe lookup counts, timeout counts, and sampled
  timeout lookup IDs from live logs, plus source-split seek counts,
  resync/track-change counts, nearby timeout lookup samples, uncorrelated
  timeout counts, and privacy-safe track token samples. The profiling log capture now includes both
  `subsystem == "cv.MusicFloat"` and `process == "MusicFloat"` so process-level
  `nw_read_request_report` lines can be preserved in local artifacts if they
  recur. Seek, Music.app refinement, provider, translation, and artwork logs
  use per-process track telemetry tokens rather than raw track IDs, preserving
  local correlation without exposing fallback title/album/artist strings. Driven live run
  `20260525-080546Z-live-Direct-Sample-28b81d4` exercised two provider lookups,
  including a track change, and recorded `network_timeout_count=0`.
- 2026-05-25 follow-up: clean snapshot run
  `20260525-142048Z-live-Direct-Sample-52adb7a` also recorded
  `network_timeout_count=0` after `script/profile.sh` was tightened to ignore
  AppleEvent timeout parameters such as `timeout 7200`. Keep the issue open
  for actual `nw_read_request_report ... Operation timed out` evidence, not
  generic AppleEvent timeout fields.
- Next check: capture surrounding `cv.MusicFloat` provider logs for a matching
  `lookup=` value when this appears in a real live lookup. Keep this open until
  a live run proves whether the timeout is harmless cancellation, transient
  network failure, or a user-visible provider miss.

## Resolved

### 2026-10-13 Xcode JSON project format migration

- Converted through Xcode 27.2's File inspector from `project.pbxproj` to
  `MusicFloat.xcodeproj/project.xcproj`; opening the `.xcodeproj` bundle is unchanged.
  The JSON configuration requires Xcode 27 or later.
- Preserved every explicit Debug/Release setting for the project, app, and test
  targets, plus the existing scheme edits. Evaluated app settings also matched
  before/after in both configurations.
- Updated version readers/writers, profiling version metadata, the build-bump
  wrapper, and current documentation/spec paths. Temporary-copy checks passed
  for version reads, build bumps, marketing updates, and tag validation in both
  JSON and legacy formats; the real version remains `0.3.1 (6)`.
- Verification: Debug app build/launch and `LSUIElement` verification passed;
  Release build passed; profile report/disk and shell syntax checks passed.
  All 160 tests passed with a temporary xcconfig aligning the test signing team
  and deployment target to the app. Result:
  `.codex/DerivedData/Logs/Test/Test-MusicFloat-2026.10.13_13-20-14-+0200.xcresult`.
- Gate limitations: the unchanged test target references a team with no local
  signing certificate and targets macOS 26.5 while the app targets 27.0.
  After temporary overrides, `agent_verify.sh` stopped at its warning gate on
  `SystemLifecycleObserverTests.swift:48` (`isStopped` mutated after capture by
  a sendable closure). Signing/deployment settings and test source were preserved;
  the full strict gate is not a pass.

### 2026-05-25 stale lyrics shown after no-lyrics track change

- Status: resolved
- Area: live track-change state / provider timeout and miss handling.
- Symptom: after a track change, a song with no lyrics could briefly or
  intermittently show lyrics from the previous song, especially when provider
  lookup work produced network timeout lines such as
  `nw_read_request_report ... Operation timed out`.
- Root cause: confirmed non-empty track changes cleared artwork but left the
  previous `lyricsDocument` and translation in `AppState` until provider lookup
  finished. Provider guards prevented stale async results from applying, but the
  old document still existed locally while the new track was loading or when the
  new lookup ended unavailable.
- Fix: `AppState.updatePlayerState(_:)` now clears lyrics and translation
  immediately when the incoming player snapshot has a real new track identity.
  Transient nil-track Music.app payloads still preserve the current lyrics.
- Verification:
  - Focused `AppStateArtworkTests` and `ProviderPipelineControllerTests`
    passed, including new coverage for real track changes clearing lyrics and
    transient nil-track payloads preserving them.

### 2026-05-25 AppleScript compile crash on scrub

- Status: resolved
- Area: Music.app playback commands / AppleScript execution.
- Symptom: scrubbing could abort with `EXC_CRASH / SIGABRT` while compiling a
  cache-miss `set player position` AppleScript. The top frames were
  `OSALanguageInstance componentInstance`, `OSAScript compileAndReturnError`,
  `AppleScriptExecutor.compiledScript(for:)`, and
  `PublicAppleMusicAppBridge.perform(_:)`.
- Root cause: the actor-backed AppleScript cache serialized calls but did not
  pin OSAKit to a stable thread. Swift actor executors can hop between worker
  threads, while OSAKit language/component state is thread-affine and can throw
  uncaught Objective-C exceptions during compile.
- Fix: `AppleScriptExecutor` now owns a single long-lived `MusicFloat
  AppleScript` worker thread. All `OSALanguage`, `OSAScript`, compile, execute,
  and script-cache access happens on that thread; async callers remain off the
  main actor.
- Verification:
  - Full `xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat
    -destination platform=macOS -derivedDataPath .codex/DerivedData` passed.
  - `./script/build_and_run.sh --verify` passed.

### 2026-05-25 opt-in disk cache and clear-cache UX batch

- Status: resolved
- Areas: cache persistence, native Settings, privacy-safe disk keys.
- Source reports:
  - `reports/research-2026-05-25-resource-usage.md`
  - `reports/research-2026-05-25-bug-risk-register.md`
  - `reports/research-2026-05-25-reference-comparison.md`
- Changes:
  - `DiskBackedMediaCache` wraps the bounded memory cache and persists only
    selected namespaces when `diskMediaCacheEnabled` is true.
  - The default disk-persisted namespaces are artwork and translation; raw
    lyrics remain memory-only until a separate privacy/product decision.
  - Disk filenames and the cache index use stable hashed lookup keys rather
    than raw track, title, lyric, or provider lookup strings.
  - Settings now includes a Disk cache toggle, usage summary, and Clear Cache
    action that removes both memory entries and disk files.
- Verification:
  - Focused `MediaCacheTests` passed, including opt-in persistence across cache
    instances, disabled disk-read behavior, clear-cache removal, and raw-key
    privacy for the disk index/filenames.

### 2026-05-25 translation cache and profiling-lane batch

- Status: resolved
- Areas: translation/artwork cache, profiling evidence hygiene, live ledger
  summaries.
- Source reports:
  - `reports/research-2026-05-25-resource-usage.md`
  - `reports/translation-architecture-plan.md`
  - `reports/performance-flaws.md`
- Changes:
  - Successful translations now cache through `EphemeralMediaCache` as bounded
    JSON data keyed by provider/document/target fields.
  - Translation cache keys use bounded SHA-256 redacted key strings and do not
    expose raw lyric text in key strings or logs.
  - Live artwork refresh now caches downsampled artwork bytes through the same
    bounded cache using privacy-safe hashed track keys.
  - `script/profile.sh --apple-translation` creates an explicit
    Translation/NaturalLanguage profiling lane.
  - Run-ledger entries now record `app.apple_translation_build`, and strict
    comparisons reject mixed default-vs-translation builds.
  - Live verification summaries now include lookup/timeout correlation fields
    so agents can triage provider timeouts without opening raw live logs first.
- Verification:
  - Focused `ProviderPipelineControllerTests` passed, including translation
    cache-hit behavior and privacy-safe cache-key coverage.
  - Focused `AppStateArtworkTests` passed, including artwork cache-hit behavior
    and privacy-safe artwork cache-key coverage.
  - `bash -n script/profile.sh` passed.
  - A local-only isolated smoke sample with `--apple-translation` passed and
    recorded `app.apple_translation_build=true`.

### 2026-05-25 provider-cache, parsing, and agent-gate batch

- Status: resolved
- Areas: provider cache safety, catalog miss backoff, parser actor isolation,
  warning stability, agent verification.
- Source reports:
  - `reports/research-2026-05-25-resource-usage.md`
  - `reports/research-2026-05-25-bug-risk-register.md`
  - `reports/research-2026-05-25-codex-agent-experience.md`
  - `reports/research-2026-05-25-skills-and-fixtures-strategy.md`
- Changes:
  - Public lyrics lookup now coalesces in-flight requests by track key, keeps a
    bounded positive cache, and uses a short negative cache only for confirmed
    fully exhausted misses.
  - Cancellation, transient catalog/web failures, disabled fallback paths, and
    missing media-token paths no longer poison the unavailable cache.
  - Transient catalog resolution failures now throw through the Apple Music web
    provider so the top-level lyrics provider can avoid confirmed-miss caching
    even when later fallbacks also miss.
  - Apple Music catalog misses have a bounded short-term backoff, while
    transient resolver failures retry on the next lookup.
  - Apple Music web JSON decode, catalog search decode, TTML parse, LRCLIB
    decode, and LRCLIB parse now run through nonisolated/detached helpers
    instead of broad MainActor work.
  - Strict memory-safety warnings in the AX observer and Apple Music event
    listener were removed from the current build gate.
  - `script/agent_verify.sh` now gives agents one repeatable full check: full
    tests, warning scrape, app verify, profile report, and profile disk summary.
- Verification:
  - Focused public lyrics provider tests passed.
  - Focused Apple Music web provider tests passed.
  - A default Release build passed and does not link Translation or
    NaturalLanguage frameworks.
  - `script/agent_verify.sh` passed after the script's macOS `mktemp` template
    bug was fixed.

### 2026-05-25 report-improvement batch

- Status: resolved
- Areas: startup idleness, native panel sizing, menu polish, settings lifecycle,
  hidden live memory, privacy-safe telemetry.
- Source reports:
  - `reports/research-2026-05-25-bug-risk-register.md`
  - `reports/research-2026-05-25-native-smoothness.md`
  - `reports/research-2026-05-25-resource-usage.md`
- Changes:
  - Normal launch now stays menu-bar idle; `--demo` and `--live` remain explicit
    auto-start paths.
  - Visible overlay width changes now resize and clamp the existing `NSPanel`.
  - Long current-track menu labels are truncated while preserving a tooltip.
  - Settings language loading now uses SwiftUI `.task` instead of an unstructured
    `Task` from `onAppear`.
  - Stopping live Apple Music releases the live provider pipeline when reduced
    hidden memory mode is enabled.
  - PlayerInfo/LRCLIB/catalog/calibration telemetry no longer logs raw
    title/artist/album or lyric-line text in the targeted report findings.
  - Seek/provider/translation/artwork correlation logs now use privacy-safe
    track telemetry tokens rather than raw `trackID=` values.
  - `script/profile.sh compare-runs --strict` now rejects invalid comparison
    evidence for agent/CI-style checks.

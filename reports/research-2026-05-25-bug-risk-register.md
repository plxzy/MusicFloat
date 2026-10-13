# Bug Risk Register - 2026-05-25

## Summary

This register lists concrete risks found during the research pass. It is not a claim that every item is currently failing. Items are prioritized by likely user impact, privacy/security implications, and how easily future agents could make incorrect assumptions.

## 2026-05-25 Follow-up Status

Closed or substantially addressed in the implementation follow-up:

- BUG-R1 targeted raw title/artist/album/lyric telemetry findings were redacted
  or changed to source/stage/count/safe-reason logging. A follow-up also
  replaced raw `trackID=` seek/provider/translation/artwork correlation fields
  with per-process track telemetry tokens, because Music.app IDs can fall back
  to title/album/artist strings.
- BUG-R3 normal launch is now idle by default; auto-start behavior requires
  `--demo` or `--live`.
- BUG-R4 default Release no longer links Translation/NaturalLanguage.
- BUG-R5 visible overlay width changes now resize and clamp the existing panel.
- BUG-R6 persisted panel origin, active-screen initial placement, resize
  clamping, and display-change clamping are implemented with focused placement
  tests.
- BUG-R7 Apple Music web, catalog search, and LRCLIB decode/parse work moved
  out of broad MainActor execution.
- BUG-R8 live provider pipeline release now happens on live stop when reduced
  hidden memory mode is enabled.
- BUG-R9 catalog scoring/backoff improved with metadata scoring and short true
  miss caching.
- BUG-R12 public lyrics lookup now has TTLs, confirmed-miss negative caching,
  in-flight request joining, and the shared `EphemeralMediaCache` now has entry,
  byte, TTL, unavailable-TTL, and LRU limits. Successful translations now use
  that bounded cache with privacy-safe keys, and live artwork refresh caches
  downsampled bytes through the same contract. Follow-up also added an opt-in
  disk-backed media cache for artwork/translation payloads plus Settings usage
  and clear-cache controls.
- BUG-R13, BUG-R14, BUG-R15, BUG-R16, BUG-R17, and BUG-R18 were addressed by
  menu truncation, settings `.task`, lyrics tracker updates, removing the unused
  menu view, strict-warning agent verification, and strict profile comparisons.
- The profile ledger now records Apple Translation build state and live
  lookup/timeout summaries; `script/profile.sh --apple-translation` is the
  explicit Translation/NaturalLanguage measurement lane.

Still open or intentionally deferred:

- BUG-R2 sandbox policy is out of scope for this batch.
- BUG-R10 now has a driven Music.app evidence run; keep it in monitoring for
  scrub-heavy manual use and future playback-clock changes.
- BUG-R11 timeout correlation now has shared lookup IDs across provider stages,
  ledger summary fields, and process-level live log capture for future
  `nw_read_request_report` lines. A follow-up split live summaries into
  source-specific seek/resync counts and same-line/nearby/uncorrelated timeout
  counts, but BUG-R11 still needs a real recurring timeout to classify the
  symptom.
- Storefront-language handling is partially addressed: Apple Music web lyrics
  no longer send the account storefront language as `l` unless a preferred lyric
  language is explicitly configured. Live language-variant examples are still
  needed before closing the lyrics tracker item.

## Risk Table

| ID | Priority | Area | Risk | Evidence | Recommended next action |
| --- | --- | --- | --- | --- | --- |
| BUG-R1 | P0 | Privacy | Telemetry can expose title, artist, album, or lyric text as public log data. | `AppleMusicEventListener.swift:107`, `LRCLIBLyricsProvider.swift:116`, `LRCLIBLyricsProvider.swift:162`, `AppleMusicCatalogResolver.swift:147`, `ProviderPipelineController.swift:316` | Replace raw strings with stage/source/count/duration/hashed IDs. Put raw diagnostics behind explicit local debug flag. |
| BUG-R2 | P0 | Security/distribution | Sandbox is disabled in Debug and Release despite project guidance saying sandbox should stay on until a narrow need is proven. | `AGENTS.md`, `MusicFloat.xcodeproj/project.pbxproj:339`, `MusicFloat.xcodeproj/project.pbxproj:381`, empty entitlements | Decide and document: restore sandbox for default/demo, or justify live Apple Events/AX profile. |
| BUG-R3 | P0 | Startup/resource | Default launch starts live Apple Music and overlay automatically. | `MusicFloatApp.swift:70-88`, `MusicFloatApp.swift:164-200` | Make default launch idle unless explicit flag or user preference requests live overlay. |
| BUG-R4 | P0 | Performance baseline | Release links Translation/NaturalLanguage despite prior report saying this was a resolved memory-cost flaw. | `project.pbxproj:314`; `otool -L` shows Translation, `_Translation_SwiftUI`, NaturalLanguage | Decide if default-on is intentional; update performance tracker and baseline or restore gating. |
| BUG-R5 | P1 | UI layout | Width preference changes can leave visible panel frame stale. | `FloatingPanelController.swift:28`, `FloatingPanelController.swift:49`, `SettingsView.swift:184` | Add future panel resize/clamp path on width changes. |
| BUG-R6 | P1 | Multi-display UX | Panel initial placement was one-shot from main screen, with no persisted origin or display clamping. Follow-up added persisted origin, active-screen placement, resize/display-change clamping, and placement tests. | `FloatingPanelController.swift`; `MusicFloatTests/FloatingPanelPlacementTests.swift`; PlayStatus clamping reference | Run manual multi-display QA after the next app verify/live overlay check. |
| BUG-R7 | P1 | MainActor contention | TTML/JSON/LRC parsing is effectively MainActor-bound under default actor isolation. | `project.pbxproj:359`, `AppleMusicWebLyricsProvider.swift:10`, `TTMLParser.swift:12` | Move parsing to nonisolated helpers or parsing actor; profile syllable-heavy tracks. |
| BUG-R8 | P1 | Live memory | Stopping live mode cancels work but does not release live provider pipeline/cache. | `MusicFloatApp.swift:150`, `MusicFloatApp.swift:270`, `LyricsProvider.swift:101` | Add release/reset option when reduced hidden memory is enabled. |
| BUG-R9 | P1 | Lyrics reliability | Catalog matching misses can repeatedly retry and fall back. | `AppleMusicCatalogResolver.swift:109-189`; status report known issues | Cache failed catalog resolutions briefly; use hasLyrics, hasTimeSyncedLyrics, audioLocale, storefront language. |
| BUG-R10 | P1 | Lyrics sync | Seek/scrub and track-change desync was a known shaky area. Follow-up run `20260525-080546Z-live-Direct-Sample-28b81d4` proved seek detection, live tick resync, track-change handling, and provider reload in a driven live session; keep monitoring for syllable-heavy/manual scrub cases. | `reports/lyrics-accuracy-status.md`; live tick/seek code in `PlayerController.swift:271-379`; `reports/performance-runs.jsonl` | Repeat driven live probes when playback-clock or sync-engine code changes. |
| BUG-R11 | P1 | Provider fallback | Network timeout logs are known during provider work. Follow-up added a shared privacy-safe lookup ID across provider stage, catalog, endpoint, and LRCLIB logs; live ledger rows summarize lookup/timeout fields; live log capture now includes process-level MusicFloat lines so `nw_read_request_report` can be preserved locally if it recurs. | `reports/bugs-and-issues.md`; `nw_read_request_report ... Operation timed out`; `LyricsProvider.swift`; `AppleMusicWebLyricsProvider.swift`; `LRCLIBLyricsProvider.swift`; `script/profile.sh` | Capture a recurring live timeout and group nearby logs by matching `lookup=` value when available. |
| BUG-R12 | P1 | Cache behavior | Initial lyrics cache lacked TTL, negative cache, inflight de-dupe across equivalent requests, and disk policy. Follow-up closed the lyrics slice, made the shared ephemeral cache bounded/TTL-aware, wired successful translations plus downsampled artwork through it, and added opt-in disk persistence with Settings usage/clear controls. | `LyricsProvider.swift`, `MediaCache.swift`, `ProviderPipelineController.swift`, `AppleMusicArtworkProvider.swift`, `SettingsView.swift`, `MusicFloatTests/MediaCacheTests.swift`, `MusicFloatTests/ProviderPipelineControllerTests.swift`, `MusicFloatTests/AppStateArtworkTests.swift`; PlayStatus cache reference | Keep disk cache opt-in and limited to privacy-reviewed namespaces; measure before adding lyrics disk persistence. |
| BUG-R13 | P2 | Menu polish | Long current-track menu rows can make menu width unstable. | `MenuBarStatusItemController.swift:78`; prior repo memory around menu row churn | Truncate current-track labels and keep placeholder rows stable. |
| BUG-R14 | P2 | Settings lifecycle | Settings language load starts from `onAppear` as an unstructured task. | `SettingsView.swift:171`, `SettingsView.swift:218-271` | Use `.task` or store/cancel task. |
| BUG-R15 | P2 | Stale docs | Initial lyrics status report said per-syllable rendering was deferred, while overlay code had syllable-aware timed progress. Follow-up updated the status tracker. | `reports/lyrics-accuracy-status.md:42-55`, `LyricsOverlayView.swift:537-681` | Keep the tracker current when live evidence changes. |
| BUG-R16 | P2 | Legacy code path | `MenuBarView` appears unused while the real status item is AppKit. | `MusicFloatApp.swift:10`, `MenuBarStatusItemController.swift:25` | Remove or label as legacy/reference so future fixes land on the live path. |
| BUG-R17 | P2 | Tooling ambiguity | Xcode issue state around unsafe constructs looked transient/stale across build/test checks. | Agent/Xcode navigator observation versus later successful build/test log | Add a repeatable strict warning check to the agent verification path. |
| BUG-R18 | P2 | Report evidence quality | `profile.sh compare-runs` warns on invalid comparisons but can still exit successfully. | `script/profile.sh:1027` | Add `compare-runs --strict` for CI/agent use. |

## Detailed Notes

### BUG-R1: Privacy logging

This is the highest non-crash risk because it cuts against the product direction and user trust. Unified logs are local, but still durable and inspectable. MusicFloat should not write title/artist/album or lyric lines as public log fields by default.

Preferred replacement fields:

- provider source,
- pipeline stage,
- line count,
- syllable count,
- duration bucket,
- endpoint family,
- storefront/language code,
- local non-reversible track hash,
- cancellation/stale-result reason.

Keep raw strings only when:

- an explicit debug flag is passed,
- logs are clearly marked local diagnostics,
- the report says raw logs may include listening data,
- the agent is told not to paste raw values into PRs or public issues.

### BUG-R2: Sandbox mismatch

Resolved 2026-10-13: sandbox off is intentional. Live mode needs Accessibility
access to Music.app, Apple Events to Music.app, and the bundled
`MediaRemoteHelper` process, none of which fit the App Sandbox. `AGENTS.md` now
documents this; hardened runtime stays on with empty entitlements.

This is either a real configuration bug or an intentional live-integration tradeoff that needs to be documented. The current state is ambiguous:

- Hardened runtime is on.
- Sandbox is off.
- Entitlements are empty.
- Apple Events usage string exists.

Future agents may "fix" this in the wrong direction unless the repo states why. The next report/update should answer:

- Is sandbox off only because live AppleScript/Music.app control needs it?
- Should mock/demo builds be sandboxed?
- Is there a separate distribution profile?
- What permission prompts are acceptable for the app?

### BUG-R4: Translation linkage

The existing Release binary links Translation and NaturalLanguage. That does not automatically mean a bug, but it invalidates any stale claim that the default Release app is free of those framework costs.

The decision should be explicit:

- Translation-first product default: keep linked, baseline it, and own the memory cost.
- Small-at-rest default: gate Translation behind a build flag or lazy plugin-like boundary, then prove Release linkage is gone.

### BUG-R9 and BUG-R10: Lyrics reliability

The current provider shape is strong:

- AppleScript library lyrics first,
- Apple Music web/TTML,
- LRCLIB,
- Accessibility fallback.

Known weak points are more specific:

- catalog identity resolution,
- storefront/language mismatch,
- seek/scrub offset drift,
- duplicate/fallback requests after misses,
- AX calibration line collisions.

This argues for targeted live probes and cache/backoff work, not a provider rewrite.

## Risks That Are Already Well Controlled

- Stale provider results: `ProviderPipelineController` has track-ID guards and cancellation paths.
- Hidden live ticks: `PlayerController` cancels when overlay is hidden.
- Single AppKit panel ownership: `FloatingPanelController` owns the `NSPanel`.
- Mock/live boundary: feature flags and runtime adapters keep provider choices explicit.
- Build/test regression surface: the full Xcode test suite currently passes
  through `script/agent_verify.sh`.

## Suggested Fix Batches

Batch A - Baseline correctness:

- BUG-R1 privacy logging.
- BUG-R2 sandbox decision.
- BUG-R4 Translation linkage.
- BUG-R15 stale status report.

Batch B - Idle and memory:

- BUG-R3 idle launch.
- BUG-R8 live pipeline release/reset.
- BUG-R12 bounded cache plan.

Batch C - Native overlay polish:

- BUG-R5 width resize.
- BUG-R6 placement/clamping.
- BUG-R13 menu truncation.
- BUG-R14 settings task lifecycle.

Batch D - Lyrics robustness:

- BUG-R9 catalog metadata/cache.
- BUG-R10 live seek probes.
- BUG-R11 timeout correlation.

Batch E - Agent reliability:

- BUG-R17 warning check.
- BUG-R18 strict profiling compare.

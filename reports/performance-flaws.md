# MusicFloat Performance Flaws

Use this report to connect profiling evidence to PRs, commits, tags, and fixes.
Keep raw traces out of git; cite run IDs from `reports/performance-runs.jsonl`.

## Open

### PERF-001: Invalid live benchmark evidence

- Status: open
- First seen: PR #11 setup review
- Signal: a benchmark can claim to be live without proving Music.app playback,
  overlay appearance, non-mock lyrics, and provider readiness.
- Affected modes: live profiling
- Evidence: earlier subagent demo-mode benchmark was useful as a sanity check
  but not valid Apple Music live evidence.
- Current mitigation: `script/profile.sh ... --live` preflight and live-log
  verification, `--drive-music` for seek/next-track live interaction coverage,
  run ledger metadata, and `script/profile.sh compare-runs --strict` for
  agent/CI comparisons that should fail on mixed scenarios, invalid runs, or
  tracked-dirty source evidence.
- 2026-05-25 verification: strict comparison rejects incompatible live evidence
  instead of allowing a successful agent/CI exit. Keep the flaw open because the
  missing artifact is still a valid live `--drive-music` baseline/candidate
  pair, not just stricter tooling.
- 2026-05-25 live follow-up: run
  `20260525-080546Z-live-Direct-Sample-28b81d4` used
  `--live --drive-music`, proved Music.app playback, live auto-start overlay,
  non-mock Apple Music web lyrics (`line_count=64`), provider readiness, a
  driven seek/track-change event, and zero provider timeout lines. It reported
  avg RSS 113.69 MB and max CPU 13.9 percent. The row is useful current
  evidence but not a clean regression baseline because the worktree was dirty.
- 2026-05-25 clean snapshot live follow-up: run
  `20260525-142048Z-live-Direct-Sample-52adb7a` came from temporary snapshot
  commit `52adb7a4` with `tracked_dirty=false`. It proved Music.app playback,
  live auto-start overlay, non-mock Apple Music web lyrics (`line_count=50`),
  provider readiness, one watchdog seek, one live-clock resync, and one
  track-change event. It reported avg RSS 111.28 MB, max RSS 114.27 MB, avg
  CPU 5.15 percent, and max CPU 23.5 percent. This is clean current-candidate
  evidence, but still not a baseline/candidate regression pair.
- 2026-05-25 tooling follow-up: live verification now accepts the live
  auto-start overlay path and returns failure if any required log token is
  missing. Short run `20260525-080707Z-live-Direct-Sample-28b81d4` was marked
  invalid because provider readiness/non-mock lyrics were not proven before the
  sample ended.
- 2026-05-25 timeout-summary follow-up: `script/profile.sh` now excludes
  AppleEvent timeout parameters such as `timeout 7200` from
  `network_timeout_count`. The clean snapshot row above records zero real
  network timeout failures after that correction.
- 2026-10-13 invalid capture: clean snapshot run
  `20261013-123253Z-live-Direct-Sample-d8dfcc1` built default Release but
  failed live verification because macOS denied `log stream` to the non-admin
  account. Its empty event/timeout counters are not live or network-health proof.
  The failed row and local artifacts are retained. Direct samples now also capture
  app stderr with `OS_ACTIVITY_DT_MODE=YES`, select a single log source to avoid
  duplicate event counts, and label limited process-network coverage when the
  unified stream is unavailable. Capture settings are part of comparison compatibility.
- 2026-10-13 clean current-candidate follow-up:
  `20261013-123954Z-live-Direct-Sample-de7c419` (snapshot `de7c419c`) passed live
  verification with timed LRCLIB lyrics, two watchdog seeks, four resyncs, and one
  track change. 28 usage samples reported avg RSS 115.51 MB, max RSS 119.33 MB,
  avg CPU 3.59 percent, and max CPU 33.6 percent. This is the app-stderr logging
  lane with limited process-network coverage, not a comparable baseline/candidate
  pair or evidence of a performance improvement. Both artifacts and compact rows
  are preserved; no artifacts were cleaned.
- Next check: collect a clean same-mode `--live --drive-music`
  baseline/candidate pair while Music.app can play a lyric-capable track. Use
  `script/profile_snapshot.sh` or a real clean branch/worktree so the measured
  ledger rows are not dirty-checkout evidence.

### PERF-002: Raw Instruments artifacts can bloat disk usage

- Status: monitoring
- First seen: PR #9 profiling notes
- Signal: phased Instruments traces can create multi-GB `.codex/traces` and
  DerivedData artifacts.
- Affected modes: record, phased
- Current mitigation: `script/profile.sh disk`, `script/profile.sh clean`, and
  trace-size reporting in run entries.
- Next check: confirm trace sizes stay bounded after a full live phased run.

### PERF-007: Faster visible-lyrics refresh needs same-mode CPU proof

- Status: monitoring
- First seen: PR #18 follow-up review
- Signal: visible lyrics refresh moved from a 2s side loop to a 0.5s app loop
  with a 0.75s provider throttle to reduce delayed lyric starts, but AX
  traversal can be expensive when Apple Music web and LRCLIB miss.
- Affected modes: live overlay with visible Music.app lyrics fallback.
- Current mitigation: Apple Music web documents skip AX replacement, AX
  observer-driven refreshes keep the 0.5s cooldown, and repeated visible-line
  misses back off to 1.25s.
- Evidence gap: no clean same-mode baseline/candidate CPU pair isolates this
  refresh-cadence change yet. Do not claim it is free or regressed without run
  IDs, usage CSVs, and live logs from matching live scenarios.
- Next check: collect a clean `--live --drive-music --scenario
  apple-music-driven-karaoke` pair, or add an isolated AX-miss scenario if a
  track/provider miss reliably reproduces the expensive path.

## Resolved

### PERF-006: Live AppleScript polling repeatedly recompiles scripts

- Status: resolved in PR #17
- First seen: live same-track profiling for timed lyric progress
- Signal: live Apple Music overlay samples on a syllable-timed track stayed near
  double-digit CPU while lyrics were already loaded.
- Affected modes: live Apple Music overlay, especially timed lyrics
- Evidence: `20260525-051919Z-live-Direct-Sample-1d5470b` on
  "Solitaires (feat. Travis Scott)" selected Apple Music web syllable lyrics
  with `line_count=63` and `syllable_count=702`, then reported avg CPU 12.64%
  and max CPU 17.6%.
- Diagnosis: a local Time Profiler export from
  `20260525-052039Z-live-Time-Profiler-1d5470b` helped identify repeated
  `OSAScript` compile work under XProtect/YARA scanning. That record is marked
  invalid in the ledger because `xctrace` exited non-zero at the time limit, so
  same-mode sample runs are the comparison evidence.
- Fix: async AppleScript execution now reuses compiled `OSAScript` instances
  behind a serial actor, keeping OSAKit work off the main actor while avoiding
  per-poll recompilation.
- Validation: same-track live sample
  `20260525-052748Z-live-Direct-Sample-1d5470b` selected the same 63-line,
  702-syllable document and reported avg CPU 7.13% and max CPU 24.8%; excluding
  the initial launch/provider samples, CPU was avg 6.68% and max 11.7%.
  A driven live sample also dropped to avg CPU 4.19% and max CPU 12.8% in
  `20260525-052533Z-live-Direct-Sample-1d5470b`.

### PERF-005: AX lyrics fallback over-polls on visible-line misses

- Status: resolved in PR #17
- First seen: live driven profiling for timed lyric refactor
- Signal: when Apple Music web and LRCLIB missed, AX fallback notifications
  repeatedly traversed Music.app's lyrics tree while the panel had no visible
  lyric line, raising live sample CPU.
- Affected modes: live overlay with AX fallback and missing web/LRCLIB lyrics
- Evidence: `20260525-045803Z-live-Direct-Sample-e9179a5` reported avg CPU
  11.27% and max CPU 36.9%; its live log showed dense repeated
  `Music.app AX lyrics panel had no visible lyric line` entries.
- Fix: observer-driven AX refreshes now use a 0.5s cooldown and back off to
  1.25s after repeated visible-line misses.
- Validation: `20260525-050037Z-live-Direct-Sample-e9179a5` reported avg CPU
  5.38% and max CPU 35.5%; the startup/provider spike remained, but the AX
  miss burst disappeared from the live log.

### PERF-004: Apple Translation links translation frameworks at overlay startup

- Status: resolved in PR #13 follow-up
- First seen: PR #13 validation run
- Signal: same-mode Release `--demo` overlay samples showed higher candidate RSS
  before any settings or real translation workflow was opened.
- Affected modes: demo overlay, likely live overlay startup
- Evidence: `20260524-233022Z-demo-Direct-Sample-19fc78b` vs
  `20260524-233051Z-demo-Direct-Sample-1e7afcb` reported avg RSS
  85.7 MB -> 121.5 MB and max RSS 118.2 MB -> 148.2 MB. `otool -L`
  showed the candidate binary newly linked `Translation.framework`,
  `_Translation_SwiftUI.framework`, `NaturalLanguage.framework`, and
  `libswiftNaturalLanguage.dylib`.
- Fix: `LyricsDocument` no longer runs NaturalLanguage inference during init,
  the live provider pipeline is created only when live mode starts, and Apple
  Translation/NaturalLanguage framework usage is gated behind
  `ENABLE_APPLE_TRANSLATION` so the default `--demo` build stays mock-only.
- Validation: same-mode 30s Release `--demo --scenario overlay-karaoke`
  samples `20260524-234057Z-demo-Direct-Sample-19fc78b` vs
  `20260524-234551Z-demo-Direct-Sample-1e7afcb` reported avg RSS
  83.7 MB -> 83.4 MB and max RSS 104.9 MB -> 87.0 MB. Follow-up `otool -L`
  confirmed the fixed candidate no longer links Translation or NaturalLanguage
  frameworks in the default Release binary.
- PR #13 HEAD validation: same-mode 30s Release `--demo --scenario
  overlay-karaoke` samples `20260524-234057Z-demo-Direct-Sample-19fc78b` vs
  `20260525-001430Z-demo-Direct-Sample-1c1e8af` reported avg RSS
  83.7 MB -> 80.6 MB and max RSS 104.9 MB -> 87.7 MB.
- 2026-05-25 follow-up: a fresh default Release build under
  `.codex/DerivedData` succeeded, and `otool -L` again produced no
  `Translation`, `_Translation_SwiftUI`, `NaturalLanguage`, or
  `libswiftNaturalLanguage` linkage.
- 2026-05-25 tooling follow-up: `script/profile.sh --apple-translation` now
  creates an explicit Translation/NaturalLanguage profiling lane, the run
  ledger records `app.apple_translation_build`, and strict run comparison
  rejects mixed default-vs-translation builds. A local-only smoke run
  `20260525-074552Z-demo-Direct-Sample-28b81d4` under
  `/private/tmp/musicfloat-agent/profile-lane-smoke.jsonl` built with
  `app.apple_translation_build=true`; `otool -L` on that isolated Release app
  confirmed Translation/NaturalLanguage linkage.
- 2026-05-25 clean snapshot follow-up: temporary snapshot commit `8af2ba8`
  produced clean 30s `--demo --scenario translation-enabled-overlay` rows:
  default run `20260525-082557Z-demo-Direct-Sample-8af2ba8` reported avg RSS
  79.41 MB, max RSS 81.56 MB, avg CPU 0.30 percent, max CPU 6.7 percent;
  Apple Translation run `20260525-082703Z-demo-Direct-Sample-8af2ba8` reported
  avg RSS 75.36 MB, max RSS 77.58 MB, avg CPU 0.33 percent, max CPU 7.7
  percent. The translation binary linked `Translation`, `_Translation_SwiftUI`,
  `NaturalLanguage`, and `libswiftNaturalLanguage`. Treat the lower RSS as
  sample noise, not an improvement claim; the useful result is that no startup
  RSS jump reproduced in this clean pair.
- Next check: repeat the clean default-vs-translation pair after real Apple
  Translation work is exercised, because this demo pair only proves startup and
  overlay cost when the framework is linked but not actively translating.

### PERF-003: Deprecated karaoke Text concatenation

- Status: resolved in PR #12
- First seen: PR #9 review/build warnings
- Signal: SwiftUI warned that `Text + Text` is deprecated in macOS 26.
- Affected modes: demo, live overlay rendering
- Fix: segmented karaoke text now renders through one `AttributedString`,
  preserving wrapping and per-syllable styling without `Text` concatenation.
- Validation: `xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat
  -destination 'platform=macOS' -derivedDataPath .codex/DerivedData`

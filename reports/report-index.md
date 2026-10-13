# MusicFloat Report Index

Use this index to route durable findings without opening every report.

## Active Trackers

- `reports/performance-flaws.md`: measured performance flaws, invalid evidence,
  mitigations, and resolved performance issues.
- `reports/performance-runs.jsonl`: compact durable run ledger. Run IDs cited in
  tracked reports should exist here unless labeled local-only.
- `reports/bugs-and-issues.md`: durable user-visible bugs and non-performance
  implementation issues.
- `reports/lyrics-accuracy-status.md`: live lyrics provider status, accuracy
  evidence, and Apple Music/LRCLIB behavior.
- `reports/translation-architecture-plan.md`: translation provider architecture,
  cache strategy, and Apple Translation gating decisions.

## Research Snapshots

- `reports/research-2026-05-25-index.md`: entrypoint for the first research set.
- `reports/research-2026-05-25-native-smoothness.md`: native panel/menu bar UI
  and smoothness findings.
- `reports/research-2026-05-25-resource-usage.md`: memory, CPU, wakeup, cache,
  and hidden-work findings.
- `reports/research-2026-05-25-bug-risk-register.md`: bug and risk inventory.
- `reports/research-2026-05-25-reference-comparison.md`: PlayStatus and `.tmp`
  reference comparison.
- `reports/research-2026-05-25-codex-agent-experience.md`: initial Codex
  developer-experience findings.
- `reports/research-2026-05-25-codex-surfaces-deep-dive.md`: Codex actions,
  agents, and report-surface research.
- `reports/research-2026-05-25-musicfloat-agent-backlog.md`: proposed
  repo-local agent specs and follow-up agents.
- `reports/research-2026-05-25-skills-and-fixtures-strategy.md`: skills,
  plugin, fixture, and developer-lane strategy.
- `reports/research-2026-05-25-music-miniplayer-native-feasibility.md`: Apple
  Music miniplayer inspection and MusicFloat native compact-bar feasibility.

## Routing Rules

- Prefer active trackers for new evidence. Research snapshots are historical
  unless a task explicitly asks to extend them.
- Do not cite raw trace bundles, live logs, or usage CSVs in tracked reports
  without also adding a compact, privacy-safe summary.
- Do not paste raw lyrics, track names, artist names, tokens, or listening
  history.
- When evidence invalidates a research snapshot, add a short staleness note to
  the active tracker instead of rewriting the original snapshot.

## Current Follow-up State

- 2026-10-13: the seven review follow-ups and visible playback recovery are
  implemented; monitor-aware restoration, position locking, and optional snapping
  are added. Full gate passes 199 tests. See `reports/bugs-and-issues.md` for
  scope and remaining native acceptance, and `reports/lyrics-accuracy-status.md`
  for live evidence. Non-admin direct samples now record their app-stderr logging
  lane and limited process-network coverage; older samples are not equal-lane
  performance comparisons.

- Same-day report-improvement work addressed the idle launch, default Release
  Translation linkage, targeted telemetry redaction, visible panel width resize,
  settings lifecycle, provider-cache hardening, parser isolation, strict profile
  compare, repo-local agent specs, the full agent verification script, persisted
  panel placement/clamping, a read-only profile doctor, and provider lookup
  correlation IDs.
- Follow-up work also wired successful translations through the bounded
  ephemeral cache, added privacy-safe translation cache keys, added an explicit
  `script/profile.sh --apple-translation` lane, and expanded run-ledger entries
  with Apple Translation build state plus live lookup/timeout summary fields.
- The live artwork path now shares the bounded ephemeral cache and stores
  downsampled artwork bytes behind privacy-safe hashed keys.
- The cache layer now has an opt-in disk-backed lane for artwork/translation
  payloads, Settings shows memory/disk usage, and Settings can clear memory plus
  disk cache state. Disk filenames and the index use hashed keys, not raw track
  or lyric lookup keys.
- Translation cache review follow-up: runtime translation keys are bounded
  SHA-256 redacted strings, not unbounded lyric text keys, and memory/disk cache
  policy uses LRU, TTL, entry-count, total-cost, and object-cost limits.
- Visible lyrics refresh review follow-up: the 0.5s/0.75s refresh cadence is
  documented as a monitoring item in `reports/performance-flaws.md`; do not call
  its CPU impact proven until a same-mode live pair exists.
- Driven live run `20260525-080546Z-live-Direct-Sample-28b81d4` proved
  live Music.app playback, overlay appearance, non-mock Apple Music web lyrics,
  provider readiness, seek/track-change handling, and zero timeout lines. The
  follow-up also fixed the live verifier so missing required log tokens fail
  direct samples.
- Live profiling now captures both `cv.MusicFloat` subsystem logs and
  process-level `MusicFloat` logs so local artifacts can preserve
  `nw_read_request_report` timeout lines if they recur while reports still cite
  compact privacy-safe ledger summaries.
- `script/profile_snapshot.sh` now provides an honest clean-measurement path
  from a dirty checkout by creating temporary detached worktrees with isolated
  `RUN_LEDGER`, `TRACE_DIR`, and `DERIVED_DATA_DIR` paths.
  Prepare mode was verified against the current dirty checkout in temporary
  snapshot commit `8077daf`; no app launch or profiling run was performed.
- Full `./script/agent_verify.sh` passed during the snapshot-helper follow-up:
  script syntax checks, Xcode tests, app verify, profile report, and profile
  disk all completed. The later Bash-array fix in `script/profile.sh` was
  exercised by the clean snapshot profile samples below.
- Clean snapshot commit `8af2ba8` produced default vs Apple Translation demo
  rows `20260525-082557Z-demo-Direct-Sample-8af2ba8` and
  `20260525-082703Z-demo-Direct-Sample-8af2ba8`. The pair did not reproduce a
  startup RSS jump from merely linking Translation/NaturalLanguage; repeat only
  after real translation work is exercised.
- XcodeBuildMCP is now surfaced through `.xcodebuildmcp/config.yaml`, Codex
  environment actions, and `./script/profile.sh doctor`. The enabled surface is
  macOS-first: `macos`, `project-discovery`, `coverage`, `utilities`,
  `swift-package`, and `xcode-ide`, with MusicFloat session defaults. Restart
  or reload Codex after config changes so MCP-advertised tools refresh. A
  read-only sidecar audit confirmed the config is correct; missing tools after
  restart are more likely session/project-context or namespace-advertisement
  issues. Some Codex sessions may expose the tools as Xcode or `mcp__xcode__`
  actions rather than a literal `xcodebuildmcp` namespace. `./script/profile.sh
  doctor` now prints this hint and listed 13 macOS workflow tools in the current
  session.
- Parser fixture coverage now includes synthetic plain-line integrity, CRLF and
  blank-line normalization, invalid synced timestamp fallback, LRC offsets,
  fractional timestamps, and repeated timestamp ordering.
- Seek/provider/translation/artwork telemetry now uses privacy-safe per-process
  track tokens instead of raw `trackID=` fields, so timeout and seek evidence can
  be correlated without exposing fallback title/album/artist strings. Live
  ledger summaries now split seek, watchdog seek, playerInfo seek, resync,
  track-change, same-line timeout, nearby-timeout, and uncorrelated-timeout
  counts.
- Apple Music web lyrics no longer send the storefront default language as `l`
  unless an explicit preferred lyric language is configured; primary TTML is
  still preferred over localizations when available.
- Untimed/plain lyrics now use equal estimated line windows instead of
  word-weighted timing, and untimed lines with stray syllable data do not render
  karaoke progress. Per-tick syllable progress also no longer carries its own
  implicit SwiftUI animation.
- Live provider/AX visible-lyrics refresh is decoupled from the high-frequency
  playback tick. `PlayerController` no longer accepts an `onLiveTick` callback;
  the app controller owns a separate visible-overlay refresh loop.
- Clean snapshot driven live run
  `20260525-142048Z-live-Direct-Sample-52adb7a` proved live Music.app playback,
  overlay appearance, provider readiness, non-mock Apple Music web lyrics, one
  watchdog seek, one resync, and one track-change event from temporary snapshot
  commit `52adb7a4`. It reported avg RSS 111.28 MB, max RSS 114.27 MB, avg CPU
  5.15 percent, and max CPU 23.5 percent. It is clean current-candidate
  evidence, not a baseline/candidate pair or hitch/thermal proof.
- `script/profile.sh` timeout summarization now excludes AppleEvent timeout
  parameters such as `timeout 7200`; the clean live row records no real
  network/request timeout failures.
- PR #18 follow-up: Apple Music web lyrics now skip AX replacement for both
  timed and plain documents, preserving sentence-first behavior for line-only
  lyrics. The visible-lyrics fallback loop now checks every 0.5s with a 0.75s
  provider throttle, reducing the start/line-change delay introduced by the 2s
  side loop. AppleScript diagnostics now report fallback error details instead
  of `AppleScript error: nil`.
- Remaining non-sandbox items: capture an actual timeout if it recurs and keep
  seek/scrub monitoring fresh on future playback-clock changes.

# MusicFloat Research Index - 2026-05-25

## Scope

This report set is a read-only planning and research pass for making MusicFloat smoother, more native, lower usage, less buggy, and easier for Codex agents to develop and debug. It intentionally does not change app source, build settings, scripts, or automation config.

Same-day follow-up note: after this read-only report set was created, several
recommendations were implemented and verified. The research files keep their
original evidence, but dated follow-up sections now mark what is closed,
partially closed, or still future. Use the active trackers for current status.

Inputs used:

- MusicFloat source and project settings in the current checkout.
- Existing repo guidance in `AGENTS.md`, `.codex/PROFILING.md`, `.codex/agents/performance-profiler.md`, `docs/VERSIONING.md`, and existing reports.
- Local reference app `/Users/psp/Development/PlayStatus`.
- Reference repos under `.tmp`: `Manzana-Apple-Music-Lyrics`, `apple-music-downloader`, `YouLyPlus`, `LyricFever`, and `applemusic-like-lyrics`.
- Xcode MCP build/test checks and local profiling/report commands.
- Three read-only sub-agent passes: current app risk, reference comparison, and Codex/developer-experience tooling.

## Report Map

- `reports/research-2026-05-25-native-smoothness.md`
  - Native menu bar and floating-panel behavior.
  - SwiftUI/AppKit ownership, overlay sizing, placement, controls, and animation smoothness.

- `reports/research-2026-05-25-resource-usage.md`
  - Startup work, hidden work, Translation/NaturalLanguage linkage, parsing isolation, caches, and trace hygiene.

- `reports/research-2026-05-25-bug-risk-register.md`
  - Prioritized risk register with evidence, impact, and recommended next actions.

- `reports/research-2026-05-25-reference-comparison.md`
  - What to borrow, avoid, or treat cautiously from PlayStatus and `.tmp` repos.

- `reports/research-2026-05-25-codex-agent-experience.md`
  - Improvements for Codex actions, agent contracts, doctor checks, report indexing, and Xcode/profiling workflows.

Second-loop additions:

- `reports/research-2026-05-25-codex-surfaces-deep-dive.md`
  - Clear split between repo-local agents, global skills, plugins, prompts, actions, MCP tools, and when to use each.

- `reports/research-2026-05-25-musicfloat-agent-backlog.md`
  - Concrete proposed MusicFloat repo-local agents, each with triggers, commands, inspect paths, "must not" rules, and report destinations.

- `reports/research-2026-05-25-skills-and-fixtures-strategy.md`
  - Strategy for when to turn MusicFloat workflows into skills/plugins, and how parser fixtures, named lanes, and doctor scripts should evolve.

## Verification Snapshot

Current branch and tree:

- Branch: `main` tracking `origin/main`.
- Before report creation, `git status --short --branch` showed a clean worktree.
- Current HEAD observed earlier in the run: `28b81d4a95c2406fc6069195059e37b9cc0828e8`.

Build and tests:

- Xcode MCP `BuildProject` for `MusicFloat.xcodeproj` succeeded.
- Xcode MCP `RunAllTests` reported `96 tests: 96 passed, 0 failed, 0 skipped`.
- Some Xcode navigator/agent observations saw strict memory-safety warnings around unsafe Accessibility/EventListener helpers. Later build-log checks did not keep surfacing them, so this report treats those as a warning-stability item, not as a confirmed failing gate.

Profiling state:

- `./script/profile.sh report` showed 16 recorded runs.
- Recent live direct samples in the report were around 107.9 MB to 129.6 MB average RSS, with max CPU from 12.8 percent to 24.8 percent depending on scenario.
- `./script/profile.sh disk` reported `.codex/traces` at 6.9 MB and DerivedData at 264 MB.
- Existing `reports/performance-flaws.md` has open issues for invalid mixed live benchmark evidence and trace artifact bloat.

Release linkage check:

- The existing Release binary under `.codex/DerivedData/Build/Products/Release/MusicFloat.app/Contents/MacOS/MusicFloat` links `Translation.framework`, `_Translation_SwiftUI`, and `NaturalLanguage.framework`.
- This mattered because `reports/performance-flaws.md` said Translation/NaturalLanguage linkage previously caused an RSS jump and was resolved by gating. At the time of the snapshot, project settings also globally defined `ENABLE_APPLE_TRANSLATION` for Release.

Same-day follow-up verification:

- Focused provider/cache and Apple Music web tests passed.
- Focused lookup-correlation provider tests passed.
- Focused floating-panel placement tests passed.
- Focused media-cache policy tests passed.
- Default Release build passed.
- Fresh `otool -L` for the default Release binary showed no Translation or
  NaturalLanguage linkage.
- `script/agent_verify.sh` passed after its macOS `mktemp` template was fixed.
- Strict profile comparison now rejects invalid comparison evidence with a
  nonzero exit.
- `script/profile.sh doctor` now runs read-only preflight checks and reports
  sandbox-limited `xctrace` or process-list access without failing the command.

Current source/status changes addressed:

- Idle default launch.
- Privacy-safe targeted provider telemetry.
- Default Release Translation gating.
- Parser/decode work off broad MainActor paths.
- Live provider pipeline release on stop when reduced hidden memory is enabled.
- Visible panel width resize/clamp.
- Persisted panel origin, active-display initial placement, and display-change
  clamping.
- Menu title truncation.
- Settings `.task` lifecycle.
- Provider positive/negative cache TTLs, in-flight de-dupe, and catalog miss
  backoff.
- Shared ephemeral media cache now has entry, byte, TTL, unavailable-TTL, and
  LRU limits for future artwork/translation use.
- Runtime translation results now use that bounded ephemeral cache with
  privacy-safe provider/document/target keys.
- Live artwork refresh now uses the same bounded ephemeral cache for
  downsampled artwork bytes with privacy-safe hashed track keys.
- Provider lookup correlation IDs across top-level, Apple Music web, catalog,
  and LRCLIB logs.
- `script/profile.sh --apple-translation` now provides a dedicated
  Translation/NaturalLanguage profiling lane, run-ledger entries record the
  Apple Translation build state, and live summaries include lookup/timeout
  correlation fields.
- Repo-local agent specs, report index, and full agent verification script.
- Read-only profile doctor command.

## Highest-Leverage Work Queue

P0 - Decide the idle-launch contract.

- Current default launch schedules live Apple Music and overlay startup shortly after app launch (`MusicFloat/App/MusicFloatApp.swift:70-88`, `MusicFloat/App/MusicFloatApp.swift:164-200`).
- That is useful for demo/live development, but it conflicts with the stated "smaller at rest" and lazy-allocation direction.
- Recommended product decision: default should be menu-bar idle unless the user passes `--demo`, passes an explicit live flag, or opts into "resume live overlay on launch."

P0 - Tighten privacy-safe telemetry.

- Several logs expose track title, artist, album, or lyric line text as public telemetry.
- Replace with source, stage, counts, coarse duration, and a local hashed track key.
- Keep raw values behind an explicit debug flag and document that flag as local-only.

P0 - Reconcile sandbox and entitlement baseline. (Resolved 2026-10-13: sandbox
off is intentional and documented in `AGENTS.md`.)

- `AGENTS.md` says keep sandbox and hardened runtime on until a specific integration proves it needs narrow entitlement changes.
- The project currently has `ENABLE_APP_SANDBOX = NO` for Debug and Release, while hardened runtime remains enabled and entitlements are empty.
- Either re-enable sandbox for default/demo builds or document the exact Apple Events/Accessibility reason it is off, including what distribution profile owns that tradeoff.

P0 - Recheck Translation gating and update performance status.

- Initial snapshot found Release linking Translation/NaturalLanguage frameworks.
- Follow-up work moved Translation back behind an explicit build flag for default
  Release, updated the performance tracker, and proved fresh Release linkage is
  gone.
- Follow-up work also added a dedicated `--apple-translation` build/profile
  lane. Remaining work: collect clean same-mode measurements for that lane when
  translation cost is the active question.

P1 - Move heavy parsing away from broad MainActor work.

- The target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Apple Music web lyrics provider and TTML/JSON parse paths are effectively MainActor-bound today.
- Keep state application on MainActor, but move JSON decode, TTML parse, and LRC parse into nonisolated helpers or a parsing actor.
- Follow-up work moved Apple Music web and LRCLIB decode/parse helpers off broad
  MainActor execution; measured live hitch evidence is still future.

P1 - Add bounded cache and negative-cache behavior.

- MusicFloat has a 64-entry in-memory lyrics cache and an `EphemeralMediaCache` placeholder.
- PlayStatus has useful patterns: inflight de-dupe, memory caps, disk TTLs, negative lyrics caching, usage reporting, and clear-cache controls.
- Keep disk cache opt-in and measured, but add a bounded cache plan for lyrics/artwork/catalog misses.
- Follow-up work added bounded lyrics TTLs, confirmed-miss negative caching,
  in-flight lookup joining, catalog miss backoff, and a bounded TTL-aware
  ephemeral cache contract. Runtime translations now cache through that
  contract, and live artwork refresh now caches downsampled data through it.
  Disk persistence and clear-cache UX remain future.

P1 - Make floating panel placement and resizing more native.

- `FloatingPanelController` is a good single owner for the long-lived `NSPanel`.
- Current initial placement is one-shot from `NSScreen.main?.visibleFrame`, and width changes only apply when showing the panel.
- Follow-up implemented persisted placement, active-display initial placement,
  display-change clamping, and width-change resize/clamp without recreating the
  panel. Remaining work is manual multi-display QA with the real overlay.

P1 - Improve catalog and lyrics robustness.

- Current Apple Music web flow already uses dedicated `syllable-lyrics` and broad fallback endpoints.
- Reference repos expose fields worth using in future: `hasLyrics`, `hasTimeSyncedLyrics`, `audioLocale`, and storefront/language metadata.
- Use those to reduce bad catalog matches, storefront-language misses, and unnecessary LRCLIB fallback.

P2 - Improve Codex agent affordances.

- Codex currently exposes only a Run action through `.codex/environments/environment.toml`.
- Add future actions for Verify, Test, Profile Report, Profile Disk, Release Status, and a non-mutating Doctor.
- Add a single agent check command so future agents do not forget tests after `build_and_run.sh --verify`.
- Follow-up added the agent check script, read-only doctor command, and
  `script/generate_codex_environment.sh`, which now regenerates safe Codex UI
  actions without manual edits to the autogenerated environment file.
- The profiling ledger now captures Apple Translation build state and compact
  live lookup/timeout summaries, reducing future raw-log spelunking.
- `script/profile_snapshot.sh` now gives agents a clean temporary worktree path
  for profiling the current dirty state or a named ref without committing the
  main checkout.
- A clean snapshot pair at commit `8af2ba8` measured default vs
  Apple-Translation-linked demo startup. The Translation-linked binary did not
  show a startup RSS jump in that pair; active translation work still needs its
  own future measurement.

P2 - Add focused repo-local agent specs before global skills.

- Second-loop research found that most MusicFloat workflows are too repo-specific for global skills right now.
- Add `.codex/agents/*.md` specs first for privacy/entitlements, live lyrics, translation memory, release identity, native panel QA, provider/cache boundaries, build/test triage, report curation, and Codex/Xcode doctor checks.
- Promote only proven cross-repo pieces later, such as a generic macOS Codex/Xcode doctor.

P2 - Make profiling reports stricter and easier to query.

- `profile.sh compare-runs` warns on mixed mode/scenario/invalid evidence but exits successfully.
- Add strict comparison mode and JSON/report filters for mode, scenario, validity, git dirty state, and run IDs.
- Store privacy-safe live verification summaries directly in the ledger.

## What Not To Borrow Wholesale

- Do not copy LyricFever's global observable app model, analytics-heavy provider flow, or broad network-provider coupling.
- Do not copy PlayStatus's richer/menu-heavy status item for MusicFloat's first slice; MusicFloat's simpler AppKit status item is a better fit.
- Do not treat Apple Music web-player repos as stable public API guidance. Use them as endpoint/header evidence only, behind explicit user token boundaries and feature flags.
- Do not turn requestAnimationFrame/browser renderer advice from `applemusic-like-lyrics` into direct macOS implementation advice. The transferable idea is "high-frequency lyric progress should be isolated and disposed when hidden," not the browser loop itself.

## Suggested Execution Order

1. Privacy and baseline correctness:
   - Telemetry redaction.
   - Sandbox/entitlement decision note.
   - Translation gating verification and performance tracker update.

2. Idle/resource behavior:
   - Default idle-launch decision.
   - Release live provider pipeline/cache on hidden/stop paths when reduced memory mode is enabled.
   - MainActor parse isolation.

3. Native polish:
   - Overlay width live resize.
   - Persisted and clamped panel placement.
   - Drag/control hit-test review.

4. Lyrics robustness:
   - Catalog metadata scoring.
   - Negative cache and failed-resolution backoff.
   - Live timeout proof grouped by `lookup=` correlation ID.
   - Seek/scrub desync probes.

5. Agent experience:
   - Maintain generated Codex actions.
   - Add doctor/check scripts.
   - Add report update index.
   - Add strict profiling/report modes.

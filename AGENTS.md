# MusicFloat Agent Notes

MusicFloat is a native macOS menu bar app for floating, translated music lyrics. The project is intentionally starting small: keep the first slices architectural, observable, and easy to reverse while leaving room for deeper Apple Music and Music.app experiments later.

## Agent Workflow Checklist

- One lead agent owns the final answer, working tree, and verdict.
- Keep simple or single-file changes lead-only.
- Delegate only when the user asked for subagents, delegation, or parallel
  agent work.
- Delegate only bounded sidecar investigations or disjoint write scopes.
- Do not overlap build, test, profile, release, or app-launch commands against
  the same checkout, DerivedData, trace dirs, performance ledger, or running app.
- Performance and regression claims require evidence: run IDs, traces, logs,
  and same-mode comparisons.

## Getting Started With Codex Agents

- Start in single-agent mode: read this file, inspect the smallest relevant
  tracker, and make the narrow change.
- Open `.codex/agents/codex-workflow-router.md` only when the task is broad,
  ambiguous, explicitly asks for agents, or spans independent risk zones.
- Open one specialist spec at a time, only after the router or task points to
  it. Shared rules live here; specialist specs should stay domain-specific.
- If subagents are in flight, treat the current branch as lead-owned. Sidecars
  may write only an exact disjoint scope; otherwise they return findings for
  the lead to integrate.
- The lead rechecks `git status` and the diff before integrating any handoff.
  If two agents touched the same file or command lane, pause writes and resolve
  the conflict in the lead thread before continuing.

## Product Direction

- Build a no-Dock menu bar app with a lightweight floating lyrics overlay.
- Prefer native macOS behavior over web-style UI or heavy custom surfaces.
- Keep the overlay fast, calm, readable, and always useful while music is playing.
- Treat translations as a first-class feature, but do not wire network translation until the app shell, provider boundaries, and cache strategy are ready.
- Do not pretend public Apple APIs expose synced Apple Music lyrics. Future lyric work must be explicit about source, permissions, and reliability.

## Reference App

Use `/Users/psp/Development/PlayStatus` as an important reference, especially for:

- menu bar app ergonomics,
- now-playing provider shape,
- AppleScript/Music and Spotify experiments,
- artwork and media caching ideas,
- lyrics UI states,
- detached or floating surface behavior,
- memory reduction when hidden surfaces unload.

MusicFloat should not become a copy of PlayStatus. The goal is to make this app more native, smaller at rest, more lyrics-focused, more translation-aware, and more experimental behind clean boundaries.

## Current Architecture

The active first slice is:

- `MusicFloat/App/AppState.swift`: app-wide observable state.
- `MusicFloat/App/MusicFloatApp.swift`: menu bar and settings scenes.
- `MusicFloat/MenuBar/MenuBarStatusItemController.swift`: live AppKit status item and command menu.
- `MusicFloat/Overlay/FloatingPanelController.swift`: the only long-lived `NSPanel` owner.
- `MusicFloat/Overlay/LyricsOverlayView.swift`: mocked lyric and translation overlay.
- `MusicFloat/Settings/SettingsView.swift`: placeholder configuration surface.
- `MusicFloat/Diagnostics/AppTelemetry.swift`: stable unified logging categories.
- `MusicFloat/Player`: now-playing value types plus `MusicAppBridge`.
- `MusicFloat/Player/PlayerController.swift`: mock playback refresh boundary for proving state flow without real polling.
- `MusicFloat/Lyrics`: lyric value types, provider contract, and sync engine.
- `MusicFloat/Translation`: translation provider contract and mock translation payloads.
- `MusicFloat/Cache`: placeholder cache contract for later bounded memory/disk policy.
- `MusicFloat/Runtime`: feature flags, provider runtime state, and provider task ownership.

SwiftUI views should receive state and commands. They should not own AppKit windows, music bridges, provider clients, or long-lived caches.

## Future Boundaries

When adding real functionality, prefer these seams:

- `Player/MusicAppBridge.swift`: now-playing and playback commands. Start public-first, then add experimental adapters behind flags.
- `Player/PlayerController.swift`: task ownership for refresh loops. Keep real polling intervals adaptive and cancellable.
- `Lyrics/LyricsProvider.swift`: lyric lookup and attribution. Never assume MusicKit exposes synced lyrics.
- `Lyrics/LyricsSyncEngine.swift`: timing and active-line selection. Keep high-frequency ticks away from broad SwiftUI invalidation.
- `Translation/TranslationProvider.swift`: translation requests and cache keys. Do not log raw provider lyrics or personal listening history.
- `Cache/MediaCache.swift`: artwork, lyrics, translations, and bounded memory/disk policy. Keep disk cache opt-in and measured.
- `Runtime/ProviderPipelineController.swift`: owns provider tasks for the overlay. Keep loading cancellable and tied to visibility unless a feature flag explicitly allows hidden refresh.
- `Runtime/RuntimeFeatureFlags.swift`: declares whether a boundary is mock, public Apple API, experimental, or disabled. Architecture slices should default to mock-only with hidden refresh disabled.

Keep experimental adapters behind protocols and feature flags. AppleScript, ScriptingBridge, Accessibility, app observation, private-ish inspection, and provider scraping must stay replaceable and easy to disable.

## Codex Agent Workflow

The Codex layer should improve judgment and verification without becoming a
forced ceremony. One lead agent owns the user-facing answer, the working tree,
and the final verdict unless a specialist handoff is clearly useful.

Use official OpenAI guidance this way:

- Add rules to `AGENTS.md` when they prevent repeated mistakes, reduce
  over-reading, or codify recurring review feedback.
- Use specialist handoffs only when the task needs separate ownership or a
  bounded second investigation. The lead agent still integrates the result.
- Turn a workflow into a shared skill only after it has stable inputs, outputs,
  and two or three concrete repeat-use cases.
- Keep reliability loops explicit: run relevant checks for code changes, review
  diffs before handoff, and use traces or reports as durable evidence for
  profiling/debugging claims.

Default behavior:

- Start with `rg`, targeted file reads, and the smallest relevant tracker.
- Treat `.codex/agents/*.md` as on-demand specialist specs. Read only the
  matching spec and any file it explicitly routes to.
- Do not bulk-read `.codex/DerivedData`, `.codex/traces`, raw live logs, or all
  reports unless the task is specifically about those artifacts.
- Prefer read-only diagnostics before commands that launch apps, change Music.app
  playback, record Instruments traces, install bundles, clean artifacts, or alter
  permissions.
- Consider a specialist spec or handoff when a second agent can inspect a
  separate risk zone with bounded inputs, allowed commands, and a compact
  verdict.

Do not delegate for a small single-file change, a task where the specialist
would need the same write scope as the lead, or a command sequence that must own
the only running MusicFloat/Music.app session.

When multi-agent tools are available, spawn subagents only after the user has
asked for delegation, subagents, or parallel agent work. Before spawning, the
lead agent should name the immediate local task it will continue doing, then
delegate only sidecar work that can run independently. Use explorer-style agents
for specific read-only codebase questions and worker-style agents only for
disjoint write scopes. Close subagents when their result is integrated.

Non-interference rules:

- Do not run build, test, profile, release, or app-launch commands in parallel
  against the same checkout, `.codex/DerivedData`, `.codex/traces`,
  `reports/performance-runs.jsonl`, or running `cv.MusicFloat` instance.
- `./script/build_and_run.sh --verify` may build, launch, or stop MusicFloat.
  Use it for meaningful app verification and avoid overlapping it with profile,
  live-lyrics, or release identity work.
- Never run `./script/profile.sh clean`, `script/release_self.sh --install`,
  `./script/profile.sh ... --drive-music`, broad `pkill`, or broad `killall`
  unless the user asked for that effect or explicitly approved it.
- For exploratory profiling or agent-behavior checks, prefer isolated paths:

  ```sh
  RUN_LEDGER=/tmp/musicfloat-agent/runs.jsonl \
  TRACE_DIR=/tmp/musicfloat-agent/traces \
  DERIVED_DATA_DIR=/tmp/musicfloat-agent/DerivedData \
  ./script/profile.sh sample 20s --demo --scenario overlay-karaoke
  ```

  Add `--apple-translation` for isolated Translation/NaturalLanguage lane
  smoke checks; keep those separate from default Release measurements.

  For clean evidence from a dirty checkout, use:

  ```sh
  script/profile_snapshot.sh -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
  ```

  The snapshot helper creates a temporary detached worktree and isolated
  profiling artifact paths without committing the main checkout. Add `--run`
  only when you intentionally want it to build, launch, or profile the app.

  Copy or rerun compact evidence into the tracked ledger only when it becomes
  durable project evidence.

When handing work to a subagent, include:

- the exact question,
- allowed paths and commands,
- forbidden side effects,
- expected output shape,
- report paths to update, or a clear `no writes` instruction.

Available repo-local agent specs:

| Spec | Use for |
| --- | --- |
| `.codex/agents/codex-workflow-router.md` | Delegation and safety routing. |
| `.codex/agents/performance-profiler.md` | Performance evidence and regression comparison. |
| `.codex/agents/build-test-triage.md` | Compiler, test, CI, and Xcode warning failures. |
| `.codex/agents/live-lyrics-forensics.md` | Live Apple Music lyrics behavior. |
| `.codex/agents/privacy-entitlements-reviewer.md` | Logs, privacy, sandbox, and entitlements. |
| `.codex/agents/translation-memory-gatekeeper.md` | Translation framework memory and privacy boundaries. |
| `.codex/agents/native-panel-auditor.md` | Native overlay/menu bar behavior. |
| `.codex/agents/release-identity-doctor.md` | Debug/Release/dist/installed bundle identity. |
| `.codex/agents/provider-cache-boundary-auditor.md` | Provider cache, retry, timeout, and cancellation behavior. |
| `.codex/agents/report-curator.md` | Durable tracker/report updates. |
| `.codex/agents/codex-xcode-doctor.md` | Codex/Xcode/MCP tool affordances. |
| `.codex/agents/parser-fixture-curator.md` | TTML/LRC/parser fixture coverage. |
| `.codex/agents/musicfloat-agent-check.md` | Final handoff verification and report coherence. |

XcodeBuildMCP is repo-configured in `.xcodebuildmcp/config.yaml` for the
macOS-first MusicFloat surface: `macos`, `project-discovery`, `coverage`,
`utilities`, `swift-package`, and `xcode-ide`, with session defaults for
`MusicFloat.xcodeproj`, scheme `MusicFloat`, macOS/arm64, `.codex/DerivedData`,
and bundle ID `cv.MusicFloat`. After changing that config, restart or reload
the Codex session so MCP tool advertisement refreshes. Depending on the Codex
tool bridge, these capabilities may appear as Xcode or `mcp__xcode__` actions
rather than a literal `xcodebuildmcp` namespace; use `.codex/agents/codex-xcode-doctor.md`
and `./script/profile.sh doctor` to distinguish config problems from session
advertisement problems.

## Telemetry

Use Apple's unified logging via `Logger`; do not use `print` for app telemetry.

Use categories consistently:

- `Lifecycle`
- `MenuBar`
- `Windowing`
- `Settings`
- `Performance`

Log stable, high-signal events: app launch, menu actions, panel creation/show/hide, settings appearance, future provider milestones, cache eviction, and fallback paths. Keep telemetry concise: prefer counts, provider/source names, privacy-safe lookup IDs, and broad error classes over raw text, raw line payloads, track titles, artist names, or repeated per-line details. Do not log secrets, tokens, raw lyrics from real providers, or personal listening history beyond coarse public-safe state.

Use `AppTelemetry.measure` for short performance spans that should show up as signposts in Instruments, especially panel creation/show/hide, provider calls, lyric sync ticks, cache reads, translation requests, and startup work. Keep signposts coarse; they are for finding shape, not narrating every line of code.

Run telemetry with:

```sh
./script/build_and_run.sh --telemetry
```

Run a memory sample with:

```sh
./script/build_and_run.sh --memory
```

For Xcode-native profiling, use Product > Profile on the shared scheme or use:

```sh
./script/profile.sh list
./script/profile.sh record "Time Profiler" 20s
./script/profile.sh record "Allocations" 30s
./script/profile.sh record "Logging" 15s
./script/profile.sh record "System Trace" 5s
```

For a local self-install style Release bundle, use:

```sh
script/release_self.sh --memory
script/release_self.sh --install
```

The self-release script exports `dist/MusicFloat.app`, keeps dSYM output in DerivedData, verifies `LSUIElement`, prints signing/entitlements, and builds with strip/postprocess plus coverage instrumentation disabled. Do not commit `dist/`.

The most useful Instruments templates for this project are:

- `App Launch`: startup cost and accidental eager initialization.
- `Time Profiler`: CPU cost from polling, sync engines, parsing, translation, or UI updates.
- `Allocations`: memory growth after overlay/settings/provider use.
- `Leaks`: retained windows, providers, caches, or translation clients.
- `SwiftUI`: expensive view invalidation and body recomputation.
- `Swift Concurrency`: task lifetimes, actor hops, and runaway async work.
- `Logging`: unified logs plus signposts from `AppTelemetry.measure`.
- `System Trace`: CPU wake/context-switch evidence, especially for hidden menu bar idle checks.
- `Power Profiler`: long-running menu bar idle cost.
- `Animation Hitches`: overlay movement/material/rendering smoothness.

## Performance Profiler Agent

For tasks that ask Codex to compare versions, benchmark, profile, investigate
memory leaks, SwiftUI invalidation, Swift concurrency, CPU wakeups, startup
cost, regressions, or performance flaws, start with:

```sh
sed -n '1,260p' .codex/PROFILING.md
sed -n '1,320p' .codex/agents/performance-profiler.md
./script/profile.sh report
./script/profile.sh disk
```

Use the profiler agent spec at `.codex/agents/performance-profiler.md` as the
task contract. It defines valid evidence, same-mode comparison rules,
baseline/candidate workflow, report format, and fix boundaries.

When comparing versions, do not claim a regression from mixed modes, mixed
default-vs-`--apple-translation` builds, or unverified live traces. Use run IDs
from `reports/performance-runs.jsonl`, trace paths under `.codex/traces/`,
usage CSVs under `.codex/traces/usage/`, compact live verification summaries,
and `cv.MusicFloat` logs as evidence. Update
`reports/performance-flaws.md` when a run proves a new flaw, invalidates prior
evidence, or closes an issue.

For Apple Music live-button, live-lyrics, freeze, seek, or skip investigations,
prefer the driven live workflow:

```sh
./script/profile.sh sample 30s --live --drive-music --scenario apple-music-driven-karaoke
```

`--drive-music` is allowed for those profiling tasks because it starts
Music.app playback and performs seek/next-track actions, but call out that it
changes the user's active Music playback.

## Build And Runtime Baseline

- Project type: Xcode macOS app.
- Project configuration: `MusicFloat.xcodeproj/project.xcproj` (Xcode's JSON
  format; requires Xcode 27 or later). Use `script/version.sh` for version edits.
- Scheme: `MusicFloat`.
- Bundle ID: `cv.MusicFloat`.
- The app is an agent-style UI element app: `LSUIElement = YES`.
- Keep Swift 6, strict concurrency, strict memory safety, and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- App Sandbox is intentionally off (`ENABLE_APP_SANDBOX = NO`). Live mode reads
  Music.app through Accessibility, sends Apple Events to Music.app, and spawns
  the bundled `MediaRemoteHelper` that loads a private framework; none of these
  fit the sandbox. Keep hardened runtime on and entitlements empty, and do not
  re-enable the sandbox or add entitlements without a specific integration need.
- Add usage strings only when the corresponding API is actually wired.
- Avoid broad permissions, Apple Events exceptions, Accessibility prompts, or network clients in architecture-only slices.

Use:

```sh
./script/build_and_run.sh --verify
```

before handing off meaningful app changes.

Use:

```sh
./script/agent_verify.sh
```

for a full agent handoff gate when the task touches shared runtime behavior,
tests, scripts, or report-backed performance claims. It runs the test suite,
fails on unexpected compiler warnings, verifies the app launches, and prints the
current profiling report/disk summary.

Use:

```sh
./script/profile.sh doctor
```

for a read-only Codex/Xcode/app preflight. It checks git state, Xcode,
`mcpbridge`, Instruments template access, bundle identity, artifact sizes,
Codex actions, and Music.app live preflight without recording traces, installing
bundles, cleaning artifacts, or driving playback.

## Memory And Performance Expectations

A bare SwiftUI/AppKit menu bar process can sit around tens of MB of RSS because loading AppKit, SwiftUI, dyld shared cache mappings, and the Swift runtime has a non-zero floor. Treat around 20 MB RSS as a baseline to measure, not automatically a leak.

Before optimizing memory:

- measure Debug and Release separately,
- measure at rest, after showing the overlay, after hiding it, and after opening settings,
- distinguish resident memory from virtual memory,
- avoid loading artwork, lyric providers, translation clients, large caches, or heavy settings trees at startup.

Prefer lazy allocation. The floating panel, provider adapters, caches, translation clients, and experimental observers should initialize only when needed.

Hidden UI should not keep preview or provider clocks alive. Mock playback is allowed to advance while the overlay is visible or while a developer explicitly starts the mock preview, but hiding the overlay should cancel that task. Prefer adaptive lyric-boundary wakeups over one-second polling; if hidden providers later need background refresh, make the interval adaptive, feature-flagged, and measurable in System Trace/Power Profiler.

## Style

- Keep first-screen UI functional, not a landing page.
- Prefer system materials, standard controls, and macOS idioms.
- Use AppKit only where SwiftUI does not model the behavior cleanly.
- Keep each slice small enough to revert if an Apple API direction proves wrong.

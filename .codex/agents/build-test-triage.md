# MusicFloat Build Test Triage Agent

Use this spec for compiler errors, test failures, CI failures, Xcode warnings,
strict concurrency warnings, strict memory-safety warnings, or stale-looking
navigator issues.

## Mission

Find the smallest failing scope and separate current build/test evidence from
stale IDE state. Keep fixes narrow and preserve MusicFloat's Swift 6,
MainActor-by-default, hardened-runtime (non-sandboxed) macOS baseline.

## First Checks

Start with the smallest gate that matches the failure. Use `build_and_run.sh
--verify` only when app launch/runtime verification is part of the question.

```sh
git status --short --branch
xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat -destination 'platform=macOS' -derivedDataPath .codex/DerivedData
```

Runtime verification gate:

```sh
./script/build_and_run.sh --verify
```

Full handoff gate for broad agent work:

```sh
./script/agent_verify.sh
```

This runs the full Xcode test suite, fails on unexpected compiler warnings,
verifies the app launches, and prints profile report/disk summaries. Use it
after shared runtime/script/report work, not as the first diagnostic for a tiny
single-file failure.

Use XcodeBuildMCP or Xcode tools when the task is explicitly about Xcode state:

- list windows/projects,
- build the project,
- run all tests,
- fetch the build log,
- compare navigator issues with current command output.

## Non-Interference

- `build_and_run.sh --verify` can launch or stop MusicFloat. Do not overlap it
  with profiling, live-lyrics, release identity, or another build agent.
- `agent_verify.sh` also launches/stops MusicFloat through `build_and_run.sh
  --verify`; treat it as the owner of the checkout while it runs.
- Do not run broad process kills. If a stale `cv.MusicFloat` process blocks a
  build/run check, identify it with `pgrep -fl MusicFloat` and ask before
  killing anything unexpected.
- Do not clean DerivedData unless the failure is proven cache-related or the user
  asks for a clean build.

## Inspect

- failing source and test files,
- `script/build_and_run.sh`,
- `MusicFloat.xcodeproj/project.xcproj`,
- `.codex/agents/performance-profiler.md` only if the failure affects evidence,
- Build macOS Apps `test-triage` skill guidance when needed.

## Further Research For This Agent

- Map common Swift 6 strict-concurrency diagnostics to MusicFloat ownership
  seams such as `ProviderPipelineController`, `PlayerController`, and AppKit
  controllers.
- Identify warnings that are harmless stale navigator issues versus warnings in
  the fresh build log.
- Keep `./script/profile.sh doctor` aligned with build/test reality when new
  toolchain, scheme, DerivedData, or Xcode MCP checks become useful.

## Output Format

```md
Verdict: build pass | test pass | build fail | test fail | stale IDE state | inconclusive

Smallest failing scope:
- <target/test/file>

Evidence:
- <command and key error>

Safe next fix:
- <minimal change or diagnostic>

Side effects:
- MusicFloat launched/stopped? yes/no
```

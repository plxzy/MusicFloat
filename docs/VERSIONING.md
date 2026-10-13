# MusicFloat Versioning Convention

## Two numbers, two purposes

| Field | Meaning | Bumped by | Example |
|-------|---------|-----------|---------|
| `MARKETING_VERSION` | User-facing semantic version | `script/version.sh set-marketing <version>` | 0.3.0, 0.4.0 |
| `CURRENT_PROJECT_VERSION` | Monotonic build number | `script/version.sh bump-build` | 3, 4, 5 |

The installed app shows both values:

- Finder/App Info version: `MARKETING_VERSION` (`CFBundleShortVersionString`)
- Build: `CURRENT_PROJECT_VERSION` (`CFBundleVersion`)

So `0.3.0 (3)` means semantic version `0.3.0`, build `3`. It does **not**
mean version `3.0`.

The project uses Xcode's JSON configuration at
`MusicFloat.xcodeproj/project.xcproj` and requires Xcode 27 or later. The helper
reads and updates this format, with a fallback for legacy `.pbxproj` projects.

Use the helper script as the source of truth:

```sh
script/version.sh show
script/version.sh value MARKETING_VERSION
script/version.sh value CURRENT_PROJECT_VERSION
script/version.sh installed
script/version.sh running
script/release_self.sh --status
```

## When to bump what

```
PR merged to main       -> script/version.sh bump-build
                           CURRENT_PROJECT_VERSION increments

Feature batch done      -> script/version.sh set-marketing <version>
                           + commit version bump
                           + merge
                           + create matching annotated tag (v<version>)
                           + optionally create GitHub Release

Experimental fix/test   -> bump build only
User-visible feature    -> patch or minor semantic bump
Compatibility break     -> minor bump while pre-1.0
```

## git tags

Tags are created for **semantic version milestones**, not every merge:

- `v0.1.0` — first profileable architecture slice
- `v0.2.0` — real Apple Music lyrics working
- `v0.3.0` — translation provider wired
- `v0.4.0` — next user-visible feature batch, not yet assigned

Build numbers track CI lineage but don't get tags.

Before tagging, assert the tag matches the project:

```sh
script/version.sh assert-tag-version v0.4.0
git tag -a v0.4.0 -m "MusicFloat v0.4.0"
git push origin v0.4.0
```

## Release app identity

The menu bar can hide which build is running. Before debugging a Release-only
issue, confirm the active process:

```sh
script/release_self.sh --status
pgrep -fl MusicFloat
```

Expected self-installed Release path:

```text
/Applications/MusicFloat.app/Contents/MacOS/MusicFloat
```

Xcode Debug path:

```text
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/MusicFloat.app/Contents/MacOS/MusicFloat
```

If the running command points at DerivedData, you are testing Debug, not the
installed Release app. Use `script/release_self.sh --install --open` to replace
and launch the self-installed Release bundle.

## GitHub Releases

Only for tagged versions the user considers distributable/testable.
Include auto-generated release notes from merged PRs.

## Profiling convention

When comparing versions, use the same mode and scenario on both sides. `--demo`
is the cheap mock-overlay sanity check; `--live` is the meaningful Apple Music
karaoke path and requires Music.app to be actively playing.

```sh
# Cheap resource sample
./script/profile.sh sample 30s --demo --scenario overlay-karaoke

# Single Instruments template
./script/profile.sh record "Time Profiler" 20s --live --scenario apple-music-karaoke

# Compare two durable run records
./script/profile.sh compare-runs <baseline-run-id> <candidate-run-id>
```

The profiler appends compact run summaries to `reports/performance-runs.jsonl`.
Use `./script/profile.sh report` to list recent runs and include run IDs in PR
notes. Do not treat mixed-mode traces as regression evidence.

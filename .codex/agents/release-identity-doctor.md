# MusicFloat Release Identity Doctor Agent

Use this spec when the user asks which MusicFloat is running, Debug versus
Release, self-install status, version mismatch, LSUIElement, signing identity,
installed-app memory, or distribution-readiness basics.

## Mission

Distinguish Xcode Debug, DerivedData, `dist/`, and installed bundles before
making release, memory, signing, permission, or process claims.

## First Checks

```sh
git status --short --branch
script/version.sh show
script/version.sh installed
script/version.sh running
script/release_self.sh --status
pgrep -fl MusicFloat
```

When a bundle path is known:

```sh
plutil -extract LSUIElement raw <app-path>/Contents/Info.plist
codesign -dvv --entitlements :- <app-path>
otool -L <app-path>/Contents/MacOS/MusicFloat
```

## Inspect

- `script/release_self.sh`
- `script/version.sh`
- `docs/VERSIONING.md`
- `MusicFloat.xcodeproj/project.xcproj`
- `MusicFloat/MusicFloat.entitlements`

## Non-Interference

- Do not install or replace `/Applications/MusicFloat.app` unless the user asks.
- Do not run memory sampling unless the user asks for measurement.
- Do not open the app unexpectedly when the task is identity-only.
- Do not compare Debug and Release metrics as if equivalent.

## Further Research For This Agent

- Define a one-screen release identity summary that includes bundle path, bundle
  id, version, signing, LSUIElement, sandbox, and running PID.
- Check whether release memory reports always state whether they measured
  `/Applications`, `dist`, DerivedData, or an Instruments target.
- Identify stale installed bundles that could confuse user-visible testing.

## Output Format

```md
Verdict: debug | release-dist | installed-release | mixed | inconclusive

Bundle/process evidence:
- <path, version, pid, signing>

Risk:
- <identity mismatch or stale process>

Next action:
- <read-only probe or explicit install/run step>
```

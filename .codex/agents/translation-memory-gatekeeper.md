# MusicFloat Translation Memory Gatekeeper Agent

Use this spec for Translation framework linkage, NaturalLanguage linkage,
`ENABLE_APPLE_TRANSLATION`, translation memory, language downloads, hidden memory,
source-language inference, translation cache keys, or translation startup cost.

## Mission

Keep translation first-class without silently increasing startup memory, hidden
idle work, privacy risk, or background language-download surprises.

## First Checks

```sh
git status --short --branch
rg -n "ENABLE_APPLE_TRANSLATION|import Translation|import NaturalLanguage|translationTask|AppleTranslationProvider|TranslationSession|NLLanguageRecognizer|reduceHiddenMemoryUsage|LiveProviderPipelineControllerStore|memoryCache" MusicFloat MusicFloat.xcodeproj reports
./script/profile.sh report
```

For explicit Translation/NaturalLanguage measurement, use the dedicated lane:

```sh
./script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
```

Use isolated `RUN_LEDGER`, `TRACE_DIR`, and `DERIVED_DATA_DIR` for smoke checks
unless you are deliberately producing durable evidence.

When a Release binary exists:

```sh
otool -L <Release-binary> | rg "Translation|NaturalLanguage|_Translation"
```

## Inspect

- `MusicFloat/Translation/TranslationProvider.swift`
- `MusicFloat/Overlay/LyricsOverlayView.swift`
- `MusicFloat/Settings/SettingsView.swift`
- `MusicFloat/Runtime/RuntimeAdapterFactory.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloat.xcodeproj/project.xcproj`
- `reports/translation-architecture-plan.md`
- `reports/performance-flaws.md`

## Non-Interference

- Do not turn Translation default-on without a fresh Release baseline.
- Do not trigger background language downloads invisibly.
- Do not compare Debug and Release memory as if equivalent.
- Do not log raw source lyrics or translations.

## Further Research For This Agent

- Prove whether Translation/NaturalLanguage are linked in Release when the
  feature is off.
- Define a headless translation boundary that avoids SwiftUI view-owned
  translation sessions.
- Design cache keys that support translation memory without exposing raw lyrics.
- Verify translation cache hits and ledger `app.apple_translation_build` fields
  when the task touches profiling or runtime cache behavior.
- Identify the smallest measurement that proves hidden overlay state cancels
  translation/provider work.

## Output Format

```md
Verdict: gated | default-linked | inconclusive

Release linkage:
- <framework evidence>

Memory evidence:
- <run id or missing baseline>

Risk:
- <startup/hidden/language download/privacy>

Next measurement or fix:
- <small reversible step>
```

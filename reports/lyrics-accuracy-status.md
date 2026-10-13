# Live Lyrics Accuracy — Status & Next Steps

Last updated: 2026-10-13

Snapshot of where the live-lyrics pipeline stands after the active-line AX pass,
Apple Music web-API integration, syllable-aware overlay progress, and the latest
provider-cache hardening. Tracks what works, what doesn't, and the most useful
next moves.

## 2026-10-13 playback recovery follow-up

- User observed Music playing while the overlay waited for playback. Recovery now
  covers a failed/nil initial snapshot and missed resume events while visible;
  startup notification subscription precedes snapshot/volume suspension. Paused
  states do not advance elapsed time, and hiding cancels recovery checks.
- Full gate passed 199 tests including silent-event-stream and cancellation
  fixtures. A fresh Debug live launch displayed the active track and Pause control.
  This verifies current playback visibility, not the exact earlier failure trigger.
- Initial Release sample `20261013-123253Z-live-Direct-Sample-d8dfcc1` is invalid:
  macOS denied unified log streaming. No network-health conclusion follows from its
  empty counters. The historical timeout issue remains open.
- Clean default Release run `20261013-123954Z-live-Direct-Sample-de7c419` passed live
  playback, overlay visibility, non-mock lyrics, provider readiness, and driven
  event verification. Two LRCLIB lookups returned timed documents (78 and 61 lines);
  counters recorded two watchdog seeks, four resyncs, and one track change. This
  run did not exercise Apple Music web TTML or prepared Translation output.
  App-stderr capture recorded zero timeout lines with limited process-network
  coverage; the network timeout issue remains open.
- Nested TTML, shared provider cancellation, and prepared Translation ownership
  now have regression coverage; actual Translation language downloads and physical
  multi-monitor interaction still need runtime acceptance.

## Current pipeline

Lyric resolution runs in this order inside `PublicLyricsProvider.lyrics(for:)`:

1. **AppleScript library lyrics** (`MusicAppLyricsProvider.fetchCurrentTrackLyrics`) — only canonical `.musicApp` results are accepted at this stage. The internal AX fallback is deliberately filtered out here so the web API gets a chance.
2. **Apple Music web API** (`AppleMusicWebLyricsProvider`) — fetches TTML from `amp-api.music.apple.com/v1/catalog/{sf}/songs/{id}` with the user's `media-user-token` and a developer JWT scraped from the web player's `index~XXXXX.js` bundle. It now tries the dedicated `/syllable-lyrics?extend=ttmlLocalizations` endpoint first, falls back to `include[songs]=albums,lyrics,syllable-lyrics`, and returns full timed multi-line `LyricsDocument` values with optional per-syllable timings.
3. **LRCLIB** — timed match if available, with an AX-driven calibration pass that nudges the LRC clock when it drifts. Skipped entirely when the "Allow LRCLIB / Music app UI fallback" toggle is off.
4. **AX panel scrape** — single-line `.musicAppUI` document. Active-line detection keys off button-frame height (the active line auto-resizes ~1.33× larger), with a viewport filter and geometric centering as tiebreakers.

Missing Accessibility permission no longer blocks non-AX providers: canonical AppleScript lyrics still return immediately, then Apple Music web and LRCLIB are allowed to run before an AX-specific permission message is surfaced.

The live-refresh tick in `ProviderPipelineController` recognizes the source of the current document and will:

- Skip everything for `.appleMusicWeb` docs, timed or plain (authoritative
  Apple document, no AX replacement). Provider-level LRCLIB/AX fallback still
  runs when Apple Music web returns no document at all.
- Run text-match calibration for `.lrclib` timed docs (matches AX active-line text against the LRC document, nudges `offsetCorrection`, ±10s safety clamp).
- Replace `.musicAppUI` docs in place when the AX scrape returns new text.

## What works

- **Catalog songs with a configured `media-user-token`**: the TTML path lights up reliably. Logs show `Lyrics hit appleMusicWeb timed=true lines=N` and the overlay tracks Music's highlight closely on a stable playback.
- **Syllable-aware overlay progress**: `LyricLine.syllables` is no longer just stored for later. Active lines use the syllable-weighted progress mask only when Apple TTML carries span timings; line-only and plain lyrics render as whole text without progress fill.
- **Sentence-first plain/line-only rendering**: untimed documents now advance by equal estimated lyric-line windows using track duration, without giving longer lines extra word-weighted time. Line-timed documents that do not carry syllables render whole active lines instead of a fake word-by-word fill, so plain lyrics behave sentence by sentence. Preview refreshes also use those estimated plain-line boundaries instead of falling back to the long idle interval.
- **LRCLIB calibration**: when LRCLIB returns timed lyrics for a different master than the user is playing, the AX-driven calibration nudges the clock back into agreement using the overlay's effective live elapsed time rather than the sparse now-playing snapshot.
- **Driven seek/track-change recovery**: live run `20260525-080546Z-live-Direct-Sample-28b81d4` launched `--live --drive-music`, loaded a non-mock Apple Music web document (`line_count=64`), detected a +15s seek via the watchdog, resynced the live clock, handled a next-track event, and detected a later seek correction. The run had `network_timeout_count=0`.
- **Clean driven live recovery evidence**: snapshot run `20260525-142048Z-live-Direct-Sample-52adb7a` repeated the driven path from a clean temporary worktree. It proved Music.app playback, overlay appearance, provider readiness, one watchdog seek, one resync, one track change, and Apple Music web lyrics after the track change (`line_count=50`, `syllable_count=0`). The live log also showed a line-only Apple Music web path (`timed=false`); visual proof that the overlay never shows fake word-fill still needs a screenshot, video, or UI snapshot.
- **Plain Apple Music web docs stay sentence-first**: Apple Music web documents
  now skip AX replacement whether they are timed or plain. Timed TTML keeps the
  Apple clock; line-only/plain web lyrics keep equal estimated sentence windows
  instead of being overwritten by a one-line Music.app UI scrape.
- **AX fallback reacts faster again**: visible-lyrics refresh now checks every
  0.5s with a 0.75s controller throttle, restoring most of the responsiveness
  lost when it was moved off the high-frequency live tick.
- **Mock preview**: architecture defaults stay fully mock; the public Apple provider stack is only selected for live Apple Music mode.
- **AX active-line detection**: button-height heuristic + viewport filter avoids the prefetch-buttons-far-off-viewport trap and the wrapped-2-line-inactive-lyric trap. Works without Music exposing any state attribute (the AX dump confirmed only the standard skeleton is published).

## Known issues

- **Seek / scrub long-run coverage**: the latest driven run proved the watchdog can detect seek jumps and resync the live clock, but it covered one session and line-timed Apple Music web lyrics. Keep this as a monitoring item for scrub-heavy manual use, syllable-heavy TTML, and tracks where Music's own highlight jumps differently from the web TTML timing.
- **Catalog ID resolution misses**: some tracks can still log `AM web: could not resolve catalog ID for track` and fall back to LRCLIB / AX. The resolver now scores `hasLyrics`, `hasTimeSyncedLyrics`, and `audioLocale`, and the web provider suppresses short-term repeated misses per track. Remaining root causes likely include:
  - AppleScript `URL of current track` is empty for some catalog playback paths (cloud library matches, Apple Music radio, queued recommendations).
  - The catalog-search fallback still only requests `types=songs`; matching may remain too strict for renamed/translated/explicit-tagged variants.
- **Storefront language**: the web provider no longer sends the storefront's
  `defaultLanguageTag` as the `l` parameter by default. It sends `l` only when a
  preferred lyric language is explicitly configured, then still prefers
  identifiable primary TTML over localizations during selection. This should
  reduce account-language transliteration surprises, but needs live examples
  before calling the language issue closed.
- **One-line lag on some songs**: even with the TTML doc loaded, the overlay sometimes shows the line just *before* the actual highlight for a beat. Could be the TTML having silent intro padding (some Apple TTML uses `<p begin="00:00.001">` on first vocal but Music's scroll engine doesn't start moving until a few hundred ms later).
- **Untimed estimate is not true sync**: plain lyrics now move line by line in equal estimated slots, but without provider timing this is still duration-based. It should feel calmer than word-fill, not perfectly match the artist's phrasing.
- **Plain Apple document completeness**: once Apple Music web returns any
  document, the overlay preserves it instead of replacing it with AX. If a
  future live case proves Apple returned a partial plain document, add an
  explicit completeness heuristic before allowing fallback replacement.
- **Smoothness still lacks a hitch trace**: the clean driven sample validates state recovery and non-syllable rendering, but it is still a 30s usage sample. Use SwiftUI, Animation Hitches, or Time Profiler evidence before claiming the overlay is fully jitter-free.
- **AppleScript error detail**: `AppleScript error: nil` was a diagnostics
  quality problem. AppleScript failures now log number/message fallback details
  so future live runs can separate harmless Music.app churn from real snapshot
  failures.

## Next steps, ranked

1. **Validate syllable progress in live driven runs** — the overlay now uses syllable timing, but it still needs driven evidence across seek/scrub and language-variant cases before we call the one-line lag solved.
2. **Keep seek watchdog proof fresh** — repeat `--live --drive-music` when changing `PlayerController`, `PlaybackClock`, or `LyricsSyncEngine`, and compare `SEEK_DETECTED` / `Live tick resync` lines against the run ledger summary. The latest clean proof is `20260525-142048Z-live-Direct-Sample-52adb7a`.
3. **Improve catalog ID resolution further** —
   - Loosen search picker: accept duration ±3s by default and match on normalized-title containment when exact equality misses.
   - If AppleScript URL is missing, try `cloud universal id` from AppleScript and look up `/v1/catalog/{sf}/songs?filter[equivalents]={id}`.
4. **Storefront language preference** — keep the original-language TTML default explicit. Add a visible setting only if live examples prove users need transliterated/localized lyrics.
5. **Switch the AX fallback to a "translation only" role** — once the web path is reliable, the AX scrape is purely for AppleScript-library tracks that have no catalog ID. Could degrade gracefully without showing it at all when fallback is off.

## Parked

- **MusicKit `MusicCatalogResourceRequest`** for lyrics — requires an Apple Developer team to mint a long-lived developer token. The web-player scrape pattern dodges that. Keep as a fallback path if Apple ever locks down the `index~XXX.js` token.
- **MediaRemote private framework** — gated on SIP-disabled entitlement and unlikely to carry timed-lyrics payloads. Exploration-only on the user's own machine.
- **Syllable text segmentation** — the overlay uses syllable timings for progress, but still masks the whole line rather than laying out each syllable as a separate selectable segment. Keep deeper typography work parked until live evidence shows the mask is not enough.

## Reference repos consulted

Located in `.tmp/`, not committed:

- `Manzana-Apple-Music-Lyrics` — confirmed the developer-token scrape + endpoint shape we adopted.
- `apple-music-downloader` — confirmed `Bearer` + `media-user-token` header pattern.
- `YouLyPlus` — runs inside the Music web player so it gets the token for free; surfaced the cleaner `/songs/{id}/syllable-lyrics?extend=ttmlLocalizations` endpoint and `hasLyrics` skip heuristic.
- `LyricFever` — uses LRCLIB / NetEase / Spotify only; doesn't touch the Apple Music web API.
- `applemusic-like-lyrics` — frontend monorepo; not relevant to the auth/fetch path.

import AppKit
import Foundation
import OSLog
import Observation

enum OverlayWidthPreset: String, CaseIterable, Identifiable, Sendable {
    case compact
    case medium
    case wide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact:
            "Compact"
        case .medium:
            "Medium"
        case .wide:
            "Wide"
        }
    }

    var width: Double {
        switch self {
        case .compact:
            420
        case .medium:
            520
        case .wide:
            620
        }
    }
}

enum OverlayContentState: Equatable, Sendable {
    case loading
    case ready
    case unavailable
    case failed(String)

    var displayName: String {
        switch self {
        case .loading:
            "Loading"
        case .ready:
            "Ready"
        case .unavailable:
            "Unavailable"
        case .failed:
            "Error"
        }
    }
}

enum LyricsOverlayLineRole: Equatable, Sendable {
    case previous
    case active
    case next
}

struct LyricsOverlayLine: Equatable, Identifiable, Sendable {
    let line: LyricLine
    let role: LyricsOverlayLineRole
    let translationText: String?

    var id: LyricLine.ID {
        line.id
    }
}

struct LyricsOverlaySnapshot: Equatable, Sendable {
    let contentState: OverlayContentState
    let statusText: String
    let trackText: String
    let lyricText: String
    let activeLine: LyricLine?
    let effectiveLyricTime: TimeInterval
    let lyricClockReferenceDate: Date
    let isLyricClockRunning: Bool
    let lyricWindow: [LyricsOverlayLine]
    let translationText: String?
    let attributionText: String
    let widthPreset: OverlayWidthPreset
}

struct LyricsOverlaySnapshotBuilder: Sendable {
    private let syncEngine = LyricsSyncEngine()

    static func activeSyllableIndex(in line: LyricLine, at effectiveLyricTime: TimeInterval) -> Int? {
        guard !line.syllables.isEmpty else {
            return nil
        }

        if let activeIndex = line.syllables.firstIndex(where: { syllable in
            syllable.startTime <= effectiveLyricTime && effectiveLyricTime < syllable.endTime
        }) {
            return activeIndex
        }

        return line.syllables.lastIndex { syllable in
            syllable.startTime <= effectiveLyricTime
        }
    }

    static func timedLineProgress(in line: LyricLine, at effectiveLyricTime: TimeInterval) -> Double? {
        guard line.startTime != nil else {
            return nil
        }

        if !line.syllables.isEmpty {
            return syllableProgress(in: line.syllables, at: effectiveLyricTime)
        }

        guard let startTime = line.startTime,
              let endTime = line.endTime,
              endTime > startTime else {
            return nil
        }

        return clampedProgress((effectiveLyricTime - startTime) / (endTime - startTime))
    }

    static func shouldRenderKaraokeProgress(for line: LyricLine) -> Bool {
        line.startTime != nil && !line.syllables.isEmpty
    }

    func makeSnapshot(
        contentState: OverlayContentState,
        playerState: PlayerState,
        lyricsDocument: LyricsDocument,
        translation: LyricTranslation,
        showsTranslation: Bool,
        widthPreset: OverlayWidthPreset,
        lyricOffsetSeconds: Double = 0
    ) -> LyricsOverlaySnapshot {
        let effectiveLyricTime = playerState.elapsedTime + lyricOffsetSeconds + lyricsDocument.offsetCorrection
        let statusText: String
        let lyricText: String
        let attributionText: String
        var activeLine: LyricLine?
        var lyricWindow: [LyricsOverlayLine] = []
        var translationText: String?

        switch contentState {
        case .loading:
            statusText = "Preparing lyrics"
            lyricText = "Listening for a mock playback snapshot..."
            attributionText = "Mock pipeline"
        case .unavailable:
            statusText = playerState.statusLine
            lyricText = "Lyrics unavailable for this track"
            translationText = showsTranslation ? "Translation will wait for lyrics" : nil
            attributionText = "No provider result"
        case .failed(let message):
            statusText = "Provider error"
            lyricText = message
            attributionText = "Mock failure state"
        case .ready:
            statusText = playerState.statusLine
            activeLine = syncEngine.activeLine(
                in: lyricsDocument,
                at: playerState.elapsedTime + lyricOffsetSeconds,
                duration: playerState.track?.duration
            )
            lyricText = activeLine?.text ?? "Lyrics unavailable"
            translationText = activeLine.flatMap { line in
                showsTranslation ? translation.text(for: line) : nil
            }
            lyricWindow = Self.lyricWindow(
                in: lyricsDocument,
                activeLine: activeLine,
                effectiveLyricTime: effectiveLyricTime,
                translation: translation,
                showsTranslation: showsTranslation
            )
            attributionText = Self.attributionText(
                lyricsDocument: lyricsDocument,
                translation: translation,
                showsTranslation: showsTranslation
            )
        }

        return LyricsOverlaySnapshot(
            contentState: contentState,
            statusText: statusText,
            trackText: playerState.track?.displayTitle ?? "Waiting for playback",
            lyricText: lyricText,
            activeLine: activeLine,
            effectiveLyricTime: effectiveLyricTime,
            lyricClockReferenceDate: playerState.updatedAt,
            isLyricClockRunning: playerState.playbackStatus == .playing,
            lyricWindow: lyricWindow,
            translationText: translationText,
            attributionText: attributionText,
            widthPreset: widthPreset
        )
    }

    private static func lyricWindow(
        in document: LyricsDocument,
        activeLine: LyricLine?,
        effectiveLyricTime: TimeInterval,
        translation: LyricTranslation,
        showsTranslation: Bool
    ) -> [LyricsOverlayLine] {
        guard !document.lines.isEmpty else {
            return []
        }

        guard let activeLine,
              let activeIndex = document.lines.firstIndex(where: { $0.id == activeLine.id }) else {
            guard document.isTimed,
                  let nextIndex = document.lines.firstIndex(where: { line in
                      guard let startTime = line.startTime else { return false }
                      return startTime > effectiveLyricTime
                  }) else {
                return []
            }
            return [
                LyricsOverlayLine(
                    line: document.lines[nextIndex],
                    role: .next,
                    translationText: nil
                )
            ]
        }

        let lowerBound = max(0, activeIndex - 1)
        let upperBound = min(document.lines.count - 1, activeIndex + 1)

        return (lowerBound...upperBound).map { index in
            let role: LyricsOverlayLineRole
            if index < activeIndex {
                role = .previous
            } else if index == activeIndex {
                role = .active
            } else {
                role = .next
            }

            let line = document.lines[index]
            return LyricsOverlayLine(
                line: line,
                role: role,
                translationText: role == .active && showsTranslation ? translation.text(for: line) : nil
            )
        }
    }

    private static func syllableProgress(
        in syllables: [LyricSyllable],
        at effectiveLyricTime: TimeInterval
    ) -> Double? {
        var firstStart: TimeInterval?
        var lastEnd: TimeInterval?
        var totalWeight = 0.0

        for syllable in syllables {
            firstStart = min(firstStart ?? syllable.startTime, syllable.startTime)
            lastEnd = max(lastEnd ?? syllable.endTime, syllable.endTime)
            totalWeight += Double(max(1, syllable.text.count))
        }

        guard let firstStart,
              let lastEnd,
              lastEnd > firstStart,
              totalWeight > 0 else {
            return nil
        }

        if effectiveLyricTime <= firstStart {
            return 0
        }
        if effectiveLyricTime >= lastEnd {
            return 1
        }

        var completedWeight = 0.0
        for syllable in syllables {
            let weight = Double(max(1, syllable.text.count))
            if effectiveLyricTime >= syllable.endTime {
                completedWeight += weight
                continue
            }

            if effectiveLyricTime <= syllable.startTime {
                return clampedProgress(completedWeight / totalWeight)
            }

            let duration = max(0.001, syllable.endTime - syllable.startTime)
            let syllableProgress = clampedProgress((effectiveLyricTime - syllable.startTime) / duration)
            return clampedProgress((completedWeight + weight * syllableProgress) / totalWeight)
        }

        return 1
    }

    private static func clampedProgress(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func attributionText(
        lyricsDocument: LyricsDocument,
        translation: LyricTranslation,
        showsTranslation: Bool
    ) -> String {
        let sourceLanguageIdentifier = translation.sourceLanguageIdentifier
            ?? lyricsDocument.sourceLanguageIdentifier
        guard let sourceLanguageIdentifier else {
            return lyricsDocument.attribution
        }

        let sourceName = localizedLanguageName(for: sourceLanguageIdentifier)
        guard showsTranslation,
              !sameLanguageFamily(sourceLanguageIdentifier, translation.targetLanguageIdentifier) else {
            return "\(lyricsDocument.attribution) - \(sourceName)"
        }

        let targetName = localizedLanguageName(for: translation.targetLanguageIdentifier)
        return "\(lyricsDocument.attribution) - \(sourceName) to \(targetName)"
    }

    private static func sameLanguageFamily(_ lhs: String, _ rhs: String) -> Bool {
        let lhsLanguage = Locale.Language(identifier: lhs)
        let rhsLanguage = Locale.Language(identifier: rhs)
        if lhsLanguage.minimalIdentifier == rhsLanguage.minimalIdentifier {
            return true
        }
        guard let lhsCode = lhsLanguage.languageCode?.identifier,
              let rhsCode = rhsLanguage.languageCode?.identifier else {
            return false
        }
        return lhsCode == rhsCode
    }

    private static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

@MainActor
@Observable
final class AppState {
    var isOverlayVisible = false
    var isMockPreviewRunning = false
    var isLiveModeRunning = false
    var providerRuntimeState: ProviderRuntimeState = .idle
    var translationRuntimeState: TranslationRuntimeState = .idle
    var overlayContentState: OverlayContentState = .ready
    var playerState: PlayerState
    var nowPlayingArtwork: NSImage?
    var musicVolume: Int?
    var isPlaybackCommandInFlight = false
    private(set) var nowPlayingArtworkTrackID: String?
    var lyricsDocument: LyricsDocument
    var translation: LyricTranslation
    var runtimeFeatureFlags = RuntimeFeatureFlags.architectureDefault
    var showsTranslation: Bool
    var isLyricsOverlayExpanded: Bool
    var preferredTranslationLanguageIdentifier: String
    var overlayWidthPreset: OverlayWidthPreset
    var reduceHiddenMemoryUsage: Bool
    /// Global default offset used when the current track has no remembered
    /// per-track offset. Positive values advance lyrics; negative delay them.
    var lyricOffsetSeconds: Double
    /// Remembered offsets per `NowPlayingTrack.id`. Persisted so once a track
    /// is tuned, the offset is automatic on next play.
    private(set) var perTrackOffsets: [String: Double]
    /// High-frequency elapsed-time updates from the playback tick. Kept
    /// separate from `playerState` so the menu (which observes only stable
    /// fields like track/status) doesn't get re-rendered on every tick —
    /// macOS MenuBarExtra(.menu) re-renders interrupt mouse tracking.
    private(set) var liveElapsedTime: TimeInterval = 0
    private(set) var liveElapsedUpdatedAt: Date = .distantPast

    private let snapshotBuilder = LyricsOverlaySnapshotBuilder()
    private let userDefaults: UserDefaults
    private static let perTrackOffsetsKey = "perTrackLyricOffsets"
    private static let preferredTranslationLanguageIdentifierKey = "preferredTranslationLanguageIdentifier"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        playerState = MockMusicAppBridge.previewState
        lyricsDocument = MockLyricsProvider.previewDocument

        let languageIdentifier = Self.validStoredLanguageIdentifier(
            userDefaults.string(forKey: Self.preferredTranslationLanguageIdentifierKey)
        ) ?? Self.systemLanguageIdentifier
        preferredTranslationLanguageIdentifier = languageIdentifier
        userDefaults.set(languageIdentifier, forKey: Self.preferredTranslationLanguageIdentifierKey)
        translation = MockTranslationProvider.previewTranslation(targetLanguageIdentifier: languageIdentifier)
        showsTranslation = userDefaults.object(forKey: "showTranslation") as? Bool ?? true
        isLyricsOverlayExpanded = userDefaults.object(forKey: "lyricsOverlayExpanded") as? Bool ?? true
        overlayWidthPreset = OverlayWidthPreset(
            rawValue: userDefaults.string(forKey: "overlayWidthPreset") ?? OverlayWidthPreset.medium.rawValue
        ) ?? .medium
        reduceHiddenMemoryUsage = userDefaults.object(forKey: "reduceHiddenMemoryUsage") as? Bool ?? true
        lyricOffsetSeconds = userDefaults.object(forKey: "lyricOffsetSeconds") as? Double ?? 0
        perTrackOffsets = (userDefaults.dictionary(forKey: Self.perTrackOffsetsKey) as? [String: Double]) ?? [:]
        liveElapsedTime = playerState.elapsedTime
        liveElapsedUpdatedAt = playerState.updatedAt
    }

    /// Effective offset used for sync — per-track if known, otherwise the
    /// global default. Computed, not stored, so it tracks player state.
    var effectiveLyricOffsetSeconds: Double {
        if let trackID = playerState.track?.id, let perTrack = perTrackOffsets[trackID] {
            return perTrack
        }
        return lyricOffsetSeconds
    }

    /// Effective elapsed time used by lyric sync paths. During live or mock
    /// preview the playback tick updates this without invalidating broader
    /// menu state; otherwise the stable player snapshot is authoritative.
    var effectiveElapsedTime: TimeInterval {
        if isLiveModeRunning || isMockPreviewRunning {
            return liveElapsedTime
        }
        return playerState.elapsedTime
    }

    /// Where the current effective offset comes from. Used by the menu so
    /// the user knows whether their nudge will affect just this track or
    /// the global default.
    enum LyricOffsetScope: Equatable {
        case perTrack(trackID: String)
        case global
    }

    var lyricOffsetScope: LyricOffsetScope {
        if let trackID = playerState.track?.id, perTrackOffsets[trackID] != nil {
            return .perTrack(trackID: trackID)
        }
        return .global
    }

    var overlaySnapshot: LyricsOverlaySnapshot {
        // Build an effective PlayerState that substitutes the high-frequency
        // tick value in for elapsedTime, so the overlay reflects smooth
        // playback while menu-observed fields stay stable.
        let effectivePlaybackStatus = isOverlayVisible ? playerState.playbackStatus : .paused
        let effectiveState = PlayerState(
            playbackStatus: effectivePlaybackStatus,
            track: playerState.track,
            elapsedTime: effectiveElapsedTime,
            updatedAt: liveElapsedUpdatedAt
        )
        return snapshotBuilder.makeSnapshot(
            contentState: overlayContentState,
            playerState: effectiveState,
            lyricsDocument: lyricsDocument,
            translation: translation,
            showsTranslation: showsTranslation,
            widthPreset: overlayWidthPreset,
            lyricOffsetSeconds: effectiveLyricOffsetSeconds
        )
    }

    var preferredTranslationLanguageName: String {
        Self.localizedLanguageName(for: preferredTranslationLanguageIdentifier)
    }

    var lyricsSourceLanguageName: String {
        guard let sourceLanguageIdentifier = lyricsDocument.sourceLanguageIdentifier else {
            return "Unknown"
        }
        return Self.localizedLanguageName(for: sourceLanguageIdentifier)
    }

    var pendingTranslationDownload: (source: String, target: String)? {
        translationRuntimeState.downloadLanguages
    }

    // MARK: - Lyric offset

    /// Nudges the effective offset. If a track is playing, the nudge is
    /// stored against that track; otherwise it modifies the global default.
    func nudgeLyricOffset(by delta: Double) {
        let rounded = { (v: Double) in ((v * 100).rounded() / 100) }
        if let trackID = playerState.track?.id {
            let base = perTrackOffsets[trackID] ?? lyricOffsetSeconds
            let next = rounded(base + delta)
            perTrackOffsets[trackID] = next
            userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
            AppTelemetry.settings.info("Per-track lyric offset for track set to \(next)")
        } else {
            lyricOffsetSeconds = rounded(lyricOffsetSeconds + delta)
            userDefaults.set(lyricOffsetSeconds, forKey: "lyricOffsetSeconds")
            AppTelemetry.settings.info("Global lyric offset nudged to \(self.lyricOffsetSeconds)")
        }
    }

    /// Clears the per-track offset for the current track (falls back to
    /// global) if one exists; otherwise resets the global default to 0.
    func resetLyricOffset() {
        if let trackID = playerState.track?.id, perTrackOffsets[trackID] != nil {
            perTrackOffsets.removeValue(forKey: trackID)
            userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
            AppTelemetry.settings.info("Per-track lyric offset cleared")
        } else {
            lyricOffsetSeconds = 0
            userDefaults.set(0, forKey: "lyricOffsetSeconds")
            AppTelemetry.settings.info("Global lyric offset reset")
        }
    }

    /// Wipes every remembered per-track offset. Global stays.
    func clearAllPerTrackOffsets() {
        perTrackOffsets.removeAll()
        userDefaults.set(perTrackOffsets, forKey: Self.perTrackOffsetsKey)
        AppTelemetry.settings.info("All per-track lyric offsets cleared")
    }

    func applyPreferences(
        showsTranslation: Bool,
        preferredTranslationLanguageIdentifier: String,
        overlayWidthPreset: OverlayWidthPreset,
        reduceHiddenMemoryUsage: Bool
    ) -> Bool {
        let normalizedLanguageIdentifier = Self.validStoredLanguageIdentifier(preferredTranslationLanguageIdentifier)
            ?? Self.systemLanguageIdentifier
        let translationPreferenceChanged = self.showsTranslation != showsTranslation
            || self.preferredTranslationLanguageIdentifier != normalizedLanguageIdentifier
        self.showsTranslation = showsTranslation
        self.preferredTranslationLanguageIdentifier = normalizedLanguageIdentifier
        self.overlayWidthPreset = overlayWidthPreset
        self.reduceHiddenMemoryUsage = reduceHiddenMemoryUsage
        userDefaults.set(normalizedLanguageIdentifier, forKey: Self.preferredTranslationLanguageIdentifierKey)
        if translationPreferenceChanged {
            clearTranslation()
            setTranslationRuntimeState(showsTranslation ? .idle : .unavailable(reason: "Translation hidden"))
        }

        AppTelemetry.settings.info(
            "Preferences applied translation=\(showsTranslation) language=\(normalizedLanguageIdentifier, privacy: .public) width=\(overlayWidthPreset.rawValue, privacy: .public) reduceHiddenMemory=\(reduceHiddenMemoryUsage)"
        )
        return translationPreferenceChanged
    }

    func updatePlayerState(_ playerState: PlayerState) {
        let previousTrackID = self.playerState.track?.id
        self.playerState = playerState
        if playerState.track?.id != previousTrackID {
            nowPlayingArtwork = nil
            nowPlayingArtworkTrackID = playerState.track?.id
            if playerState.track != nil {
                clearLyricsForTrackChange()
            }
        }
        // Seed the live tick fields from the authoritative state so
        // the overlay's elapsed reflects it immediately.
        liveElapsedTime = playerState.elapsedTime
        liveElapsedUpdatedAt = playerState.updatedAt
    }

    func applyNowPlayingArtwork(_ artwork: NSImage?, forTrackID trackID: String?) {
        guard let trackID else {
            clearNowPlayingArtwork()
            return
        }
        guard playerState.track?.id == trackID else {
            AppTelemetry.performance.info("Ignoring stale now-playing artwork for track=\(NowPlayingTrack.telemetryID(for: trackID), privacy: .public)")
            return
        }

        nowPlayingArtwork = artwork
        nowPlayingArtworkTrackID = trackID
        AppTelemetry.performance.info("Now-playing artwork updated available=\(artwork != nil)")
    }

    func clearNowPlayingArtwork() {
        nowPlayingArtwork = nil
        nowPlayingArtworkTrackID = nil
    }

    private func clearLyricsForTrackChange() {
        lyricsDocument = LyricsDocument(source: .none, lines: [], isTimed: false)
        clearTranslation()
        AppTelemetry.performance.info("Lyrics document cleared for new track")
    }

    func setMusicVolume(_ volume: Int?) {
        musicVolume = volume.map(MusicPlaybackCommand.clampedVolume)
    }

    func setPlaybackCommandInFlight(_ isInFlight: Bool) {
        isPlaybackCommandInFlight = isInFlight
    }

    func setLyricsOverlayExpanded(_ isExpanded: Bool) {
        isLyricsOverlayExpanded = isExpanded
        userDefaults.set(isExpanded, forKey: "lyricsOverlayExpanded")
        AppTelemetry.windowing.info("Lyrics overlay expanded=\(isExpanded)")
    }

    /// High-frequency update — does NOT touch `playerState`, so menu/Settings
    /// observers don't re-evaluate. Called from the playback tick.
    func updateLiveElapsedTime(_ value: TimeInterval) {
        liveElapsedTime = value
        liveElapsedUpdatedAt = Date()
    }

    /// When the overlay has been hidden, the live tick is stopped to avoid
    /// wakeups. On reveal, advance once from wall-clock time so lyrics do not
    /// resume from the stale hidden timestamp while the authoritative Music.app
    /// snapshot is still being fetched.
    func resumeLiveElapsedTimeFromWallClock(now: Date = Date()) {
        guard playerState.playbackStatus == .playing,
              playerState.track != nil,
              liveElapsedUpdatedAt != .distantPast else {
            return
        }

        let delta = now.timeIntervalSince(liveElapsedUpdatedAt)
        guard delta.isFinite, delta > 0 else {
            return
        }

        liveElapsedTime = MusicPlaybackCommand.clampedPlaybackPosition(
            liveElapsedTime + delta,
            duration: playerState.track?.duration
        )
        liveElapsedUpdatedAt = now
    }

    func setProviderRuntimeState(_ state: ProviderRuntimeState) {
        providerRuntimeState = state
        AppTelemetry.performance.info("Provider runtime state set to \(state.displayName, privacy: .public)")
    }

    func applyLyricsDocument(_ document: LyricsDocument) {
        lyricsDocument = document
        let syllableCount = document.lines.reduce(0) { total, line in
            total + line.syllables.count
        }
        AppTelemetry.performance.info(
            "Lyrics document applied source=\(document.source.rawValue, privacy: .public) timed=\(document.isTimed) line_count=\(document.lines.count) syllable_count=\(syllableCount)"
        )
    }

    func applyTranslation(_ translation: LyricTranslation) {
        self.translation = translation
    }

    func clearTranslation() {
        translation = LyricTranslation(
            targetLanguageIdentifier: preferredTranslationLanguageIdentifier,
            sourceLanguageIdentifier: lyricsDocument.sourceLanguageIdentifier,
            lines: []
        )
    }

    func setTranslationRuntimeState(_ state: TranslationRuntimeState) {
        translationRuntimeState = state
        AppTelemetry.performance.info("Translation runtime state set to \(state.displayName, privacy: .public)")
    }

    func applyProviderReady() {
        providerRuntimeState = .ready
        overlayContentState = .ready
        AppTelemetry.performance.info("Provider pipeline ready")
    }

    func applyProviderUnavailable() {
        providerRuntimeState = .unavailable
        overlayContentState = .unavailable
        AppTelemetry.performance.info("Provider pipeline unavailable")
    }

    func applyProviderFailure(_ message: String) {
        providerRuntimeState = .failed(message)
        overlayContentState = .failed(message)
        AppTelemetry.performance.info("Provider pipeline failed")
    }

    func setMockPreviewRunning(_ isRunning: Bool) {
        isMockPreviewRunning = isRunning
    }

    func setLiveModeRunning(_ isRunning: Bool) {
        isLiveModeRunning = isRunning
    }

    func resetMockPlayback() {
        updatePlayerState(MockMusicAppBridge.previewState)
        overlayContentState = .ready
        AppTelemetry.performance.info("Mock playback snapshot reset")
    }

    func setOverlayContentState(_ state: OverlayContentState) {
        overlayContentState = state
        AppTelemetry.performance.info("Mock overlay state set to \(state.displayName, privacy: .public)")
    }

    static var systemLanguageIdentifier: String {
        let preferred = Locale.preferredLanguages.first
        return LyricsDocument.normalizedLanguageIdentifier(preferred)
            ?? Locale.current.language.minimalIdentifier
    }

    static func validStoredLanguageIdentifier(_ rawValue: String?) -> String? {
        guard let normalized = LyricsDocument.normalizedLanguageIdentifier(rawValue) else {
            return nil
        }
        let firstComponent = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard (2...3).contains(firstComponent.count),
              firstComponent.allSatisfy({ $0.isLetter }) else {
            return nil
        }
        return normalized
    }

    static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

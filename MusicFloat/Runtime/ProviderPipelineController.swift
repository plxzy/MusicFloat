import Foundation
import OSLog

@MainActor
final class ProviderPipelineController {
    /// Backstop poll cadence in case the AX observer doesn't fire (Music not
    /// running yet, panel closed, observer attach failed). Push notifications
    /// from `MusicAppAXObserver` drive the common case at ~event latency.
    private static let integratedVisibleLyricsRefreshInterval: TimeInterval = 0.75
    /// Cooldown after an AX-observer-driven refresh, so a burst of
    /// notifications doesn't translate into a burst of full AX traversals.
    private static let observerDrivenCooldown: TimeInterval = 0.5
    private static let visibleLyricsMissBackoffThreshold = 3
    private static let visibleLyricsMissBackoffInterval: TimeInterval = 1.25

    private let lyricsProvider: any LyricsProvider
    private let translationProvider: any TranslationProvider
    private let mediaCache: any MediaCache
    private var loadTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var loadRequestID: UUID?
    private var translationRequestID: UUID?
    private var loadingTrackID: String?
    private var lastIntegratedVisibleLyricsRefresh = Date.distantPast
    private var consecutiveIntegratedVisibleLyricsMisses = 0
    private let axObserver = MusicAppAXObserver()
    private weak var observedAppState: AppState?

    init(
        lyricsProvider: any LyricsProvider,
        translationProvider: any TranslationProvider,
        mediaCache: any MediaCache = EphemeralMediaCache()
    ) {
        self.lyricsProvider = lyricsProvider
        self.translationProvider = translationProvider
        self.mediaCache = mediaCache
    }

    func prepareOverlayContent(appState: AppState) {
        AppTelemetry.measure("ProviderPipelineController.prepareOverlayContent") {
            guard let track = appState.playerState.track else {
                appState.clearTranslation()
                appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                appState.applyProviderUnavailable()
                return
            }
            let requestedTrackID = track.id

            guard loadTask == nil else {
                if loadingTrackID == requestedTrackID {
                    AppTelemetry.performance.notice("Provider pipeline duplicate load ignored track=\(NowPlayingTrack.telemetryID(for: requestedTrackID), privacy: .public)")
                }
                return
            }

            AppTelemetry.performance.info("Provider pipeline load started")
            appState.setProviderRuntimeState(.loading)
            appState.setOverlayContentState(.loading)
            cancelTranslationTask(appState: appState)
            loadingTrackID = requestedTrackID
            let requestID = UUID()
            loadRequestID = requestID

            loadTask = Task { @MainActor [weak self, weak appState, track] in
                await AppTelemetry.measure("ProviderPipelineController.prepareOverlayContent.load") {
                    guard let self, let appState else {
                        return
                    }

                    defer {
                        if self.loadRequestID == requestID {
                            self.loadingTrackID = nil
                            self.loadTask = nil
                            self.loadRequestID = nil
                        }
                    }
                    guard !Task.isCancelled, self.loadRequestID == requestID else { return }

                    let startedAt = Date()
                    let lyricsResult = await self.lyricsProvider.lyrics(for: track)
                    AppTelemetry.performance.notice(
                        "Provider lyrics load finished track=\(NowPlayingTrack.telemetryID(for: requestedTrackID), privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)"
                    )
                    guard !Task.isCancelled, self.loadRequestID == requestID else {
                        return
                    }
                    guard appState.playerState.track?.id == requestedTrackID else {
                        AppTelemetry.performance.info("Provider result ignored because live track changed before lyrics completed")
                        return
                    }

                    switch lyricsResult {
                    case .available(let document):
                        appState.applyLyricsDocument(document)
                        appState.applyProviderReady()
                        appState.clearTranslation()
                        self.startTranslation(
                            for: document,
                            requestedTrackID: requestedTrackID,
                            appState: appState
                        )
                    case .unavailable:
                        appState.clearTranslation()
                        appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                        appState.applyProviderUnavailable()
                    case .failed(let message):
                        appState.clearTranslation()
                        appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                        appState.applyProviderFailure(message)
                    }
                }
            }
        }
    }

    /// Cancels any in-flight load and starts a fresh one. Intended for the
    /// "track changed" signal in live mode.
    func refreshOverlayContent(appState: AppState) {
        if let trackID = appState.playerState.track?.id,
           loadTask != nil,
           loadingTrackID == trackID {
            AppTelemetry.performance.notice("Provider refresh skipped; same track already loading track=\(NowPlayingTrack.telemetryID(for: trackID), privacy: .public)")
            return
        }
        cancelLoadTask()
        cancelTranslationTask(appState: appState)
        lastIntegratedVisibleLyricsRefresh = .distantPast
        consecutiveIntegratedVisibleLyricsMisses = 0
        prepareOverlayContent(appState: appState)
    }

    func refreshTranslation(appState: AppState) {
        cancelTranslationTask(appState: appState)
        appState.clearTranslation()
        guard loadTask == nil else {
            appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for current lyrics"))
            return
        }
        guard let requestedTrackID = appState.playerState.track?.id else {
            appState.setTranslationRuntimeState(.unavailable(reason: "No current track"))
            return
        }
        startTranslation(
            for: appState.lyricsDocument,
            requestedTrackID: requestedTrackID,
            appState: appState
        )
    }

    /// Live mode can receive transient empty playerInfo payloads while Music
    /// is paused or changing state. Preserve the current document unless the
    /// playback layer has confirmed a real track identity change.
    func refreshOverlayContentForLiveTrack(appState: AppState) {
        guard appState.playerState.track != nil else {
            cancelInFlightLoadPreservingState(appState: appState)
            AppTelemetry.performance.info("Live provider refresh skipped for empty track payload")
            return
        }
        guard appState.isOverlayVisible || appState.runtimeFeatureFlags.allowsHiddenProviderRefresh else {
            cancelInFlightLoadPreservingState(appState: appState)
            AppTelemetry.performance.info("Live track refresh deferred while overlay hidden")
            return
        }
        refreshOverlayContent(appState: appState)
    }

    func resumeVisibleLiveOverlayContent(appState: AppState) {
        lastIntegratedVisibleLyricsRefresh = .distantPast
        consecutiveIntegratedVisibleLyricsMisses = 0

        guard appState.isOverlayVisible,
              appState.isLiveModeRunning else {
            return
        }

        if !appState.lyricsDocument.lines.isEmpty,
           appState.lyricsDocument.source != .none {
            if appState.providerRuntimeState == .idle {
                appState.applyProviderReady()
            }
            refreshIntegratedVisibleLyrics(appState: appState)
            if appState.translation.lines.isEmpty,
               let trackID = appState.playerState.track?.id {
                startTranslation(for: appState.lyricsDocument, requestedTrackID: trackID, appState: appState)
            }
            AppTelemetry.performance.info("Live provider resume reused visible lyrics document")
            return
        }

        refreshOverlayContentForLiveTrack(appState: appState)
    }

    func cancelInFlightLoadPreservingState(appState: AppState) {
        guard loadTask != nil || translationTask != nil else { return }
        AppTelemetry.performance.info("Provider pipeline load cancelled because live track payload is empty")
        cancelLoadTask()
        cancelTranslationTask(appState: appState)
    }

    func refreshIntegratedVisibleLyrics(appState: AppState) {
        guard appState.isOverlayVisible,
              appState.isLiveModeRunning else {
            axObserver.stop()
            observedAppState = nil
            return
        }
        guard appState.providerRuntimeState != .loading else {
            axObserver.stop()
            observedAppState = nil
            return
        }

        let current = appState.lyricsDocument
        if Self.skipsIntegratedVisibleLyricsRefresh(for: current) {
            // Authoritative document straight from Apple. Timed TTML is clock
            // ground truth; line-only/plain Apple documents should stay
            // sentence-first instead of being replaced by a jittery one-line
            // AX scrape.
            axObserver.stop()
            observedAppState = nil
            return
        }

        startAXObserverIfNeeded(appState: appState)
        performIntegratedVisibleLyricsRefresh(
            appState: appState,
            minimumInterval: Self.integratedVisibleLyricsRefreshInterval
        )
    }

    private func performIntegratedVisibleLyricsRefresh(
        appState: AppState,
        minimumInterval: TimeInterval
    ) {
        guard appState.isOverlayVisible,
              appState.isLiveModeRunning else {
            return
        }
        guard appState.providerRuntimeState != .loading else {
            return
        }

        let now = Date()
        let effectiveMinimumInterval = Self.integratedVisibleLyricsMinimumInterval(
            base: minimumInterval,
            consecutiveMisses: consecutiveIntegratedVisibleLyricsMisses
        )
        guard now.timeIntervalSince(lastIntegratedVisibleLyricsRefresh) >= effectiveMinimumInterval else {
            return
        }
        lastIntegratedVisibleLyricsRefresh = now

        let current = appState.lyricsDocument
        if Self.skipsIntegratedVisibleLyricsRefresh(for: current) {
            return
        }
        if current.source == .lrclib, current.isTimed {
            // Calibration path: AX gives us ground-truth current line. Align
            // the LRC clock to it instead of replacing the (multi-line, timed)
            // document with a single-line scrape.
            guard let axText = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineText() else {
                noteIntegratedVisibleLyricsMiss()
                return
            }
            noteIntegratedVisibleLyricsHit()
            calibrateLRCDocument(current: current, visibleLineText: axText, appState: appState)
            return
        }

        guard let document = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument() else {
            noteIntegratedVisibleLyricsMiss()
            return
        }
        noteIntegratedVisibleLyricsHit()

        guard document.lines.first?.text != current.lines.first?.text else {
            return
        }

        appState.applyLyricsDocument(document)
        appState.applyProviderReady()
        refreshTranslation(appState: appState)
        AppTelemetry.performance.info("Music.app UI lyric line refreshed")
    }

    static func integratedVisibleLyricsMinimumInterval(
        base: TimeInterval,
        consecutiveMisses: Int
    ) -> TimeInterval {
        guard consecutiveMisses >= visibleLyricsMissBackoffThreshold else {
            return base
        }
        return max(base, visibleLyricsMissBackoffInterval)
    }

    private func noteIntegratedVisibleLyricsMiss() {
        consecutiveIntegratedVisibleLyricsMisses = min(
            consecutiveIntegratedVisibleLyricsMisses + 1,
            Self.visibleLyricsMissBackoffThreshold
        )
    }

    private func noteIntegratedVisibleLyricsHit() {
        consecutiveIntegratedVisibleLyricsMisses = 0
    }

    private func calibrateLRCDocument(
        current: LyricsDocument,
        visibleLineText: String,
        appState: AppState
    ) {
        let elapsed = appState.effectiveElapsedTime
        guard let calibrated = Self.calibratedLRCDocument(
            current: current,
            visibleLineText: visibleLineText,
            elapsed: elapsed
        ) else {
            return
        }

        appState.applyLyricsDocument(calibrated)
        AppTelemetry.performance.info("LRC calibrated offset=\(calibrated.offsetCorrection) (was \(current.offsetCorrection))")
    }

    static func calibratedLRCDocument(
        current: LyricsDocument,
        visibleLineText axText: String,
        elapsed: TimeInterval
    ) -> LyricsDocument? {
        guard elapsed > 0 else { return nil }

        let normalizedAX = Self.normalizeForMatch(axText)
        guard !normalizedAX.isEmpty else { return nil }

        let candidates = current.lines.compactMap { line -> (LyricLine, TimeInterval)? in
            guard let start = line.startTime else { return nil }
            guard Self.normalizeForMatch(line.text) == normalizedAX else { return nil }
            return (line, start)
        }
        guard let (matched, matchedStart) = candidates.min(by: {
            abs($0.1 - (elapsed + current.offsetCorrection)) < abs($1.1 - (elapsed + current.offsetCorrection))
        }) else {
            return nil
        }

        let newOffset = matchedStart - elapsed
        // Reject implausibly large offsets — usually a chorus-line collision
        // where the AX text matched the wrong repeat.
        guard abs(newOffset) <= 10 else {
            AppTelemetry.performance.info(
                "LRC calibration rejected offset=\(newOffset, privacy: .public) candidates=\(candidates.count, privacy: .public) lineLength=\(matched.text.count, privacy: .public)"
            )
            return nil
        }
        guard abs(newOffset - current.offsetCorrection) > 0.05 else {
            return nil
        }

        return current.withOffsetCorrection(newOffset)
    }

    static func skipsIntegratedVisibleLyricsRefresh(for document: LyricsDocument) -> Bool {
        document.source == .appleMusicWeb
    }

    private static func normalizeForMatch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func startAXObserverIfNeeded(appState: AppState) {
        guard observedAppState !== appState else { return }
        observedAppState = appState
        axObserver.start { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.performIntegratedVisibleLyricsRefresh(
                appState: appState,
                minimumInterval: Self.observerDrivenCooldown
            )
        }
    }

    func stopHiddenWork(appState: AppState) {
        axObserver.stop()
        observedAppState = nil
        lastIntegratedVisibleLyricsRefresh = .distantPast
        consecutiveIntegratedVisibleLyricsMisses = 0
        cancelTranslationTask(appState: appState)

        if loadTask != nil {
            AppTelemetry.performance.info("Provider pipeline load cancelled while overlay hidden")
        }
        cancelLoadTask()
        appState.setProviderRuntimeState(.idle)
    }

    private func startTranslation(
        for document: LyricsDocument,
        requestedTrackID: String,
        appState: AppState
    ) {
        guard appState.showsTranslation else {
            appState.setTranslationRuntimeState(.unavailable(reason: "Translation hidden"))
            return
        }
        guard translationTask == nil else { return }

        let requestID = UUID()
        translationRequestID = requestID
        appState.setTranslationRuntimeState(.checkingAvailability)
        let targetLanguageIdentifier = appState.preferredTranslationLanguageIdentifier
        let translationCacheKey = Self.translationCacheKey(
            providerIdentifier: translationProvider.displayName,
            targetLanguageIdentifier: targetLanguageIdentifier,
            document: document
        )
        AppTelemetry.performance.notice(
            "Translation requested track=\(NowPlayingTrack.telemetryID(for: requestedTrackID), privacy: .public) target=\(targetLanguageIdentifier, privacy: .public) lines=\(document.lines.count, privacy: .public)"
        )
        translationTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            defer {
                if self.translationRequestID == requestID {
                    self.translationTask = nil
                    self.translationRequestID = nil
                }
            }

            @MainActor func isCurrentRequest() -> Bool {
                !Task.isCancelled
                    && self.translationRequestID == requestID
                    && appState.playerState.track?.id == requestedTrackID
                    && appState.preferredTranslationLanguageIdentifier == targetLanguageIdentifier
                    && appState.showsTranslation
                    && appState.lyricsDocument.hasSameTranslationContent(as: document)
            }

            guard isCurrentRequest() else { return }
            let cachedTranslation = await self.cachedTranslation(for: translationCacheKey)
            guard isCurrentRequest() else { return }
            if let cachedTranslation {
                AppTelemetry.performance.notice(
                    "Translation cache hit target=\(cachedTranslation.targetLanguageIdentifier, privacy: .public) lines=\(cachedTranslation.lines.count, privacy: .public)"
                )
                appState.applyTranslation(cachedTranslation)
                appState.setTranslationRuntimeState(.ready)
                return
            }

            appState.setTranslationRuntimeState(.translating)
            let translationResult = await self.translationProvider.translation(
                for: document,
                targetLanguageIdentifier: targetLanguageIdentifier
            )
            guard isCurrentRequest() else { return }

            switch translationResult {
            case .available(let translation):
                let sourceLanguageIdentifier = translation.sourceLanguageIdentifier ?? "unknown"
                AppTelemetry.performance.notice(
                    "Translation ready track=\(NowPlayingTrack.telemetryID(for: requestedTrackID), privacy: .public) source=\(sourceLanguageIdentifier, privacy: .public) target=\(translation.targetLanguageIdentifier, privacy: .public) lines=\(translation.lines.count, privacy: .public)"
                )
                await self.storeTranslation(translation, for: translationCacheKey)
                guard isCurrentRequest() else { return }
                appState.applyTranslation(translation)
                appState.setTranslationRuntimeState(.ready)
            case .status(let state):
                AppTelemetry.performance.notice(
                    "Translation unavailable track=\(NowPlayingTrack.telemetryID(for: requestedTrackID), privacy: .public) state=\(state.displayName, privacy: .public)"
                )
                appState.clearTranslation()
                appState.setTranslationRuntimeState(state)
            }
        }
    }

    static func translationCacheKey(
        providerIdentifier: String,
        targetLanguageIdentifier: String,
        document: LyricsDocument
    ) -> MediaCacheKey {
        var components = [
            providerIdentifier,
            LyricsDocument.normalizedLanguageIdentifier(targetLanguageIdentifier) ?? targetLanguageIdentifier,
            document.source.rawValue,
            document.isTimed ? "timed" : "plain",
            document.sourceLanguageIdentifier ?? "source-language-unknown"
        ]
        for line in document.lines {
            components.append(String(line.id))
            components.append(line.text)
            components.append(cacheComponent(line.startTime))
            components.append(cacheComponent(line.endTime))
            for syllable in line.syllables {
                components.append(syllable.text)
                components.append(cacheComponent(syllable.startTime))
                components.append(cacheComponent(syllable.endTime))
            }
        }

        return MediaCacheKey(
            namespace: .translation,
            rawValue: MediaCacheKey.redactedRawValue(prefix: "translation-v1", components: components)
        )
    }

    private static func cacheComponent(_ value: TimeInterval?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func cachedTranslation(for key: MediaCacheKey) async -> LyricTranslation? {
        guard case .data(let data)? = await mediaCache.value(for: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(LyricTranslation.self, from: data)
        } catch {
            AppTelemetry.performance.notice("Translation cache decode failed; provider will refresh")
            return nil
        }
    }

    private func storeTranslation(_ translation: LyricTranslation, for key: MediaCacheKey) async {
        do {
            let data = try JSONEncoder().encode(translation)
            await mediaCache.store(.data(data), for: key)
        } catch {
            AppTelemetry.performance.notice("Translation cache encode failed; continuing without cache")
        }
    }

    private func cancelTranslationTask(appState: AppState) {
        guard translationTask != nil else { return }
        translationTask?.cancel()
        translationTask = nil
        translationRequestID = nil
        appState.setTranslationRuntimeState(.unavailable(reason: "Translation cancelled"))
    }

    private func cancelLoadTask() {
        loadTask?.cancel()
        loadTask = nil
        loadingTrackID = nil
        loadRequestID = nil
    }
}

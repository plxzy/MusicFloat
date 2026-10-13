import XCTest
@testable import MusicFloat

@MainActor
final class ProviderPipelineControllerTests: XCTestCase {
    func testHiddenLiveOverlayDoesNotTriggerProviderRefresh() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.hiddenLiveRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.runtimeFeatureFlags = .liveAppleMusic
        appState.isOverlayVisible = false
        appState.setLiveModeRunning(true)
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: NowPlayingTrack(
                id: "track:1",
                title: "Quiet",
                artist: "MusicFloat",
                album: "Idle",
                duration: 180,
                providerName: "Apple Music"
            ),
            elapsedTime: 12,
            updatedAt: Date()
        ))

        let lyricsProvider = RecordingLyricsProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )

        controller.refreshOverlayContentForLiveTrack(appState: appState)

        XCTAssertEqual(lyricsProvider.requestedTrackIDs, [])
        XCTAssertEqual(appState.providerRuntimeState, .idle)
    }

    func testLiveTransientNilTrackPreservesReadyLyricsState() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveTransientNilTrack.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let document = LyricsDocument(
            source: .mock,
            lines: [LyricLine(id: 0, text: "Stay here", startTime: 40)],
            isTimed: true
        )
        appState.applyLyricsDocument(document)
        appState.applyProviderReady()
        appState.updatePlayerState(PlayerState(
            playbackStatus: .paused,
            track: nil,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        let lyricsProvider = RecordingLyricsProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )

        controller.refreshOverlayContentForLiveTrack(appState: appState)

        XCTAssertEqual(appState.overlayContentState, .ready)
        XCTAssertEqual(appState.providerRuntimeState, .ready)
        XCTAssertEqual(appState.lyricsDocument, document)
        XCTAssertEqual(lyricsProvider.requestedTrackIDs, [])
    }

    func testLiveResumeWithExistingLyricsDoesNotReloadProvider() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveResumeReusesLyrics.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.runtimeFeatureFlags = .liveAppleMusic
        appState.isOverlayVisible = true
        appState.setLiveModeRunning(true)
        appState.updatePlayerState(playerState(trackID: "track:resume"))
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [LyricLine(id: 0, text: "Keep current lyrics", startTime: 10)],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        )
        appState.applyLyricsDocument(document)
        appState.applyProviderReady()
        let lyricsProvider = RecordingLyricsProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )
        controller.stopHiddenWork(appState: appState)

        controller.resumeVisibleLiveOverlayContent(appState: appState)

        XCTAssertEqual(lyricsProvider.requestedTrackIDs, [])
        XCTAssertEqual(appState.providerRuntimeState, .ready)
        XCTAssertEqual(appState.overlayContentState, .ready)
        XCTAssertEqual(appState.lyricsDocument, document)
    }

    func testLiveResumeWithoutLyricsRequestsProviderRefresh() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveResumeLoadsMissingLyrics.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.runtimeFeatureFlags = .liveAppleMusic
        appState.isOverlayVisible = true
        appState.setLiveModeRunning(true)
        appState.updatePlayerState(playerState(trackID: "track:missing"))
        let lyricsProvider = RecordingLyricsProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )

        controller.resumeVisibleLiveOverlayContent(appState: appState)
        await Task.yield()

        XCTAssertEqual(lyricsProvider.requestedTrackIDs, ["track:missing"])
        XCTAssertEqual(appState.providerRuntimeState, .unavailable)
        controller.stopHiddenWork(appState: appState)
    }

    func testAppleMusicWebDocumentsSkipAXRefreshAndCalibration() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [LyricLine(id: 0, text: "Ground truth", startTime: 10)],
            isTimed: true
        )
        let plainDocument = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "First sentence", startTime: nil),
                LyricLine(id: 1, text: "Second sentence", startTime: nil)
            ],
            isTimed: false
        )

        XCTAssertTrue(ProviderPipelineController.skipsIntegratedVisibleLyricsRefresh(for: document))
        XCTAssertTrue(ProviderPipelineController.skipsIntegratedVisibleLyricsRefresh(for: plainDocument))
    }

    func testIntegratedVisibleLyricsMissesBackOffAXRefreshCadence() {
        XCTAssertEqual(
            ProviderPipelineController.integratedVisibleLyricsMinimumInterval(
                base: 0.5,
                consecutiveMisses: 2
            ),
            0.5
        )
        XCTAssertEqual(
            ProviderPipelineController.integratedVisibleLyricsMinimumInterval(
                base: 0.5,
                consecutiveMisses: 3
            ),
            1.25
        )
    }

    func testProviderPipelineAppliesLyricsReadyBeforeTranslationCompletes() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.lyricsBeforeTranslation.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: NowPlayingTrack(
                id: "track:ready",
                title: "Ready",
                artist: "MusicFloat",
                album: "Tests",
                duration: 180,
                providerName: "Apple Music"
            ),
            elapsedTime: 0,
            updatedAt: Date()
        ))
        let document = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Lyrics are ready before translation", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )
        let translationStarted = expectation(description: "Translation started")
        let translationProvider = ControllableTranslationProvider(started: translationStarted)
        let controller = ProviderPipelineController(
            lyricsProvider: ImmediateLyricsProvider(document: document),
            translationProvider: translationProvider
        )

        controller.prepareOverlayContent(appState: appState)
        await fulfillment(of: [translationStarted], timeout: 1.0)

        XCTAssertEqual(appState.providerRuntimeState, .ready)
        XCTAssertEqual(appState.overlayContentState, .ready)
        XCTAssertEqual(appState.lyricsDocument, document)
        XCTAssertNotEqual(appState.translationRuntimeState, .ready)
        translationProvider.complete(with: .status(.unavailable(reason: "Test complete")))
        controller.stopHiddenWork(appState: appState)
    }

    func testTargetLanguageChangeClearsStaleTranslation() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.targetLanguageChange.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.applyTranslation(LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: "Bonjour")]
        ))

        let changed = appState.applyPreferences(
            showsTranslation: true,
            preferredTranslationLanguageIdentifier: "es",
            overlayWidthPreset: .medium,
            reduceHiddenMemoryUsage: true
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(appState.translation.lines, [])
        XCTAssertEqual(appState.translation.targetLanguageIdentifier, "es")
    }

    func testTargetLanguageChangeCanStartFreshTranslation() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.targetLanguageRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        appState.updatePlayerState(playerState(trackID: "track:language"))
        appState.applyLyricsDocument(LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Translate me", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        ))
        _ = appState.applyPreferences(
            showsTranslation: true,
            preferredTranslationLanguageIdentifier: "es",
            overlayWidthPreset: .medium,
            reduceHiddenMemoryUsage: true
        )
        let translationRequested = expectation(description: "Translation requested")
        let translationProvider = RecordingTargetTranslationProvider(requested: translationRequested)
        let controller = ProviderPipelineController(
            lyricsProvider: RecordingLyricsProvider(),
            translationProvider: translationProvider
        )

        controller.refreshTranslation(appState: appState)
        await fulfillment(of: [translationRequested], timeout: 1.0)

        XCTAssertEqual(translationProvider.requestedTargets, ["es"])
    }

    func testTranslationRefreshWaitsForCurrentLyricsLoad() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.translationRefreshDuringLyricsLoad.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        appState.updatePlayerState(playerState(trackID: "track:loading"))
        let loadedDocument = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Fresh lyric", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )
        let lyricsStarted = expectation(description: "Lyrics load started")
        let lyricsProvider = ControllableLyricsProvider(
            document: loadedDocument,
            started: lyricsStarted
        )
        let translationRequested = expectation(description: "Translation requested after lyrics load")
        let translationProvider = RecordingTargetTranslationProvider(requested: translationRequested)
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: translationProvider
        )

        controller.prepareOverlayContent(appState: appState)
        await fulfillment(of: [lyricsStarted], timeout: 1.0)
        _ = appState.applyPreferences(
            showsTranslation: true,
            preferredTranslationLanguageIdentifier: "es",
            overlayWidthPreset: .medium,
            reduceHiddenMemoryUsage: true
        )
        controller.refreshTranslation(appState: appState)

        XCTAssertEqual(translationProvider.requestedTargets, [])
        XCTAssertEqual(
            appState.translationRuntimeState,
            .unavailable(reason: "Translation will wait for current lyrics")
        )

        lyricsProvider.complete()
        await fulfillment(of: [translationRequested], timeout: 1.0)

        XCTAssertEqual(appState.lyricsDocument, loadedDocument)
        XCTAssertEqual(translationProvider.requestedTargets, ["es"])
    }

    func testTrackChangePreventsStaleTranslationFromApplying() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.staleTranslation.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        appState.updatePlayerState(playerState(trackID: "track:old"))
        let document = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Old track lyric", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )
        let translationStarted = expectation(description: "Translation started")
        let translationReturned = expectation(description: "Translation returned")
        let translationProvider = ControllableTranslationProvider(
            started: translationStarted,
            returned: translationReturned
        )
        let controller = ProviderPipelineController(
            lyricsProvider: ImmediateLyricsProvider(document: document),
            translationProvider: translationProvider
        )

        controller.prepareOverlayContent(appState: appState)
        await fulfillment(of: [translationStarted], timeout: 1.0)
        appState.updatePlayerState(playerState(trackID: "track:new"))
        translationProvider.complete(with: .available(LyricTranslation(
            targetLanguageIdentifier: appState.preferredTranslationLanguageIdentifier,
            sourceLanguageIdentifier: "en",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: "Ancienne ligne")]
        )))
        await fulfillment(of: [translationReturned], timeout: 1.0)
        await Task.yield()

        XCTAssertEqual(appState.translation.lines, [])
        XCTAssertNotEqual(appState.translationRuntimeState, .ready)
    }

    func testTranslationResultIsCachedForSameDocumentAndTarget() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.translationCache.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        appState.updatePlayerState(playerState(trackID: "track:cache"))
        appState.applyLyricsDocument(LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Translate me once", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        ))
        _ = appState.applyPreferences(
            showsTranslation: true,
            preferredTranslationLanguageIdentifier: "fr",
            overlayWidthPreset: .medium,
            reduceHiddenMemoryUsage: true
        )
        let translationProvider = CountingTranslationProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: RecordingLyricsProvider(),
            translationProvider: translationProvider,
            mediaCache: EphemeralMediaCache(policy: MediaCachePolicy(maxEntries: 4, maxTotalCost: 4096))
        )

        controller.refreshTranslation(appState: appState)
        try await waitUntil { appState.translationRuntimeState == .ready }
        XCTAssertEqual(translationProvider.requestCount, 1)

        appState.clearTranslation()
        appState.setTranslationRuntimeState(.idle)
        controller.refreshTranslation(appState: appState)
        try await waitUntil { appState.translationRuntimeState == .ready }

        XCTAssertEqual(translationProvider.requestCount, 1)
        XCTAssertEqual(appState.translation.text(for: LyricLine(id: 0, text: "Translate me once", startTime: nil)), "Traduit")
    }

    func testTranslationCacheKeyChangesWithLyricContentWithoutExposingRawText() {
        let first = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Private lyric text", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )
        let second = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Different private lyric text", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )

        let firstKey = ProviderPipelineController.translationCacheKey(
            providerIdentifier: "test-provider",
            targetLanguageIdentifier: "fr-FR",
            document: first
        )
        let secondKey = ProviderPipelineController.translationCacheKey(
            providerIdentifier: "test-provider",
            targetLanguageIdentifier: "fr-FR",
            document: second
        )

        XCTAssertEqual(firstKey.namespace, .translation)
        XCTAssertNotEqual(firstKey.rawValue, secondKey.rawValue)
        XCTAssertEqual(
            firstKey.rawValue,
            ProviderPipelineController.translationCacheKey(
                providerIdentifier: "test-provider",
                targetLanguageIdentifier: "fr-FR",
                document: first
            ).rawValue
        )
        XCTAssertTrue(firstKey.rawValue.hasPrefix("translation-v1:"))
        XCTAssertFalse(firstKey.rawValue.contains("Private lyric text"))
        XCTAssertFalse(secondKey.rawValue.contains("Different private lyric text"))
    }

    func testCancelledLyricsLoadCannotClearReplacementTask() async throws {
        let appState = appStateWithLyrics()
        let started = expectation(description: "Both lyrics requests started")
        started.expectedFulfillmentCount = 2
        let lyricsProvider = ControllableLyricsProvider(document: appState.lyricsDocument, started: started)
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: RecordingTranslationProvider()
        )

        controller.prepareOverlayContent(appState: appState)
        try await waitUntil { lyricsProvider.requestedTrackIDs.count == 1 }
        appState.updatePlayerState(playerState(trackID: "track:replacement"))
        controller.refreshOverlayContent(appState: appState)
        await fulfillment(of: [started], timeout: 1)

        lyricsProvider.complete()
        try await waitUntil { lyricsProvider.completedRequestCount == 1 }
        await drainPipelineTasks()
        controller.prepareOverlayContent(appState: appState)
        await drainPipelineTasks()

        XCTAssertEqual(lyricsProvider.requestedTrackIDs, ["track:pipeline", "track:replacement"])
        controller.stopHiddenWork(appState: appState)
        lyricsProvider.complete(index: 1)
        try await waitUntil { lyricsProvider.completedRequestCount == 2 }
        await drainPipelineTasks()
        XCTAssertEqual(appState.providerRuntimeState, .idle)
    }

    func testLiveResumeRestartsCancelledTranslationAndRetainsReplacementOwnership() async throws {
        let appState = appStateWithLyrics()
        let lyricsProvider = RecordingLyricsProvider()
        let started = expectation(description: "Original and resumed translations started")
        started.expectedFulfillmentCount = 2
        let translationProvider = ControllableTranslationProvider(started: started)
        let controller = ProviderPipelineController(
            lyricsProvider: lyricsProvider,
            translationProvider: translationProvider
        )

        controller.refreshTranslation(appState: appState)
        try await waitUntil { translationProvider.requestCount == 1 }
        appState.isOverlayVisible = false
        controller.stopHiddenWork(appState: appState)
        appState.isOverlayVisible = true
        controller.resumeVisibleLiveOverlayContent(appState: appState)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(lyricsProvider.requestedTrackIDs, [])

        translationProvider.complete(with: .status(.unavailable(reason: "Old request")))
        try await waitUntil { translationProvider.completedRequestCount == 1 }
        await drainPipelineTasks()
        appState.isOverlayVisible = false
        controller.stopHiddenWork(appState: appState)
        translationProvider.complete(with: .available(MockTranslationProvider.previewTranslation(
            targetLanguageIdentifier: appState.preferredTranslationLanguageIdentifier
        )), index: 1)
        try await waitUntil { translationProvider.completedRequestCount == 2 }
        await drainPipelineTasks()

        XCTAssertEqual(appState.translation.lines, [])
        XCTAssertEqual(appState.translationRuntimeState, .unavailable(reason: "Translation cancelled"))
    }

    func testCancelledCacheMissDoesNotStartTranslationProvider() async throws {
        let appState = appStateWithLyrics()
        let cache = SuspendingMediaCache(suspendsRead: true)
        let provider = CountingTranslationProvider()
        let controller = ProviderPipelineController(
            lyricsProvider: RecordingLyricsProvider(), translationProvider: provider, mediaCache: cache
        )

        controller.refreshTranslation(appState: appState)
        try await waitUntil { cache.isWaiting }
        controller.stopHiddenWork(appState: appState)
        cache.resume()
        try await waitUntil { cache.didResume }
        await drainPipelineTasks()

        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertEqual(appState.translationRuntimeState, .unavailable(reason: "Translation cancelled"))
    }

    func testTrackChangeDuringCacheStoreCannotApplyStaleTranslation() async throws {
        let appState = appStateWithLyrics()
        let cache = SuspendingMediaCache(suspendsRead: false)
        let controller = ProviderPipelineController(
            lyricsProvider: RecordingLyricsProvider(),
            translationProvider: CountingTranslationProvider(),
            mediaCache: cache
        )

        controller.refreshTranslation(appState: appState)
        try await waitUntil { cache.isWaiting }
        appState.updatePlayerState(playerState(trackID: "track:new"))
        cache.resume()
        try await waitUntil { cache.didResume }
        await drainPipelineTasks()

        XCTAssertEqual(appState.translation.lines, [])
        XCTAssertNotEqual(appState.translationRuntimeState, .ready)
    }

    private func appStateWithLyrics() -> AppState {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.pipeline.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.runtimeFeatureFlags = .liveAppleMusic
        appState.isOverlayVisible = true
        appState.showsTranslation = true
        appState.setLiveModeRunning(true)
        appState.updatePlayerState(playerState(trackID: "track:pipeline"))
        appState.applyLyricsDocument(LyricsDocument(
            source: .appleMusicWeb,
            lines: [LyricLine(id: 0, text: "Translate current lyrics", startTime: 0)],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        ))
        appState.applyProviderReady()
        appState.clearTranslation()
        return appState
    }

    private func drainPipelineTasks() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private final class SuspendingMediaCache: MediaCache {
        private let suspendsRead: Bool
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false
        private(set) var didResume = false

        init(suspendsRead: Bool) { self.suspendsRead = suspendsRead }

        func value(for key: MediaCacheKey) async -> MediaCachePayload? {
            if suspendsRead { await suspend() }
            return nil
        }

        func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async {
            if !suspendsRead { await suspend() }
        }

        func removeAll() async {}

        private func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
            didResume = true
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class RecordingLyricsProvider: LyricsProvider {
        let displayName = "Recording lyrics provider"
        private(set) var requestedTrackIDs: [String] = []

        func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
            requestedTrackIDs.append(track.id)
            return .unavailable
        }
    }

    private struct ImmediateLyricsProvider: LyricsProvider {
        let displayName = "Immediate lyrics provider"
        let document: LyricsDocument

        func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
            .available(document)
        }
    }

    private final class ControllableLyricsProvider: LyricsProvider {
        let displayName = "Controllable lyrics provider"
        private let document: LyricsDocument
        private let started: XCTestExpectation
        private var continuations: [CheckedContinuation<Void, Never>?] = []
        private(set) var requestedTrackIDs: [String] = []
        private(set) var completedRequestCount = 0

        init(
            document: LyricsDocument,
            started: XCTestExpectation
        ) {
            self.document = document
            self.started = started
        }

        func lyrics(for track: NowPlayingTrack) async -> LyricsProviderResult {
            requestedTrackIDs.append(track.id)
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                started.fulfill()
            }
            completedRequestCount += 1
            return .available(document)
        }

        func complete(index: Int = 0) {
            continuations[index]?.resume()
            continuations[index] = nil
        }
    }

    private struct RecordingTranslationProvider: TranslationProvider {
        let displayName = "Recording translation provider"

        func translation(
            for document: LyricsDocument,
            targetLanguageIdentifier: String
        ) async -> TranslationProviderResult {
            .status(.unavailable(reason: "No translation"))
        }
    }

    private final class RecordingTargetTranslationProvider: TranslationProvider {
        let displayName = "Recording target translation provider"
        private let requested: XCTestExpectation
        private(set) var requestedTargets: [String] = []

        init(requested: XCTestExpectation) {
            self.requested = requested
        }

        func translation(
            for document: LyricsDocument,
            targetLanguageIdentifier: String
        ) async -> TranslationProviderResult {
            requestedTargets.append(targetLanguageIdentifier)
            requested.fulfill()
            return .status(.unavailable(reason: "Recorded"))
        }
    }

    private final class ControllableTranslationProvider: TranslationProvider {
        let displayName = "Controllable translation provider"
        private let started: XCTestExpectation
        private let returned: XCTestExpectation?
        private var continuations: [CheckedContinuation<TranslationProviderResult, Never>?] = []
        private(set) var requestCount = 0
        private(set) var completedRequestCount = 0

        init(
            started: XCTestExpectation,
            returned: XCTestExpectation? = nil
        ) {
            self.started = started
            self.returned = returned
        }

        func translation(
            for document: LyricsDocument,
            targetLanguageIdentifier: String
        ) async -> TranslationProviderResult {
            requestCount += 1
            let result = await withCheckedContinuation { continuation in
                continuations.append(continuation)
                started.fulfill()
            }
            completedRequestCount += 1
            returned?.fulfill()
            return result
        }

        func complete(with result: TranslationProviderResult, index: Int = 0) {
            continuations[index]?.resume(returning: result)
            continuations[index] = nil
        }
    }

    private final class CountingTranslationProvider: TranslationProvider {
        let displayName = "Counting translation provider"
        private(set) var requestCount = 0

        func translation(
            for document: LyricsDocument,
            targetLanguageIdentifier: String
        ) async -> TranslationProviderResult {
            requestCount += 1
            return .available(LyricTranslation(
                targetLanguageIdentifier: targetLanguageIdentifier,
                sourceLanguageIdentifier: document.sourceLanguageIdentifier,
                lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: "Traduit")]
            ))
        }
    }

    private func playerState(trackID: String) -> PlayerState {
        PlayerState(
            playbackStatus: .playing,
            track: NowPlayingTrack(
                id: trackID,
                title: "Track",
                artist: "MusicFloat",
                album: "Tests",
                duration: 180,
                providerName: "Apple Music"
            ),
            elapsedTime: 0,
            updatedAt: Date()
        )
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

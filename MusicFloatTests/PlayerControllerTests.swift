import AppKit
import XCTest
@testable import MusicFloat

final class PlayerControllerTests: XCTestCase {
    @MainActor
    func testRestartLiveTickSeedsFromEffectiveElapsedTime() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveTickSeed.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)

        var staleSnapshot = MockMusicAppBridge.previewState
        staleSnapshot.elapsedTime = 10
        appState.updatePlayerState(staleSnapshot)
        appState.updateLiveElapsedTime(58)

        XCTAssertEqual(PlayerController.liveTickInitialElapsed(appState: appState), 58)
    }

    @MainActor
    func testHiddenLiveElapsedResumesFromWallClock() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveWallClockResume.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        var snapshot = MockMusicAppBridge.previewState
        snapshot.elapsedTime = 10
        snapshot.updatedAt = referenceDate
        appState.updatePlayerState(snapshot)

        appState.resumeLiveElapsedTimeFromWallClock(
            now: referenceDate.addingTimeInterval(15)
        )

        XCTAssertEqual(appState.effectiveElapsedTime, 25, accuracy: 0.001)
    }

    @MainActor
    func testHiddenLiveElapsedResumeClampsToTrackDuration() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.liveWallClockResumeClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        let track = NowPlayingTrack(
            id: "short-track",
            title: "Short",
            artist: "MusicFloat",
            album: "Tests",
            duration: 20,
            providerName: "Test"
        )
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 18,
            updatedAt: referenceDate
        ))

        appState.resumeLiveElapsedTimeFromWallClock(
            now: referenceDate.addingTimeInterval(15)
        )

        XCTAssertEqual(appState.effectiveElapsedTime, 20, accuracy: 0.001)
    }

    @MainActor
    func testLiveTickIntervalIgnoresSyllableBoundaries() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 0,
                    text: "Dense syllables",
                    startTime: 0,
                    syllables: [
                        LyricSyllable(text: "Dense ", startTime: 0.1, endTime: 0.2),
                        LyricSyllable(text: "syllables", startTime: 0.2, endTime: 0.3)
                    ]
                ),
                LyricLine(id: 1, text: "Next line", startTime: 8)
            ],
            isTimed: true
        )

        let interval = PlayerController.liveTickInterval(
            currentElapsed: 0,
            lyricsDocument: document,
            lyricOffsetSeconds: 0,
            duration: 120
        )

        XCTAssertEqual(interval, 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testLiveTickIntervalStillWakesForLineBoundary() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "Current line", startTime: 0),
                LyricLine(id: 1, text: "Soon", startTime: 0.35)
            ],
            isTimed: true
        )

        let interval = PlayerController.liveTickInterval(
            currentElapsed: 0,
            lyricsDocument: document,
            lyricOffsetSeconds: 0,
            duration: 120
        )

        XCTAssertEqual(interval, 0.35, accuracy: 0.0001)
    }

    @MainActor
    func testPreviewRefreshUsesTrackDurationForUntimedLyrics() {
        let controller = PlayerController(bridge: MockMusicAppBridge())
        let track = NowPlayingTrack(
            id: "plain-preview-track",
            title: "Plain",
            artist: "Artist",
            album: "Album",
            duration: 90,
            providerName: "Test"
        )
        let state = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 10,
            updatedAt: Date()
        )
        let document = LyricsDocument(
            source: .musicApp,
            lines: [
                LyricLine(id: 0, text: "First sentence", startTime: nil),
                LyricLine(id: 1, text: "Second sentence", startTime: nil),
                LyricLine(id: 2, text: "Third sentence", startTime: nil)
            ],
            isTimed: false
        )

        let interval = controller.nextRefreshInterval(
            currentState: state,
            lyricsDocument: document
        )

        XCTAssertEqual(interval, 20, accuracy: 0.001)
    }

    @MainActor
    func testLiveResyncDecisionSnapsSmallDriftWithoutSeek() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 10.4,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertEqual(decision.snapshotDelta, 0.4, accuracy: 0.0001)
        XCTAssertTrue(decision.isSameTrack)
        XCTAssertTrue(decision.shouldSnap)
        XCTAssertFalse(decision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionClassifiesLargeSameTrackJumpAsSeek() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 13,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertTrue(decision.shouldSnap)
        XCTAssertTrue(decision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionDoesNotSnapDifferentTrackOrMissingTrack() {
        let differentTrack = NowPlayingTrack(
            id: "different-track",
            title: "Different",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let differentSnapshot = PlayerState(
            playbackStatus: .playing,
            track: differentTrack,
            elapsedTime: 30,
            updatedAt: Date()
        )
        let missingSnapshot = PlayerState(
            playbackStatus: .playing,
            track: nil,
            elapsedTime: 30,
            updatedAt: Date()
        )

        let differentDecision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: differentSnapshot
        )
        let missingDecision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: missingSnapshot
        )

        XCTAssertFalse(differentDecision.shouldSnap)
        XCTAssertFalse(differentDecision.isSeek)
        XCTAssertFalse(missingDecision.shouldSnap)
        XCTAssertFalse(missingDecision.isSeek)
    }

    @MainActor
    func testLiveResyncDecisionTreatsSeekThresholdAsNonSeekSnapBoundary() {
        let snapshot = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 12,
            updatedAt: Date()
        )

        let decision = PlayerController.liveResyncDecision(
            localElapsed: 10,
            currentTrackID: MockMusicAppBridge.previewTrack.id,
            snapshot: snapshot
        )

        XCTAssertTrue(decision.shouldSnap)
        XCTAssertFalse(decision.isSeek)
    }

    @MainActor
    func testLiveResyncFailureIntervalBacksOffAfterMissingSnapshots() {
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 0), 1)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 1), 3)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 3), 7)
        XCTAssertEqual(PlayerController.liveResyncInterval(consecutiveFailures: 20), 10)
    }

    @MainActor
    func testVisibleWatchdogRecoversFailedPrimeAndMissedResume() async throws {
        let playing = MockMusicAppBridge.previewState
        var paused = playing
        paused.playbackStatus = .paused
        for initial in [PlayerState.disconnected, paused] {
            let appState = AppState(userDefaults: UserDefaults(suiteName: "MusicFloatTests.recoverPrime.\(UUID().uuidString)")!)
            appState.isOverlayVisible = true
            let bridge = RecordingMusicBridge(states: [initial, playing])
            let controller = PlayerController(
                bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge }, musicAppIsRunning: { true }
            )
            defer { controller.stopLiveAppleMusic(appState: appState) }
            var changedTrackIDs: [String?] = []
            controller.startLiveAppleMusic(appState: appState) { changedTrackIDs.append($0?.id) }
            try await waitUntil { bridge.currentStateCallCount == 1 }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(appState.effectiveElapsedTime, initial.elapsedTime, accuracy: 0.001)
            try await waitUntil(timeout: 5) { appState.playerState.playbackStatus == .playing }
            XCTAssertEqual(appState.playerState.track?.id, playing.track?.id)
            XCTAssertEqual(changedTrackIDs, initial.track == nil ? [nil, playing.track?.id] : [playing.track?.id])
        }
    }

    @MainActor
    func testStartupSubscribesBeforeSnapshotAndBuffersEvent() async throws {
        let appState = AppState(userDefaults: UserDefaults(suiteName: "MusicFloatTests.primeEvent.\(UUID().uuidString)")!)
        let bridge = RecordingMusicBridge(states: [])
        let (stream, continuation) = AsyncStream<PlayerState>.makeStream()
        bridge.eventStream = stream
        bridge.stateHandler = {
            XCTAssertEqual(bridge.eventsCallCount, 1)
            continuation.yield(MockMusicAppBridge.previewState)
            return .disconnected
        }
        let controller = PlayerController(bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge })
        defer { controller.stopLiveAppleMusic(appState: appState); continuation.finish() }
        controller.startLiveAppleMusic(appState: appState)
        try await waitUntil { appState.playerState.track != nil }
        XCTAssertEqual(appState.playerState.playbackStatus, .playing)
    }

    @MainActor
    func testHiddenOverlayCancelsWaitingPlaybackRecovery() async throws {
        let appState = AppState(userDefaults: UserDefaults(suiteName: "MusicFloatTests.hiddenRecovery.\(UUID().uuidString)")!)
        appState.isOverlayVisible = true
        let bridge = RecordingMusicBridge(states: [.disconnected, MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge }, musicAppIsRunning: { true }
        )
        defer { controller.stopLiveAppleMusic(appState: appState) }
        controller.startLiveAppleMusic(appState: appState)
        try await waitUntil { bridge.eventsCallCount == 1 && appState.playerState == .disconnected }
        appState.isOverlayVisible = false
        controller.overlayVisibilityChanged(false, appState: appState)
        try await Task.sleep(for: .milliseconds(3_200))
        XCTAssertEqual(bridge.currentStateCallCount, 1)
        XCTAssertNil(appState.playerState.track)
    }

    @MainActor
    func testFailedRevealSnapshotPreservesKnownPlayback() async throws {
        let appState = AppState(userDefaults: UserDefaults(suiteName: "MusicFloatTests.failedReveal.\(UUID().uuidString)")!)
        let initial = MockMusicAppBridge.previewState
        let bridge = RecordingMusicBridge(states: [initial, .disconnected])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge }, musicAppIsRunning: { true }
        )
        defer { controller.stopLiveAppleMusic(appState: appState) }
        controller.startLiveAppleMusic(appState: appState)
        try await waitUntil { appState.playerState.track != nil }
        appState.isOverlayVisible = true
        controller.overlayVisibilityChanged(true, appState: appState)
        try await waitUntil { bridge.currentStateCallCount >= 2 }
        XCTAssertEqual(appState.playerState, initial)
    }

    @MainActor
    func testWatchdogRecoversMissedPauseAndConfirmedProcessExit() async throws {
        let initial = MockMusicAppBridge.previewState
        let paused = PlayerState(playbackStatus: .paused, track: initial.track, elapsedTime: initial.elapsedTime, updatedAt: Date())
        for snapshot in [paused, .disconnected] {
            let defaults = UserDefaults(suiteName: "MusicFloatTests.watchdogReconcile.\(UUID().uuidString)")!
            let appState = AppState(userDefaults: defaults)
            appState.isOverlayVisible = true
            let bridge = RecordingMusicBridge(states: [initial, snapshot])
            let controller = PlayerController(
                bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge },
                musicAppIsRunning: { snapshot.track != nil }
            )
            var changedTrackIDs: [String?] = []
            controller.startLiveAppleMusic(appState: appState) { track in
                changedTrackIDs.append(track?.id)
                appState.applyLyricsDocument(Self.watchdogBoundaryDocument(at: initial.elapsedTime))
            }
            try await waitUntil { appState.playerState == snapshot }

            XCTAssertEqual(appState.effectiveElapsedTime, snapshot.elapsedTime, accuracy: 0.001)
            XCTAssertEqual(changedTrackIDs, snapshot.track == nil ? [initial.track?.id, nil] : [initial.track?.id])
            controller.stopLiveAppleMusic(appState: appState)
        }
    }

    @MainActor
    func testWatchdogKeepsPlaybackOnAmbiguousMissingSnapshot() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.watchdogMissingSnapshot.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        let initial = MockMusicAppBridge.previewState
        let bridge = RecordingMusicBridge(states: [initial, .disconnected])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge }, musicAppIsRunning: { true }
        )
        defer { controller.stopLiveAppleMusic(appState: appState) }
        var trackChangeCount = 0
        controller.startLiveAppleMusic(appState: appState) { _ in
            trackChangeCount += 1
            appState.applyLyricsDocument(Self.watchdogBoundaryDocument(at: initial.elapsedTime))
        }
        try await waitUntil { bridge.currentStateCallCount >= 2 && appState.effectiveElapsedTime > initial.elapsedTime }

        XCTAssertEqual(appState.playerState, initial)
        XCTAssertEqual(trackChangeCount, 1)
    }

    @MainActor
    func testWatchdogRecoversNewTrackWithoutRepeatingCallbackForLateEvent() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.watchdogNewTrack.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.isOverlayVisible = true
        let initial = MockMusicAppBridge.previewState
        let track = NowPlayingTrack(id: "watchdog-next", title: "Next", artist: "", album: "", duration: 90, providerName: "Test")
        let next = PlayerState(playbackStatus: .playing, track: track, elapsedTime: 0, updatedAt: Date())
        let bridge = RecordingMusicBridge(states: [initial, next])
        let (stream, continuation) = AsyncStream<PlayerState>.makeStream()
        bridge.eventStream = stream
        let controller = PlayerController(
            bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge }, musicAppIsRunning: { true }
        )
        defer { controller.stopLiveAppleMusic(appState: appState); continuation.finish() }
        var changedTrackIDs: [String?] = []
        controller.startLiveAppleMusic(appState: appState) { track in
            changedTrackIDs.append(track?.id)
            if changedTrackIDs.count == 1 {
                appState.applyLyricsDocument(Self.watchdogBoundaryDocument(at: initial.elapsedTime))
            }
        }
        try await waitUntil { appState.playerState.track?.id == track.id }
        XCTAssertEqual(appState.effectiveElapsedTime, 0, accuracy: 0.1)

        var lateEvent = next
        lateEvent.playbackStatus = .paused
        continuation.yield(lateEvent)
        try await waitUntil { appState.playerState.playbackStatus == .paused }

        XCTAssertEqual(changedTrackIDs, [initial.track?.id, track.id])
    }

    private static func watchdogBoundaryDocument(at elapsed: TimeInterval) -> LyricsDocument {
        LyricsDocument(source: .mock, lines: [LyricLine(id: 0, text: "Boundary", startTime: elapsed + 0.03)], isTimed: true)
    }

    @MainActor
    func testVolumeCommandClampsBeforeBridge() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.volumeClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)

        await controller.performLivePlaybackCommand(.setVolume(140), appState: appState)

        XCTAssertEqual(bridge.commands, [.setVolume(100)])
        XCTAssertEqual(appState.musicVolume, 100)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testPlaybackCommandIgnoredInDemoMode() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.demoPlaybackCommand.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)

        await controller.performLivePlaybackCommand(.playPause, appState: appState, isDemoMode: true)

        XCTAssertTrue(bridge.commands.isEmpty)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testPlayPauseCommandRefreshesPlayerState() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.playPauseRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let refreshedState = PlayerState(
            playbackStatus: .paused,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 43,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        bridge.states = [refreshedState]

        await controller.performLivePlaybackCommand(.playPause, appState: appState)

        XCTAssertEqual(bridge.commands, [.playPause])
        XCTAssertEqual(appState.playerState, refreshedState)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testNextTrackCommandRefreshesStateAndClearsArtwork() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.nextTrackRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = MockMusicAppBridge.previewTrack
        let nextTrack = NowPlayingTrack(
            id: "next-track",
            title: "Next",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let firstState = PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 12,
            updatedAt: Date()
        )
        let nextState = PlayerState(
            playbackStatus: .playing,
            track: nextTrack,
            elapsedTime: 0,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [firstState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )
        var changedTrack: NowPlayingTrack?

        controller.startLiveAppleMusic(appState: appState) { track in
            changedTrack = track
        }
        await waitForCurrentStateCall(on: bridge)
        changedTrack = nil
        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 8, height: 8)), forTrackID: firstTrack.id)
        bridge.states = [firstState, nextState]

        await controller.performLivePlaybackCommand(.nextTrack, appState: appState)

        XCTAssertEqual(bridge.commands, [.nextTrack])
        XCTAssertEqual(appState.playerState, nextState)
        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(changedTrack?.id, nextTrack.id)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testSeekCommandClampsToTrackDurationAndRefreshesState() async {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.seekClamp.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let track = NowPlayingTrack(
            id: "seek-track",
            title: "Seek",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let initialState = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 12,
            updatedAt: Date()
        )
        let seekState = PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 180,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [initialState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        bridge.states = [seekState]

        await controller.performLivePlaybackCommand(.seek(500), appState: appState)

        XCTAssertEqual(bridge.commands, [.seek(180)])
        XCTAssertEqual(appState.playerState, seekState)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testOverlayRevealRefreshesAuthoritativeLiveState() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.overlayRevealRefresh.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let initialState = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 10,
            updatedAt: Date()
        )
        let refreshedState = PlayerState(
            playbackStatus: .playing,
            track: MockMusicAppBridge.previewTrack,
            elapsedTime: 45,
            updatedAt: Date()
        )
        let bridge = RecordingMusicBridge(states: [initialState])
        let controller = PlayerController(
            bridge: MockMusicAppBridge(),
            liveBridgeFactory: { bridge }
        )

        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: bridge)
        appState.isOverlayVisible = false
        controller.overlayVisibilityChanged(false, appState: appState)
        bridge.states = [refreshedState, refreshedState]
        appState.isOverlayVisible = true

        controller.overlayVisibilityChanged(true, appState: appState)
        try await waitUntil { appState.playerState.elapsedTime == 45 }

        XCTAssertEqual(appState.playerState, refreshedState)
        controller.stopLiveAppleMusic(appState: appState)
    }

    @MainActor
    func testStoppedLivePrimeDoesNotPublishDelayedSnapshot() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.stoppedLivePrime.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let bridge = RecordingMusicBridge(states: [])
        var pendingSnapshot: CheckedContinuation<PlayerState, Never>?
        var snapshotReturned = false
        bridge.stateHandler = {
            let snapshot = await withCheckedContinuation { pendingSnapshot = $0 }
            snapshotReturned = true
            return snapshot
        }
        let controller = PlayerController(bridge: MockMusicAppBridge(), liveBridgeFactory: { bridge })
        var trackChangeCount = 0
        controller.startLiveAppleMusic(appState: appState) { _ in trackChangeCount += 1 }
        try await waitUntil { pendingSnapshot != nil }

        controller.stopLiveAppleMusic(appState: appState)
        let stoppedState = appState.playerState
        try XCTUnwrap(pendingSnapshot).resume(returning: MockMusicAppBridge.previewState)
        try await waitUntil { snapshotReturned }
        await Task.yield()

        XCTAssertEqual(appState.playerState, stoppedState)
        XCTAssertFalse(appState.isLiveModeRunning)
        XCTAssertEqual(trackChangeCount, 0)
    }

    @MainActor
    func testOldCommandCompletionDoesNotClearReplacementCommandOrState() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.oldCommandCompletion.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let oldBridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let replacementState = PlayerState(
            playbackStatus: .paused, track: MockMusicAppBridge.previewTrack,
            elapsedTime: 12, updatedAt: Date()
        )
        let newBridge = RecordingMusicBridge(states: [replacementState])
        newBridge.reportedVolume = 30
        let controller = PlayerController(bridge: MockMusicAppBridge(), liveBridgeFactory: {
            oldBridge.currentStateCallCount == 0 ? oldBridge : newBridge
        })
        defer { controller.stopLiveAppleMusic(appState: appState) }
        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: oldBridge)

        var oldCompletion: CheckedContinuation<MusicPlaybackCommandResult, Never>?
        oldBridge.commandHandler = { await withCheckedContinuation { oldCompletion = $0 } }
        let oldCommand = Task { await controller.performLivePlaybackCommand(.playPause, appState: appState) }
        try await waitUntil { oldCompletion != nil }
        controller.stopLiveAppleMusic(appState: appState)
        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: newBridge)

        var newCompletion: CheckedContinuation<MusicPlaybackCommandResult, Never>?
        newBridge.commandHandler = { await withCheckedContinuation { newCompletion = $0 } }
        let newCommand = Task { await controller.performLivePlaybackCommand(.setVolume(30), appState: appState) }
        try await waitUntil { newCompletion != nil }
        try XCTUnwrap(oldCompletion).resume(returning: .succeeded)
        let oldResult = await oldCommand.value

        XCTAssertNil(oldResult)
        XCTAssertEqual(appState.playerState, replacementState)
        XCTAssertTrue(appState.isPlaybackCommandInFlight)
        XCTAssertEqual(oldBridge.currentStateCallCount, 1)
        try XCTUnwrap(newCompletion).resume(returning: .succeeded)
        _ = await newCommand.value
        XCTAssertEqual(appState.musicVolume, 30)
        XCTAssertFalse(appState.isPlaybackCommandInFlight)
    }

    @MainActor
    func testOldCommandSnapshotDoesNotOverwriteRestartedLiveSession() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.oldCommandSnapshot.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let oldBridge = RecordingMusicBridge(states: [MockMusicAppBridge.previewState])
        let replacementState = PlayerState(
            playbackStatus: .paused, track: MockMusicAppBridge.previewTrack,
            elapsedTime: 12, updatedAt: Date()
        )
        let newBridge = RecordingMusicBridge(states: [replacementState])
        let controller = PlayerController(bridge: MockMusicAppBridge(), liveBridgeFactory: {
            oldBridge.currentStateCallCount == 0 ? oldBridge : newBridge
        })
        defer { controller.stopLiveAppleMusic(appState: appState) }
        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: oldBridge)

        var pendingSnapshot: CheckedContinuation<PlayerState, Never>?
        oldBridge.stateHandler = { await withCheckedContinuation { pendingSnapshot = $0 } }
        let command = Task { await controller.performLivePlaybackCommand(.playPause, appState: appState) }
        try await waitUntil { pendingSnapshot != nil }
        controller.stopLiveAppleMusic(appState: appState)
        controller.startLiveAppleMusic(appState: appState)
        await waitForCurrentStateCall(on: newBridge)
        try XCTUnwrap(pendingSnapshot).resume(returning: MockMusicAppBridge.previewState)
        let result = await command.value

        XCTAssertNil(result)
        XCTAssertEqual(appState.playerState, replacementState)
        XCTAssertTrue(appState.isLiveModeRunning)
        XCTAssertFalse(appState.isPlaybackCommandInFlight)
    }

    @MainActor
    private func waitForCurrentStateCall(on bridge: RecordingMusicBridge) async {
        for _ in 0..<20 {
            if bridge.currentStateCallCount > 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for bridge.currentState() to be called")
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<Int(timeout / 0.02) {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class RecordingMusicBridge: MusicAppBridge {
    let displayName = "Recording music bridge"
    var states: [PlayerState]
    var commands: [MusicPlaybackCommand] = []
    var commandResult: MusicPlaybackCommandResult = .succeeded
    var reportedVolume: Int?
    var stateHandler: (@MainActor () async -> PlayerState)?
    var commandHandler: (@MainActor () async -> MusicPlaybackCommandResult)?
    var eventStream: AsyncStream<PlayerState>?
    private(set) var currentStateCallCount = 0
    private(set) var eventsCallCount = 0

    init(states: [PlayerState]) {
        self.states = states
    }

    func currentState() async -> PlayerState {
        currentStateCallCount += 1
        if let stateHandler { return await stateHandler() }
        guard !states.isEmpty else {
            return .disconnected
        }
        return states.removeFirst()
    }

    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult {
        commands.append(command)
        if let commandHandler { return await commandHandler() }
        return commandResult
    }

    func currentVolume() async -> Int? {
        reportedVolume
    }

    func events() -> AsyncStream<PlayerState> {
        eventsCallCount += 1
        return eventStream ?? AsyncStream { $0.finish() }
    }
}

import Foundation
import OSLog

@MainActor
final class PlayerController {
    private static let commandRefreshAttempts = 6
    private static let commandRefreshDelayNanoseconds: UInt64 = 200_000_000
    private static let hiddenIdleRefreshInterval: TimeInterval = 60
    /// How often we re-pull `player position` from Music.app while live and
    /// playing, to correct any drift that has accumulated since the last
    /// distributed-notification event.
    private static let resyncInterval: TimeInterval = 1.0
    private static let idleResyncInterval: TimeInterval = 3.0
    /// Threshold for snapping our interpolated elapsedTime to Music's
    /// authoritative position. Smaller deltas are ignored so jitter from
    /// AppleScript's coarse `player position` doesn't fight the smooth tick.
    private static let resyncSnapThreshold: TimeInterval = 0.35
    /// Threshold for treating an elapsed-time jump as a user seek/scrub rather
    /// than normal clock drift.
    private static let seekDetectionThreshold: TimeInterval = 2.0
    private static let liveLineTickCap: TimeInterval = 1.0
    private static let liveTickMinimum: TimeInterval = 0.03
    private static let resyncFailureBackoffCap: TimeInterval = 10.0

    struct LiveResyncDecision: Equatable, Sendable {
        let snapshotDelta: TimeInterval
        let isSameTrack: Bool
        let shouldSnap: Bool
        let isSeek: Bool
    }

    private let bridge: any MusicAppBridge
    private let liveBridgeFactory: @MainActor () -> any MusicAppBridge
    private let musicAppIsRunning: @MainActor () -> Bool
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveTickTask: Task<Void, Never>?
    private var liveVisibilityRefreshTask: Task<Void, Never>?
    private var liveBridge: (any MusicAppBridge)?
    private var liveSessionID: UUID?
    private var liveTrackChangedCallback: (@MainActor (NowPlayingTrack?) -> Void)?
    private let syncEngine = LyricsSyncEngine()

    init(
        bridge: any MusicAppBridge,
        liveBridgeFactory: @escaping @MainActor () -> any MusicAppBridge = { PublicAppleMusicAppBridge() },
        musicAppIsRunning: @escaping @MainActor () -> Bool = { AppleMusicEventListener.isMusicAppRunning }
    ) {
        self.bridge = bridge
        self.liveBridgeFactory = liveBridgeFactory
        self.musicAppIsRunning = musicAppIsRunning
    }

    // MARK: - Live Apple Music

    /// Starts an event-driven feed from Apple Music's distributed notifications.
    /// Cancels any in-flight mock preview first so the two never compete.
    ///
    /// - Parameter onTrackChanged: invoked whenever the playing track's
    ///   identity changes (including the initial prime). Used by the caller
    ///   to trigger lyrics fetches.
    func startLiveAppleMusic(
        appState: AppState,
        onTrackChanged: (@MainActor (NowPlayingTrack?) -> Void)? = nil
    ) {
        guard liveTask == nil else { return }
        stopMockPreview(appState: appState)

        let bridge = liveBridgeFactory()
        let sessionID = UUID()
        liveBridge = bridge
        liveSessionID = sessionID
        liveTrackChangedCallback = onTrackChanged
        appState.setLiveModeRunning(true)
        AppTelemetry.performance.info("Live Apple Music bridge started")

        liveTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }

            // Register before the first suspension so startup events are buffered.
            let events = bridge.events()
            let initial = await bridge.currentState()
            guard !Task.isCancelled, self.liveSessionID == sessionID else { return }
            AppTelemetry.performance.info(
                "Live prime: status=\(initial.playbackStatus.rawValue, privacy: .public) hasTrack=\(initial.track != nil) elapsed=\(initial.elapsedTime) musicRunning=\(AppleMusicEventListener.isMusicAppRunning)"
            )
            appState.updatePlayerState(initial)
            self.restartLiveTick(appState: appState)
            onTrackChanged?(initial.track)

            let volume = await bridge.currentVolume()
            guard !Task.isCancelled, self.liveSessionID == sessionID else { return }
            appState.setMusicVolume(volume)

            for await state in events {
                guard !Task.isCancelled, self.liveSessionID == sessionID else { break }
                let previousTrackID = appState.playerState.track?.id
                let incomingTrackID = state.track?.id
                let isSameTrack = incomingTrackID != nil && incomingTrackID == previousTrackID
                let previousEffectiveElapsed = appState.effectiveElapsedTime
                let eventDelta = state.elapsedTime - previousEffectiveElapsed
                if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                    AppTelemetry.performance.debug(
                        "Live event: status=\(state.playbackStatus.rawValue, privacy: .public) track=\(NowPlayingTrack.telemetryID(for: incomingTrackID), privacy: .public) elapsed=\(state.elapsedTime) previousElapsed=\(previousEffectiveElapsed) delta=\(eventDelta)"
                    )
                }
                if isSameTrack, abs(eventDelta) > Self.seekDetectionThreshold {
                    AppTelemetry.performance.info(
                        "SEEK_DETECTED source=playerInfoEvent track=\(NowPlayingTrack.telemetryID(for: incomingTrackID), privacy: .public) previousElapsed=\(previousEffectiveElapsed) incomingElapsed=\(state.elapsedTime) delta=\(eventDelta)"
                    )
                }
                appState.updatePlayerState(state)
                if incomingTrackID != previousTrackID {
                    AppTelemetry.performance.info(
                        "Live track changed previous=\(NowPlayingTrack.telemetryID(for: previousTrackID), privacy: .public) next=\(state.track?.telemetryID ?? "none", privacy: .public)"
                    )
                    onTrackChanged?(state.track)
                }
                // Re-sync tick to the fresh elapsedTime from the event so
                // play/pause/skip/seek doesn't leave the active line behind.
                self.restartLiveTick(appState: appState)
            }
        }
    }

    func stopLiveAppleMusic(appState: AppState? = nil) {
        guard liveTask != nil else {
            appState?.setLiveModeRunning(false)
            return
        }
        AppTelemetry.performance.info("Live Apple Music bridge stopped")
        liveTask?.cancel()
        liveTask = nil
        liveTickTask?.cancel()
        liveTickTask = nil
        liveVisibilityRefreshTask?.cancel()
        liveVisibilityRefreshTask = nil
        liveBridge = nil
        liveSessionID = nil
        liveTrackChangedCallback = nil
        appState?.setMusicVolume(nil)
        appState?.setPlaybackCommandInFlight(false)
        appState?.setLiveModeRunning(false)
    }

    @discardableResult
    func performLivePlaybackCommand(
        _ command: MusicPlaybackCommand,
        appState: AppState,
        isDemoMode: Bool = false
    ) async -> PlayerState? {
        let command = normalizedCommand(command, appState: appState)
        guard !isDemoMode else {
            AppTelemetry.performance.notice(
                "Playback command ignored in demo mode command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }
        guard appState.isLiveModeRunning, let liveBridge, let sessionID = liveSessionID else {
            AppTelemetry.performance.notice(
                "Playback command ignored because live mode is unavailable command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }
        guard !appState.isPlaybackCommandInFlight else {
            AppTelemetry.performance.notice(
                "Playback command ignored because another command is in flight command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }

        AppTelemetry.performance.info(
            "Playback command started command=\(command.telemetryName, privacy: .public)"
        )
        appState.setPlaybackCommandInFlight(true)
        defer {
            if liveSessionID == sessionID {
                appState.setPlaybackCommandInFlight(false)
            }
        }

        let result = await liveBridge.perform(command)
        guard !Task.isCancelled, liveSessionID == sessionID else { return nil }
        guard result.isSuccess else {
            logPlaybackCommandFailure(result, command: command)
            return nil
        }

        AppTelemetry.performance.info(
            "Playback command succeeded command=\(command.telemetryName, privacy: .public)"
        )

        if case .setVolume(let volume) = command {
            appState.setMusicVolume(volume)
            let refreshedVolume = await liveBridge.currentVolume()
            guard !Task.isCancelled, liveSessionID == sessionID else { return nil }
            if let refreshedVolume {
                appState.setMusicVolume(refreshedVolume)
            }
            return nil
        }

        let previousTrackID = appState.playerState.track?.id
        guard let refreshedState = await refreshedStateAfterPlaybackCommand(
            command,
            previousTrackID: previousTrackID,
            bridge: liveBridge,
            sessionID: sessionID
        ), !Task.isCancelled, liveSessionID == sessionID else { return nil }
        appState.updatePlayerState(refreshedState)
        if refreshedState.track?.id != previousTrackID {
            liveTrackChangedCallback?(refreshedState.track)
        }
        restartLiveTick(appState: appState)
        return refreshedState
    }

    private func normalizedCommand(
        _ command: MusicPlaybackCommand,
        appState: AppState
    ) -> MusicPlaybackCommand {
        switch command {
        case .seek(let position):
            return .seek(MusicPlaybackCommand.clampedPlaybackPosition(
                position,
                duration: appState.playerState.track?.duration
            ))
        default:
            return command.clamped
        }
    }

    private func refreshedStateAfterPlaybackCommand(
        _ command: MusicPlaybackCommand,
        previousTrackID: String?,
        bridge: any MusicAppBridge,
        sessionID: UUID
    ) async -> PlayerState? {
        var latestState = await bridge.currentState()
        guard !Task.isCancelled, liveSessionID == sessionID else { return nil }

        let shouldWaitForChangedSnapshot: (PlayerState) -> Bool = { state in
            switch command {
            case .nextTrack, .previousTrack:
                guard let previousTrackID else { return false }
                return state.track?.id == previousTrackID
            case .seek(let position):
                guard let previousTrackID, state.track?.id == previousTrackID else { return false }
                return abs(state.elapsedTime - position) > 0.35
            case .playPause, .setVolume:
                return false
            }
        }

        for _ in 1..<Self.commandRefreshAttempts where shouldWaitForChangedSnapshot(latestState) {
            try? await Task.sleep(nanoseconds: Self.commandRefreshDelayNanoseconds)
            guard !Task.isCancelled, liveSessionID == sessionID else { return nil }
            latestState = await bridge.currentState()
            guard !Task.isCancelled, liveSessionID == sessionID else { return nil }
        }

        return latestState
    }

    private func logPlaybackCommandFailure(
        _ result: MusicPlaybackCommandResult,
        command: MusicPlaybackCommand
    ) {
        switch result {
        case .succeeded:
            break
        case .unavailable(let reason):
            AppTelemetry.performance.notice(
                "Playback command unavailable command=\(command.telemetryName, privacy: .public) reason=\(reason, privacy: .public)"
            )
        case .failed(let reason):
            AppTelemetry.performance.error(
                "Playback command failed command=\(command.telemetryName, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    /// Called by the app when overlay visibility changes so we don't burn
    /// CPU advancing a clock no one is watching.
    func overlayVisibilityChanged(_ isVisible: Bool, appState: AppState) {
        guard liveTask != nil else { return }
        if isVisible {
            appState.resumeLiveElapsedTimeFromWallClock()
            restartLiveTick(appState: appState)
            refreshLiveStateForVisibleOverlay(appState: appState)
        } else {
            liveVisibilityRefreshTask?.cancel()
            liveVisibilityRefreshTask = nil
            liveTickTask?.cancel()
            liveTickTask = nil
        }
    }

    private func refreshLiveStateForVisibleOverlay(appState: AppState) {
        guard let bridge = liveBridge else { return }
        liveVisibilityRefreshTask?.cancel()

        liveVisibilityRefreshTask = Task { @MainActor [weak self, weak appState, bridge] in
            guard let self, let appState else { return }
            let previousTrackID = appState.playerState.track?.id
            let snapshot = await bridge.currentState()
            guard !Task.isCancelled,
                  appState.isOverlayVisible,
                  appState.isLiveModeRunning else {
                return
            }

            if snapshot.track != nil || !self.musicAppIsRunning() {
                appState.updatePlayerState(snapshot)
                if snapshot.track?.id != previousTrackID {
                    self.liveTrackChangedCallback?(snapshot.track)
                }
            }
            self.restartLiveTick(appState: appState)
            AppTelemetry.performance.info(
                "Live overlay resume snapshot refreshed hasTrack=\(snapshot.track != nil) elapsed=\(snapshot.elapsedTime)"
            )
        }
    }

    /// Reconciles playback while the overlay is visible, including recovery
    /// from a failed prime or missed resume event. Only playing tracks advance
    /// elapsed time; waiting and paused states use a slower watchdog cadence.
    private func restartLiveTick(appState: AppState) {
        liveTickTask?.cancel()
        liveTickTask = nil

        guard let sessionID = liveSessionID,
              appState.isLiveModeRunning,
              appState.isOverlayVisible else {
            return
        }

        liveTickTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            var lastWall = Date()
            var elapsed = Self.liveTickInitialElapsed(appState: appState)
            // Start with `lastResync` in the past so the first resync fires
            // immediately on the next loop iteration. This catches the case
            // where AppleScript was wedged at event time but recovers by the
            // time the first tick interval has elapsed.
            var lastResync = Date(timeIntervalSinceNow: -Self.resyncInterval)
            var consecutiveResyncFailures = 0

            while !Task.isCancelled {
                // Sleep until the next lyric line boundary or the watchdog
                // cadence. Syllable fill is now animated locally in the active
                // lyric row, so the whole overlay no longer needs a 120 ms
                // app-state tick just to move the karaoke mask.
                let isPlaying = appState.playerState.playbackStatus == .playing
                    && appState.playerState.track != nil
                let sleep = isPlaying ? Self.liveTickInterval(
                    currentElapsed: elapsed,
                    lyricsDocument: appState.lyricsDocument,
                    lyricOffsetSeconds: appState.effectiveLyricOffsetSeconds,
                    duration: appState.playerState.track?.duration
                ) : Self.idleResyncInterval
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                if Task.isCancelled { return }

                let now = Date()
                if isPlaying { elapsed += now.timeIntervalSince(lastWall) }
                lastWall = now
                if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                    AppTelemetry.performance.debug(
                        "Live tick localElapsed=\(elapsed) snapshotElapsed=nil delta=nil snap=false"
                    )
                }

                // Periodic watchdog against Music.app's authoritative position.
                // While the overlay is visible this is frequent enough to catch
                // seeks even if Music.app does not post a playerInfo event.
                let resyncDue = Self.liveResyncInterval(consecutiveFailures: consecutiveResyncFailures)
                if now.timeIntervalSince(lastResync) >= resyncDue,
                   let bridge = self.liveBridge {
                    lastResync = now
                    let snapshot = await bridge.currentState()
                    guard !Task.isCancelled, self.liveSessionID == sessionID else { return }
                    // A nil-track snapshot can also mean an AppleScript failure.
                    // Only process exit independently confirms disconnection.
                    if snapshot.track != nil || !self.musicAppIsRunning() {
                        consecutiveResyncFailures = 0
                        let snapshot = snapshot.track == nil ? PlayerState.disconnected : snapshot
                        let previousTrackID = appState.playerState.track?.id
                        let trackChanged = snapshot.track?.id != previousTrackID
                        if trackChanged || snapshot.playbackStatus != appState.playerState.playbackStatus {
                            appState.updatePlayerState(snapshot)
                            if trackChanged { self.liveTrackChangedCallback?(snapshot.track) }
                            elapsed = snapshot.elapsedTime
                            lastWall = Date()
                            AppTelemetry.performance.info(
                                "Live watchdog reconciled status=\(snapshot.playbackStatus.rawValue, privacy: .public) trackChanged=\(trackChanged)"
                            )
                        }
                        let decision = Self.liveResyncDecision(
                            localElapsed: elapsed,
                            currentTrackID: appState.playerState.track?.id,
                            snapshot: snapshot
                        )
                        if decision.shouldSnap || AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                            AppTelemetry.performance.info(
                                "Live tick watchdog localElapsed=\(elapsed) snapshotElapsed=\(snapshot.elapsedTime) delta=\(decision.snapshotDelta) sameTrack=\(decision.isSameTrack) snap=\(decision.shouldSnap)"
                            )
                        }
                        if decision.shouldSnap {
                            if decision.isSeek {
                                AppTelemetry.performance.info(
                                    "SEEK_DETECTED source=watchdog track=\(snapshot.track?.telemetryID ?? "none", privacy: .public) localElapsed=\(elapsed) snapshotElapsed=\(snapshot.elapsedTime) delta=\(decision.snapshotDelta)"
                                )
                                appState.updatePlayerState(snapshot)
                            }
                            AppTelemetry.performance.info(
                                "Live tick resync delta=\(decision.snapshotDelta) snap=true"
                            )
                            elapsed = snapshot.elapsedTime
                            lastWall = Date()
                        }
                    } else {
                        consecutiveResyncFailures = min(consecutiveResyncFailures + 1, 5)
                        if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                            AppTelemetry.performance.debug(
                                "Live tick watchdog snapshot missing failures=\(consecutiveResyncFailures)"
                            )
                        }
                    }
                }

                if appState.playerState.playbackStatus == .playing,
                   appState.playerState.track != nil {
                    appState.updateLiveElapsedTime(elapsed)
                }
            }
        }
    }

    static func liveTickInitialElapsed(appState: AppState) -> TimeInterval {
        appState.effectiveElapsedTime
    }

    static func liveTickInterval(
        currentElapsed: TimeInterval,
        lyricsDocument: LyricsDocument,
        lyricOffsetSeconds: Double,
        duration: TimeInterval?
    ) -> TimeInterval {
        let nextLine = LyricsSyncEngine().nextLineStart(
            in: lyricsDocument,
            after: currentElapsed + lyricOffsetSeconds,
            duration: duration
        )
        let targetElapsed = nextLine.map { $0 - lyricOffsetSeconds }
            ?? (currentElapsed + Self.liveLineTickCap)
        let targetDelta = targetElapsed - currentElapsed
        return max(Self.liveTickMinimum, min(Self.liveLineTickCap, targetDelta))
    }

    static func liveResyncDecision(
        localElapsed: TimeInterval,
        currentTrackID: String?,
        snapshot: PlayerState
    ) -> LiveResyncDecision {
        let snapshotDelta = snapshot.elapsedTime - localElapsed
        let isSameTrack = snapshot.track?.id == currentTrackID
        let shouldSnap = snapshot.playbackStatus == .playing
            && snapshot.track != nil
            && isSameTrack
            && abs(snapshotDelta) >= Self.resyncSnapThreshold
        return LiveResyncDecision(
            snapshotDelta: snapshotDelta,
            isSameTrack: isSameTrack,
            shouldSnap: shouldSnap,
            isSeek: shouldSnap && abs(snapshotDelta) > Self.seekDetectionThreshold
        )
    }

    static func liveResyncInterval(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else {
            return Self.resyncInterval
        }
        return min(
            Self.resyncFailureBackoffCap,
            Self.resyncInterval + Double(consecutiveFailures) * 2.0
        )
    }

    // MARK: - Mock Preview

    func startMockPreview(appState: AppState) {
        guard refreshTask == nil else { return }
        stopLiveAppleMusic(appState: appState)

        AppTelemetry.performance.info("Player controller mock preview started")
        appState.setMockPreviewRunning(true)
        refreshTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }

            let initialState = await bridge.currentState()
            guard !Task.isCancelled else { return }
            appState.updatePlayerState(initialState)
            var playbackClock = PlaybackClock(initialState: initialState)
            var currentState = initialState

            while !Task.isCancelled {
                let refreshInterval = self.nextRefreshInterval(
                    currentState: currentState,
                    lyricsDocument: appState.lyricsDocument
                )
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: refreshInterval))
                guard !Task.isCancelled else { return }

                currentState = playbackClock.tick(by: refreshInterval)
                appState.updateLiveElapsedTime(currentState.elapsedTime)
            }
        }
    }

    func stopMockPreview(appState: AppState? = nil) {
        guard refreshTask != nil else {
            appState?.setMockPreviewRunning(false)
            return
        }

        AppTelemetry.performance.info("Player controller mock preview stopped")
        refreshTask?.cancel()
        refreshTask = nil
        appState?.setMockPreviewRunning(false)
    }

    func nextRefreshInterval(
        currentState: PlayerState,
        lyricsDocument: LyricsDocument
    ) -> TimeInterval {
        guard currentState.playbackStatus == .playing else {
            return Self.hiddenIdleRefreshInterval
        }
        guard let nextLineStart = syncEngine.nextLineStart(
            in: lyricsDocument,
            after: currentState.elapsedTime,
            duration: currentState.track?.duration
        ) else {
            return Self.hiddenIdleRefreshInterval
        }
        return max(0.25, nextLineStart - currentState.elapsedTime)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0.25, interval) * 1_000_000_000)
    }
}

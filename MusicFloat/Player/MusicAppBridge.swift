import Foundation
import OSLog

enum MusicPlaybackCommand: Equatable, Sendable {
    case playPause
    case previousTrack
    case nextTrack
    case setVolume(Int)
    case seek(TimeInterval)

    nonisolated var clamped: MusicPlaybackCommand {
        switch self {
        case .playPause, .previousTrack, .nextTrack:
            self
        case .setVolume(let volume):
            .setVolume(Self.clampedVolume(volume))
        case .seek(let position):
            .seek(Self.clampedPlaybackPosition(position, duration: nil))
        }
    }

    nonisolated var telemetryName: String {
        switch self {
        case .playPause:
            "playPause"
        case .previousTrack:
            "previousTrack"
        case .nextTrack:
            "nextTrack"
        case .setVolume:
            "setVolume"
        case .seek:
            "seek"
        }
    }

    nonisolated static func clampedVolume(_ volume: Int) -> Int {
        min(100, max(0, volume))
    }

    nonisolated static func clampedPlaybackPosition(
        _ position: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval {
        let lowerBounded = max(0, position)
        guard let duration, duration.isFinite, duration > 0 else {
            return lowerBounded
        }
        return min(duration, lowerBounded)
    }
}

enum MusicPlaybackCommandResult: Equatable, Sendable {
    case succeeded
    case unavailable(String)
    case failed(String)

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

@MainActor
protocol MusicAppBridge {
    var displayName: String { get }

    /// Returns the current snapshot of player state. May be slow if it has to
    /// touch the underlying app (e.g. AppleScript). Use only on explicit demand
    /// or as a primer; prefer `events()` for steady-state updates.
    func currentState() async -> PlayerState

    /// A long-running stream of state updates. The default implementation
    /// returns an immediately-finished stream so mock/disabled bridges do not
    /// have to opt in.
    func events() -> AsyncStream<PlayerState>

    /// Performs a user-requested playback command. Mock/disabled bridges keep
    /// the default unavailable result so test/demo paths never command Music.app.
    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult

    /// Reads the underlying player's output volume, if available.
    func currentVolume() async -> Int?
}

extension MusicAppBridge {
    func events() -> AsyncStream<PlayerState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult {
        .unavailable("\(displayName) does not support playback commands")
    }

    func currentVolume() async -> Int? {
        nil
    }
}

struct MockMusicAppBridge: MusicAppBridge {
    let displayName = "Mock Music bridge"

    func currentState() async -> PlayerState {
        Self.previewState
    }

    static let previewTrack = NowPlayingTrack(
        id: "mock:musicfloat:architecture-preview",
        title: "Architecture Preview",
        artist: "MusicFloat",
        album: "Native Boundaries",
        duration: 132,
        providerName: "Mock"
    )

    static let previewState = PlayerState(
        playbackStatus: .playing,
        track: previewTrack,
        elapsedTime: 42,
        updatedAt: Date()
    )
}

/// Real Apple Music bridge.
///
/// Sources:
/// - Steady-state updates via `com.apple.Music.playerInfo` distributed
///   notifications (event-driven, no polling).
/// - Snapshot pulls via AppleScript for `player position`, which the
///   notification does not carry.
///
/// Behavior is gated on Music.app actually being running; if it is not, we
/// return a disconnected state and avoid AppleScript so we do not launch it.
struct PublicAppleMusicAppBridge: MusicAppBridge {
    let displayName = "Public Apple API bridge"

    struct RefinedPlayerInfoEvent: Sendable {
        let state: PlayerState
        let refineSucceeded: Bool
    }

    func currentState() async -> PlayerState {
        guard AppleMusicEventListener.isMusicAppRunning else {
            return .disconnected
        }
        return await Self.pullSnapshot() ?? .disconnected
    }

    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult {
        guard AppleMusicEventListener.isMusicAppRunning else {
            return .unavailable("Music.app is not running")
        }

        let normalizedCommand = command.clamped
        guard let raw = await AppleScriptRunner.runStringOffMain(Self.commandScript(for: normalizedCommand)),
              !raw.isEmpty else {
            return .failed("Music.app command returned no result")
        }

        if raw.hasPrefix("__ERR__||") {
            let message = raw.components(separatedBy: "||").dropFirst().first ?? "unknown"
            AppTelemetry.performance.error(
                "Music playback command failed command=\(normalizedCommand.telemetryName, privacy: .public) error=\(message, privacy: .public)"
            )
            return .failed(message)
        }

        return .succeeded
    }

    func currentVolume() async -> Int? {
        guard AppleMusicEventListener.isMusicAppRunning else {
            return nil
        }
        guard let raw = await AppleScriptRunner.runStringOffMain(Self.volumeScript),
              !raw.isEmpty,
              !raw.hasPrefix("__ERR__||") else {
            return nil
        }
        return Self.parseVolume(raw)
    }

    func events() -> AsyncStream<PlayerState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let stream = AppleMusicEventListener.makePlayerInfoStream()
            let task = Task { @MainActor in
                var lastEmittedState: PlayerState?
                var lastEmittedAt = Date()

                for await playerInfoEvent in stream {
                    let event = playerInfoEvent.state
                    if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                        AppTelemetry.performance.debug(
                            "playerInfo event=\(playerInfoEvent.sanitizedSummary, privacy: .public) parsedTrack=\(event.track?.telemetryID ?? "none", privacy: .public) parsedElapsed=\(event.elapsedTime)"
                        )
                    }
                    // Notifications do not carry `player position`. Refine with
                    // AppleScript only when the snapshot agrees with the event
                    // track; during skips Music.app can briefly report the old
                    // current track, and mixing that elapsed time with the new
                    // track makes lyrics look many lines behind.
                    var matchingSnapshot: PlayerState?
                    let isNewTrackEvent = event.track?.id != nil && event.track?.id != lastEmittedState?.track?.id

                    if event.playbackStatus != .stopped {
                        let maxAttempts = isNewTrackEvent ? 1 : 3
                        for attempt in 0..<maxAttempts {
                            if attempt > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
                            }
                            guard let snapshot = await Self.pullSnapshot() else {
                                continue
                            }
                            if let eventTrack = event.track,
                               let snapshotTrack = snapshot.track,
                                eventTrack.id != snapshotTrack.id {
                                AppTelemetry.performance.info(
                                    "Music snapshot lagged new-track event; eventTrack=\(eventTrack.telemetryID, privacy: .public) snapshotTrack=\(snapshotTrack.telemetryID, privacy: .public) starting lyrics fetch without stale elapsed"
                                )
                                continue
                            }
                            matchingSnapshot = snapshot
                            break
                        }
                    } else if event.track == nil {
                        matchingSnapshot = await Self.pullSnapshot()
                    }

                    let refinedEvent = Self.refinePlayerInfoEvent(
                        event: event,
                        lastEmittedState: lastEmittedState,
                        lastEmittedAt: lastEmittedAt,
                        snapshot: matchingSnapshot,
                        isMusicAppRunning: AppleMusicEventListener.isMusicAppRunning,
                        now: Date()
                    )
                    let refined = refinedEvent.state

                    if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                        AppTelemetry.performance.debug(
                            "playerInfo refined track=\(refined.track?.telemetryID ?? "none", privacy: .public) elapsed=\(refined.elapsedTime) refineOK=\(refinedEvent.refineSucceeded)"
                        )
                    }
                    continuation.yield(refined)
                    lastEmittedState = refined
                    lastEmittedAt = Date()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    static func refinePlayerInfoEvent(
        event: PlayerState,
        lastEmittedState: PlayerState?,
        lastEmittedAt: Date,
        snapshot: PlayerState?,
        isMusicAppRunning: Bool = true,
        now: Date
    ) -> RefinedPlayerInfoEvent {
        if let snapshot {
            if snapshot.track == nil || snapshot.playbackStatus == .stopped {
                return RefinedPlayerInfoEvent(state: .disconnected, refineSucceeded: true)
            }
            return RefinedPlayerInfoEvent(
                state: PlayerState(
                    playbackStatus: event.playbackStatus == .stopped ? snapshot.playbackStatus : event.playbackStatus,
                    track: event.track ?? snapshot.track,
                    elapsedTime: snapshot.elapsedTime,
                    updatedAt: now
                ),
                refineSucceeded: true
            )
        }

        if event.track == nil, event.playbackStatus == .stopped {
            return RefinedPlayerInfoEvent(state: .disconnected, refineSucceeded: !isMusicAppRunning)
        }

        guard let lastEmittedState,
              let lastTrack = lastEmittedState.track else {
            return RefinedPlayerInfoEvent(state: event, refineSucceeded: false)
        }

        let sameTrackEvent = event.track?.id == lastTrack.id
        let transientEmptyTrackEvent = event.track == nil && event.playbackStatus != .stopped

        if transientEmptyTrackEvent {
            return RefinedPlayerInfoEvent(
                state: PlayerState(
                    playbackStatus: event.playbackStatus,
                    track: lastTrack,
                    elapsedTime: lastEmittedState.elapsedTime,
                    updatedAt: now
                ),
                refineSucceeded: false
            )
        }

        guard sameTrackEvent else {
            return RefinedPlayerInfoEvent(state: event, refineSucceeded: false)
        }

        switch event.playbackStatus {
        case .playing:
            let playingDelta = lastEmittedState.playbackStatus == .playing
                ? max(0, now.timeIntervalSince(lastEmittedAt)) : 0
            let extrapolated = lastEmittedState.elapsedTime + playingDelta
            return RefinedPlayerInfoEvent(
                state: PlayerState(
                    playbackStatus: .playing,
                    track: event.track ?? lastTrack,
                    elapsedTime: max(0, extrapolated),
                    updatedAt: now
                ),
                refineSucceeded: false
            )
        case .paused:
            return RefinedPlayerInfoEvent(
                state: PlayerState(
                    playbackStatus: .paused,
                    track: event.track ?? lastTrack,
                    elapsedTime: event.elapsedTime > 0 ? event.elapsedTime : lastEmittedState.elapsedTime,
                    updatedAt: now
                ),
                refineSucceeded: false
            )
        case .stopped:
            return RefinedPlayerInfoEvent(state: event, refineSucceeded: false)
        }
    }

    // MARK: - AppleScript snapshot

    private static let snapshotScript = """
    try
        launch application id "com.apple.Music"
        tell application id "com.apple.Music"
            set pState to (player state as string)
            if pState is "playing" or pState is "paused" then
                set tName to name of current track
                set tArtist to artist of current track
                set tAlbum to album of current track
                set tDur to duration of current track
                set tID to (persistent ID of current track as string)
                set pPos to player position
                return pState & "||" & tName & "||" & tArtist & "||" & tAlbum & "||" & (tDur as string) & "||" & (pPos as string) & "||" & tID
            else
                return pState & "||||||||||||"
            end if
        end tell
    on error errMsg
        return "__ERR__||" & errMsg
    end try
    """

    private static let volumeScript = """
    try
        tell application id "com.apple.Music"
            return (sound volume as string)
        end tell
    on error errMsg
        return "__ERR__||" & errMsg
    end try
    """

    private static func commandScript(for command: MusicPlaybackCommand) -> String {
        let body: String
        switch command.clamped {
        case .playPause:
            body = """
            playpause
            return "ok"
            """
        case .previousTrack:
            body = """
            previous track
            return "ok"
            """
        case .nextTrack:
            body = """
            next track
            return "ok"
            """
        case .setVolume(let volume):
            body = """
            set sound volume to \(volume)
            return (sound volume as string)
            """
        case .seek(let position):
            body = """
            set player position to \(Self.appleScriptNumberLiteral(for: position))
            return (player position as string)
            """
        }

        return """
        try
            tell application id "com.apple.Music"
        \(body.indentedForAppleScriptBody)
            end tell
        on error errMsg
            return "__ERR__||" & errMsg
        end try
        """
    }

    /// Parses an AppleScript-emitted number string. Tolerates both POSIX
    /// (`42.587`) and locale forms with a decimal comma (`42,587`).
    /// Returns 0 when the input is empty or unparseable.
    nonisolated static func parseLocaleNumber(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if let v = Double(trimmed) { return v }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    nonisolated static func parseVolume(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = parseLocaleNumber(trimmed)
        guard parsed.isFinite else { return nil }
        return MusicPlaybackCommand.clampedVolume(Int(parsed.rounded()))
    }

    nonisolated static func appleScriptNumberLiteral(for value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let whole = milliseconds / 1_000
        let fraction = String(milliseconds % 1_000 + 1_000).dropFirst()
        return "\(whole).\(fraction)"
    }

    private static func pullSnapshot() async -> PlayerState? {
        guard AppleMusicEventListener.isMusicAppRunning else { return nil }
        guard let raw = await AppleScriptRunner.runStringOffMain(snapshotScript), !raw.isEmpty else {
            return nil
        }
        let parts = raw.components(separatedBy: "||")
        let stateString = parts.first ?? "stopped"
        if stateString == "__ERR__" {
            let msg = parts.count > 1 ? parts[1] : "unknown"
            AppTelemetry.performance.error("Music snapshot script error: \(msg, privacy: .public)")
            return nil
        }
        let status: PlaybackStatus = {
            switch stateString.lowercased() {
            case "playing": return .playing
            case "paused": return .paused
            default: return .stopped
            }
        }()

        let title = parts.count > 1 ? parts[1] : ""
        let artist = parts.count > 2 ? parts[2] : ""
        let album = parts.count > 3 ? parts[3] : ""
        // AppleScript serializes numbers using the user's locale (e.g.
        // "42,587" in many EU locales). Normalize to period decimal before
        // handing to Swift's Double initializer, which expects POSIX form.
        let duration = parseLocaleNumber(parts.count > 4 ? parts[4] : "")
        let elapsed = parseLocaleNumber(parts.count > 5 ? parts[5] : "")
        let persistentID = parts.count > 6 ? parts[6] : ""

        if title.isEmpty {
            return PlayerState(
                playbackStatus: status,
                track: nil,
                elapsedTime: 0,
                updatedAt: Date()
            )
        }

        let track = NowPlayingTrack(
            id: persistentID.isEmpty ? "\(artist)|\(album)|\(title)" : persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            providerName: AppleMusicEventListener.providerName
        )

        return PlayerState(
            playbackStatus: status,
            track: track,
            elapsedTime: elapsed,
            updatedAt: Date()
        )
    }
}

struct DisabledMusicAppBridge: MusicAppBridge {
    let displayName = "Disabled music bridge"

    func currentState() async -> PlayerState {
        .disconnected
    }
}

private extension String {
    var indentedForAppleScriptBody: String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { "        " + $0 }
            .joined(separator: "\n")
    }
}

import Foundation
import OSLog

/// Owns the optional native MediaRemote process and converts its small JSON
/// protocol into the app's public PlayerState value type.
///
/// The helper is intentionally a separate process because MediaRemote is a
/// private framework and its client policy is not an app contract. A failed
/// launch, missing helper, malformed message, or terminated process falls back
/// to the public Music.app bridge.
@MainActor
final class MediaRemoteHelperSession {
    private static let helperName = "MediaRemoteHelper"
    private static let protocolVersion = 1
    private static let startupGrace: TimeInterval = 0.35

    private let fallback = PublicAppleMusicAppBridge()
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var currentStateValue = PlayerState.disconnected
    private var helperReady = false
    private var initialStateReceived = false
    private var stateContinuation: AsyncStream<PlayerState>.Continuation?
    private var helperUnavailableReason: String?

    deinit {
        outputTask?.cancel()
        process?.terminate()
    }

    func currentState() async -> PlayerState {
        startIfNeeded()
        if process != nil, !helperReady {
            try? await Task.sleep(nanoseconds: UInt64(Self.startupGrace * 1_000_000_000))
        }
        guard helperReady else {
            return await fallback.currentState()
        }

        if !initialStateReceived {
            try? await Task.sleep(nanoseconds: UInt64(Self.startupGrace * 1_000_000_000))
        }
        return currentStateValue
    }

    func events() -> AsyncStream<PlayerState> {
        startIfNeeded()
        guard process != nil else {
            return fallback.events()
        }

        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            stateContinuation?.finish()
            stateContinuation = continuation
            if initialStateReceived {
                continuation.yield(currentStateValue)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stateContinuation = nil
                }
            }
        }
    }

    private func startIfNeeded() {
        guard process == nil, helperUnavailableReason == nil else { return }
        guard !CommandLine.arguments.contains("--disable-experimental-mediaremote") else {
            helperUnavailableReason = "disabled-by-flag"
            AppTelemetry.lifecycle.info("MediaRemote helper disabled by command line flag")
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.helperName, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            helperUnavailableReason = "bundled-helper-missing"
            AppTelemetry.lifecycle.info("MediaRemote helper unavailable reason=bundled-helper-missing")
            return
        }

        let pipe = Pipe()
        let child = Process()
        child.executableURL = helperURL
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.helperTerminated(status: process.terminationStatus)
            }
        }

        do {
            try child.run()
        } catch {
            helperUnavailableReason = "launch-failed"
            AppTelemetry.lifecycle.info("MediaRemote helper unavailable reason=launch-failed")
            return
        }

        process = child
        outputPipe = pipe
        AppTelemetry.lifecycle.info("MediaRemote helper started")
        startReader(for: pipe.fileHandleForReading)
    }

    private func startReader(for handle: FileHandle) {
        outputTask = Task { @MainActor [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self else { return }
                    consume(line)
                }
            } catch {
                // The termination handler records the capability failure. A
                // broken pipe is expected when the helper is stopped normally.
            }
        }
    }

    private func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let version = payload["version"] as? Int,
              version == Self.protocolVersion,
              let status = payload["status"] as? String else {
            AppTelemetry.lifecycle.info("MediaRemote helper message rejected reason=invalid-protocol")
            return
        }

        switch status {
        case "ready":
            helperReady = true
        case "unavailable":
            helperUnavailableReason = (payload["reason"] as? String) ?? "helper-unavailable"
            stopHelper()
        case "stopped":
            helperReady = true
            initialStateReceived = true
            currentStateValue = .disconnected
            stateContinuation?.yield(currentStateValue)
        case "playing", "paused":
            guard let state = parseState(payload, status: status) else {
                AppTelemetry.lifecycle.info("MediaRemote helper message rejected reason=invalid-state")
                return
            }
            helperReady = true
            initialStateReceived = true
            currentStateValue = state
            stateContinuation?.yield(state)
        default:
            AppTelemetry.lifecycle.info("MediaRemote helper message rejected reason=unknown-status")
        }
    }

    private func parseState(_ payload: [String: Any], status: String) -> PlayerState? {
        guard let title = payload["title"] as? String,
              let artist = payload["artist"] as? String,
              let album = payload["album"] as? String,
              let bundleIdentifier = payload["bundleIdentifier"] as? String,
              bundleIdentifier == "com.apple.Music" else {
            return nil
        }

        let duration = finiteNumber(payload["duration"]) ?? 0
        let rawElapsed = finiteNumber(payload["elapsed"]) ?? 0
        let rate = finiteNumber(payload["rate"]) ?? (status == "playing" ? 1 : 0)
        let timestamp = finiteNumber(payload["timestamp"])
        let elapsed = adjustedElapsed(
            rawElapsed: rawElapsed,
            rate: rate,
            timestamp: timestamp,
            duration: duration
        )
        let uniqueIdentifier = payload["uniqueIdentifier"] as? String
        let contentIdentifier = payload["contentIdentifier"] as? String
        let id = uniqueIdentifier?.isEmpty == false
            ? uniqueIdentifier!
            : (contentIdentifier?.isEmpty == false
                ? contentIdentifier!
                : [bundleIdentifier, artist, album, title].joined(separator: "|"))

        return PlayerState(
            playbackStatus: status == "playing" ? .playing : .paused,
            track: NowPlayingTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                duration: max(0, duration),
                providerName: "MediaRemote (experimental)"
            ),
            elapsedTime: elapsed,
            updatedAt: Date()
        )
    }

    private func adjustedElapsed(
        rawElapsed: TimeInterval,
        rate: TimeInterval,
        timestamp: TimeInterval?,
        duration: TimeInterval
    ) -> TimeInterval {
        var elapsed = max(0, rawElapsed)
        if let timestamp, rate > 0 {
            elapsed += max(0, Date().timeIntervalSince1970 - timestamp) * rate
        }
        guard duration.isFinite, duration > 0 else { return elapsed }
        return min(duration, elapsed)
    }

    private func finiteNumber(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func helperTerminated(status: Int32) {
        guard process != nil else { return }
        process = nil
        outputPipe = nil
        outputTask?.cancel()
        outputTask = nil
        helperReady = false
        if helperUnavailableReason == nil {
            helperUnavailableReason = status == 0 ? "helper-exited" : "helper-terminated"
        }
        stateContinuation?.finish()
        stateContinuation = nil
        AppTelemetry.lifecycle.info("MediaRemote helper terminated status=\(status, privacy: .public)")
    }

    private func stopHelper() {
        process?.terminate()
        helperTerminated(status: process?.terminationStatus ?? 0)
    }
}

struct ExperimentalMusicAppBridge: MusicAppBridge {
    let displayName = "Experimental MediaRemote bridge"
    private let session: MediaRemoteHelperSession

    init(session: MediaRemoteHelperSession = MediaRemoteHelperSession()) {
        self.session = session
    }

    func currentState() async -> PlayerState {
        await session.currentState()
    }

    func events() -> AsyncStream<PlayerState> {
        session.events()
    }

    func perform(_ command: MusicPlaybackCommand) async -> MusicPlaybackCommandResult {
        await PublicAppleMusicAppBridge().perform(command)
    }

    func currentVolume() async -> Int? {
        await PublicAppleMusicAppBridge().currentVolume()
    }
}

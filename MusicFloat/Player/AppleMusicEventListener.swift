import AppKit
import Foundation
import OSLog

/// Subscribes to `com.apple.Music.playerInfo` distributed notifications and
/// projects them into `PlayerState` snapshots.
///
/// The notification fires on play/pause and track change with a userInfo
/// dictionary containing track metadata and player state. It does NOT carry
/// player position, so callers that need an accurate elapsed time should pull
/// it via `PublicAppleMusicAppBridge.currentState()`.
@MainActor
enum AppleMusicEventListener {
    private static let notificationName = Notification.Name("com.apple.Music.playerInfo")
    private static let bundleIdentifier = "com.apple.Music"
    nonisolated static let providerName = "Apple Music"

    struct PlayerInfoEvent: Sendable {
        let state: PlayerState
        let sanitizedSummary: String
    }

    /// An async stream of raw-enough playerInfo events for diagnostics plus the
    /// parsed state used by production code.
    static func makePlayerInfoStream() -> AsyncStream<PlayerInfoEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let center = DistributedNotificationCenter.default()
            let observer = center.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { note in
                if let event = makeEvent(userInfo: note.userInfo) {
                    continuation.yield(event)
                }
            }

            let box = ObserverBox(observer: observer)
            continuation.onTermination = { _ in
                DistributedNotificationCenter.default().removeObserver(box.observer)
            }
        }
    }

    nonisolated private final class ObserverBox: @unchecked Sendable {
        let observer: any NSObjectProtocol
        init(observer: any NSObjectProtocol) { self.observer = observer }
    }

    /// True when the Music app process is alive. Used to short-circuit
    /// AppleScript launches that would otherwise spawn Music headlessly.
    static var isMusicAppRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .isEmpty
    }

    // MARK: - Parsing

    nonisolated static func makeEvent(userInfo info: [AnyHashable: Any]?) -> PlayerInfoEvent? {
        let info = info ?? [:]
        let rawState = (info["Player State"] as? String) ?? "Stopped"
        let status: PlaybackStatus = {
            switch rawState.lowercased() {
            case "playing": return .playing
            case "paused": return .paused
            default: return .stopped
            }
        }()

        let title = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""

        let totalTimeMs: Double = {
            if let v = info["Total Time"] as? NSNumber { return v.doubleValue }
            if let v = info["Total Time"] as? Double { return v }
            return 0
        }()
        let duration = totalTimeMs / 1000.0

        let notificationPersistentID: String? = {
            if let v = info["PersistentID"] as? NSNumber {
                return canonicalPersistentID(v.uint64Value)
            }
            if let v = info["Persistent ID"] as? String {
                return canonicalPersistentID(v) ?? v
            }
            return nil
        }()
        let persistentID = notificationPersistentID ?? "\(artist)|\(album)|\(title)"
        let sanitizedSummary = [
            "state=\(rawState)",
            "hasName=\(!title.isEmpty)",
            "hasArtist=\(!artist.isEmpty)",
            "hasAlbum=\(!album.isEmpty)",
            "durationMs=\(Int(totalTimeMs.rounded()))",
            "persistentIDSource=\(notificationPersistentID == nil ? "fallback" : "notification")"
        ].joined(separator: " ")

        let track = title.isEmpty ? nil : NowPlayingTrack(
            id: persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            providerName: providerName
        )

        // `playerInfo` does not include player position. Caller is expected to
        // refine elapsedTime via an on-demand AppleScript pull if needed.
        let state = PlayerState(
            playbackStatus: status,
            track: track,
            elapsedTime: 0,
            updatedAt: Date()
        )
        return PlayerInfoEvent(state: state, sanitizedSummary: sanitizedSummary)
    }

    nonisolated static func canonicalPersistentID(_ value: UInt64) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    nonisolated static func canonicalPersistentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard trimmed.unicodeScalars.allSatisfy({ hexCharacterSet.contains($0) }),
              trimmed.count <= 16,
              let value = UInt64(trimmed, radix: 16) else {
            return nil
        }
        return canonicalPersistentID(value)
    }
}

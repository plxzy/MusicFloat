import Foundation
import OSLog
@preconcurrency @unsafe import ScriptingBridge

/// Apple-event access to Music.app without OSAKit.
///
/// Any in-process OSA execution (compiling source, loading a precompiled
/// `.scpt`, even `return 1 + 1`) makes XProtect build and cache its YARA rules
/// inside this process: roughly 13 MB of dirty memory for the process lifetime.
/// ScriptingBridge sends the same Apple events without OSA, at roughly 2 MB.
///
/// Each query returns the same raw string shape as the AppleScript it replaces,
/// so callers keep one parser for both backends. Launch with
/// `--osakit-music-scripting` to fall back to the AppleScript path.
nonisolated enum MusicScriptingBridge {
    static let isEnabled = !CommandLine.arguments.contains("--osakit-music-scripting")

    static func snapshotString() async -> String? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.snapshotString() }
    }

    static func volumeString() async -> String? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.volumeString() }
    }

    static func commandString(for command: MusicPlaybackCommand) async -> String? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.commandString(for: command) }
    }

    static func lyricsString() async -> String? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.lyricsString() }
    }

    static func currentTrackURLString() async -> String? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.currentTrackURLString() }
    }

    static func artworkData() async -> Data? {
        await AppleScriptRunner.performOffMain { MusicScriptingSession.shared.artworkData() }
    }
}

/// Owns the `SBApplication`. Only touched from the AppleScript worker thread.
nonisolated private final class MusicScriptingSession: NSObject, SBApplicationDelegate, @unchecked Sendable {
    static let shared = MusicScriptingSession()

    private var cachedApplication: SBApplication?
    private var lastError: NSError?

    private var application: SBApplication? {
        if cachedApplication == nil {
            cachedApplication = SBApplication(bundleIdentifier: "com.apple.Music")
            cachedApplication?.delegate = self
        }
        return cachedApplication
    }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lastError = error as NSError
        return nil
    }

    func snapshotString() -> String? {
        guard let app = application else { return nil }
        lastError = nil
        let state = playerStateName(app.property(withCode: Code.playerState).get())
        if let failure = failureMessage() { return "__ERR__||" + failure }
        guard state == "playing" || state == "paused" else {
            return state + "||||||||||||"
        }

        let track = app.property(withCode: Code.currentTrack)
        let title = string(track, Code.name)
        let artist = string(track, Code.artist)
        let album = string(track, Code.album)
        let duration = number(track.property(withCode: Code.duration).get())
        let persistentID = string(track, Code.persistentID)
        let position = number(app.property(withCode: Code.playerPosition).get())
        if let failure = failureMessage() { return "__ERR__||" + failure }

        return [
            state, title, artist, album,
            Self.posixString(duration), Self.posixString(position), persistentID,
        ].joined(separator: "||")
    }

    func volumeString() -> String? {
        guard let app = application else { return nil }
        lastError = nil
        let volume = number(app.property(withCode: Code.soundVolume).get())
        if let failure = failureMessage() { return "__ERR__||" + failure }
        return volume.map { String(Int($0.rounded())) }
    }

    func commandString(for command: MusicPlaybackCommand) -> String? {
        guard let app = application else { return nil }
        lastError = nil
        switch command.clamped {
        case .playPause:
            _ = unsafe app.perform(Selector(("playpause")))
        case .previousTrack:
            _ = unsafe app.perform(Selector(("previousTrack")))
        case .nextTrack:
            _ = unsafe app.perform(Selector(("nextTrack")))
        case .setVolume(let volume):
            app.property(withCode: Code.soundVolume).setTo(NSNumber(value: volume))
        case .seek(let position):
            app.property(withCode: Code.playerPosition).setTo(NSNumber(value: position))
        }
        if let failure = failureMessage() { return "__ERR__||" + failure }
        return "ok"
    }

    func lyricsString() -> String? {
        guard let app = application else { return nil }
        guard app.isRunning else { return "__NOT_RUNNING__" }
        lastError = nil
        let state = playerStateName(app.property(withCode: Code.playerState).get())
        if let failure = failureMessage() { return "__SCRIPT_ERROR__||" + failure }
        guard state == "playing" || state == "paused" else {
            return "__STATE__||" + state
        }

        let lyrics = app.property(withCode: Code.currentTrack)
            .property(withCode: Code.lyrics).get() as? String
        if let failure = failureMessage() { return "__ERROR__||" + failure }
        guard let lyrics, !lyrics.isEmpty else { return "__EMPTY__" }
        return "__LYRICS__\n" + lyrics
    }

    func currentTrackURLString() -> String? {
        guard let app = application, app.isRunning else { return "" }
        lastError = nil
        let url = app.property(withCode: Code.currentTrack)
            .property(withCode: Code.address).get() as? String
        return failureMessage() == nil ? (url ?? "") : ""
    }

    func artworkData() -> Data? {
        guard let app = application, app.isRunning else { return nil }
        lastError = nil
        let artworks = app.property(withCode: Code.currentTrack).elementArray(withCode: Code.artwork)
        guard artworks.count > 0, let artwork = artworks.object(at: 0) as? SBObject else {
            return nil
        }
        let raw = artwork.property(withCode: Code.rawData).get()
        guard failureMessage() == nil else { return nil }
        switch raw {
        case let data as Data:
            return data
        case let descriptor as NSAppleEventDescriptor:
            let payload = descriptor.data
            return payload.isEmpty ? descriptor.coerce(toDescriptorType: typeData)?.data : payload
        default:
            return nil
        }
    }

    private func failureMessage() -> String? {
        guard let lastError else { return nil }
        let code = lastError.code
        Task { @MainActor in
            AppTelemetry.performance.error("Music ScriptingBridge event failed code=\(code, privacy: .public)")
        }
        return lastError.localizedDescription
    }

    private func string(_ object: SBObject, _ code: AEKeyword) -> String {
        object.property(withCode: code).get() as? String ?? ""
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func playerStateName(_ value: Any?) -> String {
        let code = (value as? NSAppleEventDescriptor)?.enumCodeValue
            ?? (value as? NSNumber)?.uint32Value
        switch code {
        case Code.playing: return "playing"
        case Code.paused: return "paused"
        case Code.fastForwarding: return "fast forwarding"
        case Code.rewinding: return "rewinding"
        default: return "stopped"
        }
    }

    /// Matches the snapshot parser, which expects POSIX decimals.
    private static func posixString(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }

    /// Four-char codes from Music.app's scripting dictionary (`sdef`).
    private enum Code {
        static let playerState: AEKeyword = 0x7050_6C53 // pPlS
        static let playerPosition: AEKeyword = 0x7050_6F73 // pPos
        static let soundVolume: AEKeyword = 0x7056_6F6C // pVol
        static let currentTrack: AEKeyword = 0x7054_726B // pTrk
        static let name: AEKeyword = 0x706E_616D // pnam
        static let artist: AEKeyword = 0x7041_7274 // pArt
        static let album: AEKeyword = 0x7041_6C62 // pAlb
        static let duration: AEKeyword = 0x7044_7572 // pDur
        static let persistentID: AEKeyword = 0x7050_4953 // pPIS
        static let lyrics: AEKeyword = 0x704C_7972 // pLyr
        static let address: AEKeyword = 0x7055_524C // pURL
        static let artwork: DescType = 0x6341_7274 // cArt
        static let rawData: AEKeyword = 0x7052_6177 // pRaw
        static let playing: UInt32 = 0x6B50_5350 // kPSP
        static let paused: UInt32 = 0x6B50_5370 // kPSp
        static let fastForwarding: UInt32 = 0x6B50_5346 // kPSF
        static let rewinding: UInt32 = 0x6B50_5352 // kPSR
    }
}

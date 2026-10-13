import XCTest
@testable import MusicFloat

@MainActor
final class MediaRemoteHelperSessionTests: XCTestCase {
    private let track = NowPlayingTrack(
        id: "mr-track",
        title: "Title",
        artist: "Artist",
        album: "Album",
        duration: 100,
        providerName: "MediaRemote (experimental)"
    )

    func testPlayingStateAdvancesByElapsedWallTimeAndRate() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let state = PlayerState(playbackStatus: .playing, track: track, elapsedTime: 20, updatedAt: updatedAt)

        let result = MediaRemoteHelperSession.extrapolated(state, rate: 1, now: updatedAt.addingTimeInterval(7))

        XCTAssertEqual(result.elapsedTime, 27, accuracy: 0.0001)
        XCTAssertEqual(result.updatedAt, updatedAt.addingTimeInterval(7))
    }

    func testPausedStateIsNotAdvanced() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let state = PlayerState(playbackStatus: .paused, track: track, elapsedTime: 20, updatedAt: updatedAt)

        let result = MediaRemoteHelperSession.extrapolated(state, rate: 1, now: updatedAt.addingTimeInterval(7))

        XCTAssertEqual(result, state)
    }

    func testExtrapolationClampsToTrackDuration() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let state = PlayerState(playbackStatus: .playing, track: track, elapsedTime: 95, updatedAt: updatedAt)

        let result = MediaRemoteHelperSession.extrapolated(state, rate: 1, now: updatedAt.addingTimeInterval(30))

        XCTAssertEqual(result.elapsedTime, 100, accuracy: 0.0001)
    }
}

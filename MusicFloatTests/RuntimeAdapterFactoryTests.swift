import XCTest
@testable import MusicFloat

final class RuntimeAdapterFactoryTests: XCTestCase {
    @MainActor
    func testArchitectureDefaultFactoryUsesMockAdapters() {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)

        XCTAssertEqual(adapters.musicBridge.displayName, "Mock Music bridge")
        XCTAssertEqual(adapters.lyricsProvider.displayName, "Mock lyrics provider")
        XCTAssertEqual(adapters.translationProvider.displayName, "Mock translation provider")
    }

    @MainActor
    func testArchitectureDefaultMockPreviewUsesMockProviderPayloads() async {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)

        let lyricsResult = await adapters.lyricsProvider.lyrics(for: MockMusicAppBridge.previewTrack)
        let translationResult = await adapters.translationProvider.translation(
            for: MockLyricsProvider.previewDocument,
            targetLanguageIdentifier: "fr"
        )

        XCTAssertEqual(lyricsResult, .available(MockLyricsProvider.previewDocument))
        XCTAssertEqual(
            translationResult,
            .available(MockTranslationProvider.previewTranslation(targetLanguageIdentifier: "fr"))
        )
    }

    @MainActor
    func testLiveAppleMusicFactoryPrefersExperimentalPlayerAndPublicProviders() {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .liveAppleMusic)

        XCTAssertEqual(adapters.musicBridge.displayName, "Experimental MediaRemote bridge")
        XCTAssertEqual(adapters.lyricsProvider.displayName, "Public lyrics provider")
        XCTAssertEqual(adapters.translationProvider.displayName, "Apple on-device translation")
    }
}

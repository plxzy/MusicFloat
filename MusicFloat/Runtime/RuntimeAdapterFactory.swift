import Foundation

@MainActor
struct RuntimeAdapters {
    let musicBridge: any MusicAppBridge
    let lyricsProvider: any LyricsProvider
    let translationProvider: any TranslationProvider
}

@MainActor
enum RuntimeAdapterFactory {
    static func makeAdapters(for flags: RuntimeFeatureFlags) -> RuntimeAdapters {
        RuntimeAdapters(
            musicBridge: makeMusicBridge(for: flags.playerBridgeMode),
            lyricsProvider: makeLyricsProvider(for: flags.lyricsProviderMode),
            translationProvider: makeTranslationProvider(for: flags.translationProviderMode)
        )
    }

    static func makeMusicBridge(for mode: RuntimeAdapterMode) -> any MusicAppBridge {
        switch mode {
        case .mock:
            MockMusicAppBridge()
        case .publicApple:
            PublicAppleMusicAppBridge()
        case .experimental:
            ExperimentalMusicAppBridge()
        case .disabled:
            DisabledMusicAppBridge()
        }
    }

    private static func makeLyricsProvider(for mode: RuntimeAdapterMode) -> any LyricsProvider {
        switch mode {
        case .mock:
            MockLyricsProvider()
        case .publicApple:
            PublicLyricsProvider()
        case .experimental:
            ExperimentalLyricsProviderPlaceholder()
        case .disabled:
            DisabledLyricsProvider()
        }
    }

    private static func makeTranslationProvider(for mode: RuntimeAdapterMode) -> any TranslationProvider {
        switch mode {
        case .mock:
            MockTranslationProvider()
        case .publicApple:
            AppleTranslationProvider()
        case .experimental:
            ExperimentalTranslationProviderPlaceholder()
        case .disabled:
            DisabledTranslationProvider()
        }
    }
}

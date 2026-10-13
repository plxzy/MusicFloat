import Foundation

nonisolated enum RuntimeAdapterMode: String, CaseIterable, Identifiable, Sendable {
    case mock
    case publicApple
    case experimental
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mock:
            "Mock"
        case .publicApple:
            "Public Apple API"
        case .experimental:
            "Experimental"
        case .disabled:
            "Disabled"
        }
    }

    var translationProviderDisplayName: String {
        switch self {
        case .mock:
            "Mock translation provider"
        case .publicApple:
            #if ENABLE_APPLE_TRANSLATION
            "Apple on-device translation"
            #else
            "Apple on-device translation (not enabled in this build)"
            #endif
        case .experimental:
            "Experimental translation provider placeholder"
        case .disabled:
            "Disabled translation provider"
        }
    }
}

nonisolated struct RuntimeFeatureFlags: Equatable, Sendable {
    var playerBridgeMode: RuntimeAdapterMode
    var lyricsProviderMode: RuntimeAdapterMode
    var translationProviderMode: RuntimeAdapterMode
    var allowsHiddenProviderRefresh: Bool

    static let architectureDefault = RuntimeFeatureFlags(
        playerBridgeMode: .mock,
        lyricsProviderMode: .mock,
        translationProviderMode: .mock,
        allowsHiddenProviderRefresh: false
    )

    static let liveAppleMusic = RuntimeFeatureFlags(
        playerBridgeMode: .experimental,
        lyricsProviderMode: .publicApple,
        translationProviderMode: .publicApple,
        allowsHiddenProviderRefresh: false
    )
}

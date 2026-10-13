import OSLog
import SwiftUI
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

struct SettingsView: View {
    @Bindable var appState: AppState
    var onTranslationPreferencesChanged: () -> Void = {}
    var onOverlayLayoutPreferencesChanged: () -> Void = {}
    var onTranslationPreparationCompleted: () -> Void = {}
    var onDiskMediaCachePreferenceChanged: (Bool) async -> Void = { _ in }
    var mediaCacheUsageText: () async -> String = { "Memory 0 KB - Disk Off" }
    var clearMediaCache: () async -> Void = {}

    @AppStorage("showTranslation") private var showsTranslation = true
    @AppStorage("preferredTranslationLanguageIdentifier") private var preferredTranslationLanguageIdentifier = AppState.systemLanguageIdentifier
    @AppStorage("overlayWidthPreset") private var overlayWidthPresetRaw = OverlayWidthPreset.medium.rawValue
    @AppStorage("reduceHiddenMemoryUsage") private var reduceHiddenMemoryUsage = true
    @AppStorage("lrclibFallbackEnabled") private var lrclibFallbackEnabled = true
    @AppStorage("diskMediaCacheEnabled") private var diskMediaCacheEnabled = false
    @State private var mediaUserTokenInput: String = ""
    @State private var mediaUserTokenSavedHint: String = ""
    @State private var mediaCacheStatusText: String = "Checking..."
    @State private var isClearingMediaCache = false
    @State private var supportedTranslationLanguages: [Locale.Language] = []
    #if ENABLE_APPLE_TRANSLATION
    @State private var preparationConfiguration: TranslationSession.Configuration?
    @State private var preparationRequest: PreparedTranslationRequest?
    #endif

    var body: some View {
        #if ENABLE_APPLE_TRANSLATION
        let request = preparationRequest
        settingsForm
            .translationTask(preparationConfiguration) { session in
                guard let request else { return }
                await prepareTranslationLanguages(with: session, request: request)
            }
            .task(id: appState.translationPreparationContextID) {
                if let preparationRequest, !appState.ownsPreparedTranslationRequest(preparationRequest) {
                    cancelTranslationPreparation()
                }
            }
            .onDisappear {
                cancelTranslationPreparation()
            }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("Apple Music") {
                if MediaUserTokenStore.isConfigured {
                    LabeledContent("media-user-token", value: "Configured")
                } else {
                    LabeledContent("media-user-token", value: "Not configured")
                        .foregroundStyle(.secondary)
                }
                SecureField("Paste media-user-token", text: $mediaUserTokenInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        MediaUserTokenStore.save(mediaUserTokenInput)
                        mediaUserTokenInput = ""
                        mediaUserTokenSavedHint = MediaUserTokenStore.isConfigured ? "Saved." : "Cleared."
                        AppTelemetry.settings.info("media-user-token saved configured=\(MediaUserTokenStore.isConfigured)")
                    }
                    .disabled(mediaUserTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        MediaUserTokenStore.clear()
                        mediaUserTokenInput = ""
                        mediaUserTokenSavedHint = "Cleared."
                        AppTelemetry.settings.info("media-user-token cleared")
                    }
                    .disabled(!MediaUserTokenStore.isConfigured)
                    Spacer()
                    if !mediaUserTokenSavedHint.isEmpty {
                        Text(mediaUserTokenSavedHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Sign in at music.apple.com, copy the `media-user-token` cookie value from your browser's devtools, paste it here. Required to fetch the same timed lyrics Music.app uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow LRCLIB / Music app UI fallback", isOn: $lrclibFallbackEnabled)
                Text("When Apple has no lyrics for a track, fall back to LRCLIB and the Music.app lyrics panel. Disable to pin lyrics to Apple's data only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overlay") {
                Toggle("Show translation", isOn: $showsTranslation)

                Picker("Width", selection: $overlayWidthPresetRaw) {
                    ForEach(OverlayWidthPreset.allCases) { preset in
                        Text(preset.displayName)
                            .tag(preset.rawValue)
                    }
                }
            }

            Section("Translation") {
                Picker("Target language", selection: $preferredTranslationLanguageIdentifier) {
                    ForEach(translationLanguageOptions, id: \.minimalIdentifier) { language in
                        Text(Self.localizedLanguageName(for: language.minimalIdentifier))
                            .tag(language.minimalIdentifier)
                    }
                }

                LabeledContent("Provider", value: appState.runtimeFeatureFlags.translationProviderMode.translationProviderDisplayName)
                LabeledContent("Target", value: appState.preferredTranslationLanguageName)
                LabeledContent("Source", value: appState.lyricsSourceLanguageName)
                LabeledContent("Status", value: appState.translationRuntimeState.detailText)

                #if ENABLE_APPLE_TRANSLATION
                if appState.pendingTranslationDownload != nil {
                    Button("Prepare Translation Languages") {
                        scheduleTranslationPreparation()
                    }
                }
                #endif
            }

            Section("Runtime") {
                Toggle("Reduce hidden memory use", isOn: $reduceHiddenMemoryUsage)
                LabeledContent("Player bridge", value: appState.runtimeFeatureFlags.playerBridgeMode.displayName)
                LabeledContent("Lyrics provider", value: appState.runtimeFeatureFlags.lyricsProviderMode.displayName)
                LabeledContent("Translation provider", value: appState.runtimeFeatureFlags.translationProviderMode.displayName)
                LabeledContent("Hidden refresh", value: appState.runtimeFeatureFlags.allowsHiddenProviderRefresh ? "Enabled" : "Disabled")
                LabeledContent("Provider state", value: appState.providerRuntimeState.displayName)
                LabeledContent("Translation state", value: appState.translationRuntimeState.displayName)
            }

            Section("Cache") {
                Toggle("Disk cache", isOn: $diskMediaCacheEnabled)
                LabeledContent("Usage", value: mediaCacheStatusText)
                HStack {
                    Button("Clear Cache") {
                        Task { @MainActor in
                            isClearingMediaCache = true
                            await clearMediaCache()
                            await refreshMediaCacheUsage()
                            isClearingMediaCache = false
                        }
                    }
                    .disabled(isClearingMediaCache)

                    if isClearingMediaCache {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .onAppear {
            AppTelemetry.settings.info("Settings view appeared")
            syncPreferencesToAppState()
        }
        .task {
            await loadTranslationLanguageOptions()
            await refreshMediaCacheUsage()
        }
        .onChange(of: showsTranslation) {
            syncPreferencesToAppState()
        }
        .onChange(of: preferredTranslationLanguageIdentifier) {
            syncPreferencesToAppState()
        }
        .onChange(of: overlayWidthPresetRaw) {
            syncPreferencesToAppState()
            onOverlayLayoutPreferencesChanged()
        }
        .onChange(of: reduceHiddenMemoryUsage) {
            syncPreferencesToAppState()
        }
        .onChange(of: diskMediaCacheEnabled) {
            Task { @MainActor in
                await onDiskMediaCachePreferenceChanged(diskMediaCacheEnabled)
                await refreshMediaCacheUsage()
            }
        }
    }

    private var translationLanguageOptions: [Locale.Language] {
        let current = Locale.Language(identifier: preferredTranslationLanguageIdentifier)
        guard !supportedTranslationLanguages.isEmpty else {
            return [current]
        }
        if supportedTranslationLanguages.contains(where: { $0.minimalIdentifier == current.minimalIdentifier }) {
            return supportedTranslationLanguages
        }
        return ([current] + supportedTranslationLanguages).sorted {
            Self.localizedLanguageName(for: $0.minimalIdentifier) < Self.localizedLanguageName(for: $1.minimalIdentifier)
        }
    }

    private func syncPreferencesToAppState() {
        let widthPreset = OverlayWidthPreset(rawValue: overlayWidthPresetRaw) ?? .medium
        let translationPreferencesChanged = appState.applyPreferences(
            showsTranslation: showsTranslation,
            preferredTranslationLanguageIdentifier: preferredTranslationLanguageIdentifier,
            overlayWidthPreset: widthPreset,
            reduceHiddenMemoryUsage: reduceHiddenMemoryUsage
        )
        if translationPreferencesChanged {
            onTranslationPreferencesChanged()
        }
    }

    private func loadTranslationLanguageOptions() async {
        let languages = await Self.loadSupportedTranslationLanguages()
        supportedTranslationLanguages = languages.sorted {
            Self.localizedLanguageName(for: $0.minimalIdentifier) < Self.localizedLanguageName(for: $1.minimalIdentifier)
        }
        if !supportedTranslationLanguages.isEmpty,
           !Self.languageList(supportedTranslationLanguages, containsIdentifier: preferredTranslationLanguageIdentifier) {
            preferredTranslationLanguageIdentifier = Self.defaultSupportedTargetLanguageIdentifier(
                from: supportedTranslationLanguages
            )
            syncPreferencesToAppState()
        }
    }

    private func refreshMediaCacheUsage() async {
        mediaCacheStatusText = await mediaCacheUsageText()
    }

    private static func localizedLanguageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    #if ENABLE_APPLE_TRANSLATION
    private func scheduleTranslationPreparation() {
        guard let request = appState.beginPreparedTranslationRequest() else { return }
        var configuration = preparationConfiguration ?? TranslationSession.Configuration(preferredStrategy: .lowLatency)
        configuration.source = Locale.Language(identifier: request.sourceLanguageIdentifier)
        configuration.target = Locale.Language(identifier: request.targetLanguageIdentifier)
        configuration.invalidate()
        preparationRequest = request
        preparationConfiguration = configuration
        AppTelemetry.settings.info("Translation preparation requested")
    }

    private func cancelTranslationPreparation() {
        if let preparationRequest {
            _ = appState.cancelPreparedTranslation(preparationRequest)
        }
        preparationRequest = nil
        preparationConfiguration = nil
    }

    private func prepareTranslationLanguages(
        with session: TranslationSession,
        request: PreparedTranslationRequest
    ) async {
        defer {
            if preparationRequest?.id == request.id {
                preparationRequest = nil
                preparationConfiguration = nil
            }
        }
        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: { try await session.prepareTranslation() },
            translate: { document, target in
                try await PreparedTranslationSessionTranslator.translation(
                    using: session,
                    for: document,
                    targetLanguageIdentifier: target
                )
            }
        )
        if outcome == .retry {
            onTranslationPreparationCompleted()
        }
    }
    #endif

    private static func languageList(
        _ languages: [Locale.Language],
        containsIdentifier identifier: String
    ) -> Bool {
        guard let normalized = LyricsDocument.normalizedLanguageIdentifier(identifier) else {
            return false
        }
        return languages.contains { $0.minimalIdentifier == normalized }
    }

    private static func defaultSupportedTargetLanguageIdentifier(
        from languages: [Locale.Language]
    ) -> String {
        if languageList(languages, containsIdentifier: AppState.systemLanguageIdentifier) {
            return AppState.systemLanguageIdentifier
        }
        return languages.first?.minimalIdentifier ?? AppState.systemLanguageIdentifier
    }

    nonisolated private static func loadSupportedTranslationLanguages() async -> [Locale.Language] {
        #if ENABLE_APPLE_TRANSLATION
        await Task.detached {
            await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages
        }.value
        #else
        []
        #endif
    }
}

#Preview {
    SettingsView(appState: AppState())
}

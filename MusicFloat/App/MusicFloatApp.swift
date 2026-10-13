import AppKit
import OSLog
import SwiftUI

@main
@MainActor
struct MusicFloatApp: App {
    private let appController = MusicFloatAppController()

    var body: some Scene {
        Settings {
            SettingsView(
                appState: appController.appState,
                onTranslationPreferencesChanged: appController.translationPreferencesChanged,
                onOverlayLayoutPreferencesChanged: appController.overlayLayoutPreferencesChanged,
                onTranslationPreparationCompleted: appController.retryTranslationAfterPreparation,
                onDiskMediaCachePreferenceChanged: appController.diskMediaCachePreferenceChanged,
                mediaCacheUsageText: appController.mediaCacheUsageText,
                clearMediaCache: appController.clearMediaCache
            )
        }
    }
}

@MainActor
private final class MusicFloatAppController {
    let appState: AppState

    private let launchesInDemoMode = CommandLine.arguments.contains("--demo")
    private let launchesInLiveMode = CommandLine.arguments.contains("--live")
    private let autoHideOverlayDelay: TimeInterval?
    private let mediaCache: any UserControllableMediaCache
    private var liveProviderPipelineController: ProviderPipelineController?
    private let panelController: FloatingPanelController
    private let playerController: PlayerController
    private let mockProviderPipelineController: ProviderPipelineController
    private let artworkProvider: AppleMusicArtworkProvider
    private let statusItemController: MenuBarStatusItemController
    private let settingsWindowController: SettingsWindowController
    private var systemLifecycleObserver: SystemLifecycleObserver?
    private var suspendedLifecycleState: SuspendedLifecycleState?
    private var liveVisibleLyricsRefreshTask: Task<Void, Never>?
    private static let liveVisibleLyricsRefreshInterval: TimeInterval = 0.5

    private struct SuspendedLifecycleState {
        let wasOverlayVisible: Bool
        let wasLiveModeRunning: Bool
        let wasMockPreviewRunning: Bool

        var shouldResumeLiveOverlay: Bool {
            wasOverlayVisible && wasLiveModeRunning
        }
    }

    init() {
        autoHideOverlayDelay = Self.autoHideOverlayDelay(from: CommandLine.arguments)
        appState = AppState()
        mediaCache = DiskBackedMediaCache(
            diskPersistenceEnabled: UserDefaults.standard.object(forKey: "diskMediaCacheEnabled") as? Bool ?? false
        )
        panelController = FloatingPanelController()

        let mockAdapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)
        playerController = PlayerController(bridge: mockAdapters.musicBridge)
        mockProviderPipelineController = ProviderPipelineController(
            lyricsProvider: mockAdapters.lyricsProvider,
            translationProvider: mockAdapters.translationProvider,
            mediaCache: mediaCache
        )
        artworkProvider = AppleMusicArtworkProvider(mediaCache: mediaCache)
        statusItemController = MenuBarStatusItemController()
        settingsWindowController = SettingsWindowController()

        statusItemController.install(
            appState: appState,
            commands: MenuBarStatusItemCommands(
                toggleOverlay: { [weak self] in self?.toggleOverlay() },
                toggleMockPreview: { [weak self] in self?.toggleMockPreview() },
                toggleLiveAppleMusic: { [weak self] in self?.toggleLiveAppleMusic() },
                nudgeLyricOffset: { [weak self] delta in self?.nudgeLyricOffset(by: delta) },
                resetLyricOffset: { [weak self] in self?.resetLyricOffset() },
                clearAllPerTrackOffsets: { [weak self] in self?.clearAllPerTrackOffsets() },
                resetMockPlayback: { [weak self] in self?.resetMockPlayback() },
                setOverlayContentState: { [weak self] state in self?.setOverlayContentState(state) },
                openSettings: { [weak self] in self?.openSettingsWindow() },
                quit: { [weak self] in self?.quit() }
            )
        )

        systemLifecycleObserver = SystemLifecycleObserver(
            onSuspend: { [weak self] event in
                self?.suspendForSystemLifecycle(event)
            },
            onResume: { [weak self] event in
                self?.resumeAfterSystemLifecycle(event)
            }
        )

        AppTelemetry.lifecycle.info("MusicFloat app initialized")

        applyStartupMode()
        scheduleAutoHideOverlayIfNeeded()
    }

    private func applyStartupMode() {
        if launchesInDemoMode {
            AppTelemetry.lifecycle.info("Demo mode requested - auto-starting overlay with mock preview in 500ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.toggleOverlay()
            }
            return
        }

        if launchesInLiveMode {
            AppTelemetry.lifecycle.info("Live mode requested - auto-starting Live Apple Music mode and overlay in 500ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.startLiveAppleMusic()
            }
            return
        }

        AppTelemetry.lifecycle.info("Default startup - menu bar idle")
    }

    private func scheduleAutoHideOverlayIfNeeded() {
        guard let autoHideOverlayDelay else { return }
        AppTelemetry.lifecycle.info("Auto-hide overlay scheduled delay=\(autoHideOverlayDelay, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(autoHideOverlayDelay * 1000))) { [weak self] in
            self?.hideOverlayIfVisible(reason: "autoHide")
        }
    }

    private func suspendForSystemLifecycle(_ event: SystemLifecycleObserver.Event) {
        guard suspendedLifecycleState == nil else {
            AppTelemetry.lifecycle.info(
                "System lifecycle suspend ignored while already suspended reason=\(event.telemetryName, privacy: .public)"
            )
            return
        }

        let snapshot = SuspendedLifecycleState(
            wasOverlayVisible: appState.isOverlayVisible,
            wasLiveModeRunning: appState.isLiveModeRunning,
            wasMockPreviewRunning: appState.isMockPreviewRunning
        )
        suspendedLifecycleState = snapshot

        AppTelemetry.lifecycle.notice(
            "System lifecycle suspend reason=\(event.telemetryName, privacy: .public) overlay=\(snapshot.wasOverlayVisible) live=\(snapshot.wasLiveModeRunning) mock=\(snapshot.wasMockPreviewRunning)"
        )

        stopLiveVisibleLyricsRefreshLoop()
        mockProviderPipelineController.stopHiddenWork(appState: appState)
        if appState.reduceHiddenMemoryUsage {
            releaseLiveProviderPipelineController()
        } else {
            liveProviderPipelineController?.stopHiddenWork(appState: appState)
        }
        playerController.stopMockPreview(appState: appState)
        playerController.stopLiveAppleMusic(appState: appState)
        artworkProvider.cancel(appState: appState) { [weak self] in
            self?.statusItemController.refreshStatusIcon()
        }
        appState.runtimeFeatureFlags = .architectureDefault

        if appState.isOverlayVisible {
            appState.isOverlayVisible = false
        }
        panelController.hide(releaseResources: appState.reduceHiddenMemoryUsage)
        statusItemController.refreshStatusIcon()
    }

    private func resumeAfterSystemLifecycle(_ event: SystemLifecycleObserver.Event) {
        guard let snapshot = suspendedLifecycleState else {
            AppTelemetry.lifecycle.info(
                "System lifecycle resume ignored without suspension reason=\(event.telemetryName, privacy: .public)"
            )
            return
        }
        suspendedLifecycleState = nil

        AppTelemetry.lifecycle.notice(
            "System lifecycle resume reason=\(event.telemetryName, privacy: .public) resumeLiveOverlay=\(snapshot.shouldResumeLiveOverlay)"
        )

        if snapshot.shouldResumeLiveOverlay {
            startLiveAppleMusic()
        } else {
            statusItemController.refreshStatusIcon()
        }
    }

    private func openSettingsWindow() {
        settingsWindowController.show(
            appState: appState,
            onTranslationPreferencesChanged: { [weak self] in self?.translationPreferencesChanged() },
            onOverlayLayoutPreferencesChanged: { [weak self] in self?.overlayLayoutPreferencesChanged() },
            onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
            onDiskMediaCachePreferenceChanged: { [weak self] isEnabled in
                await self?.diskMediaCachePreferenceChanged(isEnabled)
            },
            mediaCacheUsageText: { [weak self] in
                await self?.mediaCacheUsageText() ?? "Memory 0 KB - Disk Off"
            },
            clearMediaCache: { [weak self] in
                await self?.clearMediaCache()
            }
        )
    }

    private func nudgeLyricOffset(by delta: Double) {
        appState.nudgeLyricOffset(by: delta)
    }

    private func resetLyricOffset() {
        appState.resetLyricOffset()
    }

    private func clearAllPerTrackOffsets() {
        appState.clearAllPerTrackOffsets()
    }

    private func toggleOverlay() {
        let isShowing = !appState.isOverlayVisible
        AppTelemetry.menuBar.info("Toggle overlay requested visible=\(isShowing)")

        if isShowing {
            appState.isOverlayVisible = true
            if appState.isLiveModeRunning {
                let liveProviderPipelineController = getLiveProviderPipelineController()
                panelController.show(
                    appState: appState,
                    onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
                    playbackCommands: overlayPlaybackCommands
                )
                playerController.overlayVisibilityChanged(true, appState: appState)
                liveProviderPipelineController.resumeVisibleLiveOverlayContent(appState: appState)
                startLiveVisibleLyricsRefreshLoopIfNeeded(liveProviderPipelineController)
            } else {
                playerController.startMockPreview(appState: appState)
                activeProviderPipelineController.prepareOverlayContent(appState: appState)
                panelController.show(
                    appState: appState,
                    onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
                    playbackCommands: overlayPlaybackCommands
                )
                playerController.overlayVisibilityChanged(true, appState: appState)
                startLiveVisibleLyricsRefreshLoopIfNeeded()
            }
        } else {
            hideOverlayIfVisible(reason: "menu")
        }
    }

    private func hideOverlayIfVisible(reason: String) {
        guard appState.isOverlayVisible else { return }
        appState.isOverlayVisible = false
        AppTelemetry.windowing.info("Hide overlay requested reason=\(reason, privacy: .public)")
        stopLiveVisibleLyricsRefreshLoop()
        mockProviderPipelineController.stopHiddenWork(appState: appState)
        liveProviderPipelineController?.stopHiddenWork(appState: appState)
        playerController.stopMockPreview(appState: appState)
        playerController.overlayVisibilityChanged(false, appState: appState)
        panelController.hide(releaseResources: appState.reduceHiddenMemoryUsage)
    }

    private func toggleMockPreview() {
        if appState.isMockPreviewRunning {
            playerController.stopMockPreview(appState: appState)
        } else {
            playerController.startMockPreview(appState: appState)
        }
    }

    private func toggleLiveAppleMusic() {
        guard !launchesInDemoMode else {
            AppTelemetry.menuBar.notice("Live Apple Music toggle ignored in demo mode")
            statusItemController.refreshStatusIcon()
            return
        }

        if appState.isLiveModeRunning {
            stopLiveVisibleLyricsRefreshLoop()
            playerController.stopLiveAppleMusic(appState: appState)
            if appState.reduceHiddenMemoryUsage {
                releaseLiveProviderPipelineController()
            } else {
                liveProviderPipelineController?.stopHiddenWork(appState: appState)
            }
            artworkProvider.cancel(appState: appState) { [weak self] in
                self?.statusItemController.refreshStatusIcon()
            }
            appState.runtimeFeatureFlags = .architectureDefault
        } else {
            startLiveAppleMusic()
        }

        statusItemController.refreshStatusIcon()
    }

    private func startLiveAppleMusic() {
        guard !appState.isLiveModeRunning else { return }

        let liveProviderPipelineController = getLiveProviderPipelineController()
        appState.runtimeFeatureFlags = .liveAppleMusic
        showOverlayForLiveAppleMusicIfNeeded()
        playerController.startLiveAppleMusic(appState: appState) { [weak self, appState, artworkProvider, liveProviderPipelineController] track in
            artworkProvider.refreshArtwork(for: track, appState: appState) { [weak self] in
                self?.statusItemController.refreshStatusIcon()
            }
            guard track != nil else {
                AppTelemetry.performance.info("Live track payload empty; preserving current lyrics state")
                liveProviderPipelineController.cancelInFlightLoadPreservingState(appState: appState)
                return
            }
            guard appState.isOverlayVisible || appState.runtimeFeatureFlags.allowsHiddenProviderRefresh else {
                liveProviderPipelineController.cancelInFlightLoadPreservingState(appState: appState)
                AppTelemetry.performance.info("Live track refresh deferred while overlay hidden")
                return
            }
            liveProviderPipelineController.refreshOverlayContentForLiveTrack(appState: appState)
            self?.startLiveVisibleLyricsRefreshLoopIfNeeded(liveProviderPipelineController)
            self?.statusItemController.refreshStatusIcon()
        }
    }

    private func showOverlayForLiveAppleMusicIfNeeded() {
        guard !appState.isOverlayVisible else { return }
        appState.isOverlayVisible = true
        AppTelemetry.windowing.notice("Showing lyrics overlay for Live Apple Music")
        panelController.show(
            appState: appState,
            onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
            playbackCommands: overlayPlaybackCommands
        )
        playerController.overlayVisibilityChanged(true, appState: appState)
        startLiveVisibleLyricsRefreshLoopIfNeeded()
    }

    private func startLiveVisibleLyricsRefreshLoopIfNeeded(
        _ liveProviderPipelineController: ProviderPipelineController? = nil
    ) {
        guard liveVisibleLyricsRefreshTask == nil,
              appState.isLiveModeRunning,
              appState.isOverlayVisible else {
            return
        }
        let providerPipelineController = liveProviderPipelineController
            ?? self.liveProviderPipelineController
        guard let providerPipelineController else {
            return
        }

        liveVisibleLyricsRefreshTask = Task { @MainActor [weak self, weak providerPipelineController] in
            while !Task.isCancelled {
                guard let self, let providerPipelineController else {
                    return
                }
                providerPipelineController.refreshIntegratedVisibleLyrics(appState: self.appState)
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: Self.liveVisibleLyricsRefreshInterval))
            }
        }
        AppTelemetry.performance.info("Live visible-lyrics refresh loop started")
    }

    private func stopLiveVisibleLyricsRefreshLoop() {
        guard liveVisibleLyricsRefreshTask != nil else {
            return
        }
        liveVisibleLyricsRefreshTask?.cancel()
        liveVisibleLyricsRefreshTask = nil
        AppTelemetry.performance.info("Live visible-lyrics refresh loop stopped")
    }

    private var overlayPlaybackCommands: LyricsOverlayPlaybackCommands {
        LyricsOverlayPlaybackCommands(
            playPause: { [weak self] in self?.performPlaybackCommand(.playPause) },
            previousTrack: { [weak self] in self?.performPlaybackCommand(.previousTrack) },
            nextTrack: { [weak self] in self?.performPlaybackCommand(.nextTrack) },
            setVolume: { [weak self] volume in self?.performPlaybackCommand(.setVolume(volume)) },
            seek: { [weak self] position in self?.performPlaybackCommand(.seek(position)) }
        )
    }

    private func performPlaybackCommand(_ command: MusicPlaybackCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await playerController.performLivePlaybackCommand(
                command,
                appState: appState,
                isDemoMode: launchesInDemoMode
            )
            statusItemController.refreshStatusIcon()
        }
    }

    private func resetMockPlayback() {
        appState.resetMockPlayback()
        statusItemController.refreshStatusIcon()
    }

    private func setOverlayContentState(_ state: OverlayContentState) {
        appState.setOverlayContentState(state)
    }

    func translationPreferencesChanged() {
        guard appState.isOverlayVisible else { return }
        activeProviderPipelineController.refreshTranslation(appState: appState)
    }

    func overlayLayoutPreferencesChanged() {
        panelController.updateLayout(appState: appState)
    }

    func diskMediaCachePreferenceChanged(_ isEnabled: Bool) async {
        await mediaCache.setDiskPersistenceEnabled(isEnabled)
    }

    func mediaCacheUsageText() async -> String {
        await mediaCache.usageSummary().displayText
    }

    func clearMediaCache() async {
        await mediaCache.removeAll()
        AppTelemetry.settings.info("Media cache cleared")
    }

    func retryTranslationAfterPreparation() {
        guard appState.isOverlayVisible,
              appState.playerState.track != nil else {
            return
        }
        activeProviderPipelineController.refreshTranslation(appState: appState)
    }

    private func quit() {
        AppTelemetry.lifecycle.info("Quit requested from menu bar")
        stopLiveVisibleLyricsRefreshLoop()
        mockProviderPipelineController.stopHiddenWork(appState: appState)
        liveProviderPipelineController?.stopHiddenWork(appState: appState)
        playerController.stopMockPreview(appState: appState)
        playerController.stopLiveAppleMusic(appState: appState)
        artworkProvider.cancel(appState: appState) { [weak self] in
            self?.statusItemController.refreshStatusIcon()
        }
        panelController.hide()
        NSApplication.shared.terminate(nil)
    }

    private var activeProviderPipelineController: ProviderPipelineController {
        appState.isLiveModeRunning ? getLiveProviderPipelineController() : mockProviderPipelineController
    }

    private func getLiveProviderPipelineController() -> ProviderPipelineController {
        if let liveProviderPipelineController { return liveProviderPipelineController }
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .liveAppleMusic)
        let controller = ProviderPipelineController(
            lyricsProvider: adapters.lyricsProvider,
            translationProvider: adapters.translationProvider,
            mediaCache: mediaCache
        )
        liveProviderPipelineController = controller
        AppTelemetry.lifecycle.info("Live provider pipeline initialized")
        return controller
    }

    private func releaseLiveProviderPipelineController() {
        guard let liveProviderPipelineController else { return }
        liveProviderPipelineController.stopHiddenWork(appState: appState)
        self.liveProviderPipelineController = nil
        AppTelemetry.lifecycle.info("Live provider pipeline released")
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0.1, interval) * 1_000_000_000)
    }

    private static func autoHideOverlayDelay(from arguments: [String]) -> TimeInterval? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == "--hide-after" {
                let valueIndex = arguments.index(after: index)
                guard arguments.indices.contains(valueIndex) else { return nil }
                return duration(from: arguments[valueIndex])
            }
            if argument.hasPrefix("--hide-after=") {
                return duration(from: String(argument.dropFirst("--hide-after=".count)))
            }
        }
        return nil
    }

    private static func duration(from rawValue: String) -> TimeInterval? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let suffixes: [(String, Double)] = [
            ("ms", 0.001),
            ("s", 1),
            ("m", 60)
        ]
        for (suffix, multiplier) in suffixes where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count)
            guard let value = TimeInterval(String(number)), value > 0 else { return nil }
            return value * multiplier
        }
        guard let value = TimeInterval(trimmed), value > 0 else { return nil }
        return value
    }
}

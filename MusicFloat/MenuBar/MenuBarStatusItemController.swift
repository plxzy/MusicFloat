import AppKit
import OSLog

@MainActor
struct MenuBarStatusItemCommands {
    let toggleOverlay: () -> Void
    let toggleOverlayLock: () -> Void
    let toggleEdgeSnapping: () -> Void
    let toggleMockPreview: () -> Void
    let toggleLiveAppleMusic: () -> Void
    let nudgeLyricOffset: (Double) -> Void
    let resetLyricOffset: () -> Void
    let clearAllPerTrackOffsets: () -> Void
    let resetMockPlayback: () -> Void
    let setOverlayContentState: (OverlayContentState) -> Void
    let openSettings: () -> Void
    let quit: () -> Void
}

@MainActor
final class MenuBarStatusItemController: NSObject, NSMenuDelegate {
    private static let maxTrackMenuTitleLength = 72

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var appState: AppState?
    private var commands: MenuBarStatusItemCommands?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
    }

    func install(appState: AppState, commands: MenuBarStatusItemCommands) {
        self.appState = appState
        self.commands = commands
        refreshStatusIcon()
        AppTelemetry.menuBar.info("AppKit status item installed")
    }

    func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let artwork = appState?.nowPlayingArtwork
        button.image = Self.statusImage(for: artwork)
        button.toolTip = appState?.playerState.track?.displayTitle ?? "MusicFloat"
        statusItem.length = NSStatusItem.squareLength
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let appState else { return }
        menu.removeAllItems()

        menu.addItem(actionItem(
            title: appState.isOverlayVisible ? "Hide Lyrics" : "Show Lyrics",
            action: #selector(toggleOverlay),
            keyEquivalent: "l"
        ))

        let lockItem = actionItem(title: "Lock Overlay Position", action: #selector(toggleOverlayLock))
        lockItem.state = appState.isOverlayLocked ? .on : .off
        menu.addItem(lockItem)
        let snapItem = actionItem(title: "Snap Overlay to Screen Edges", action: #selector(toggleEdgeSnapping))
        snapItem.state = appState.snapsOverlayToEdges ? .on : .off
        menu.addItem(snapItem)

        menu.addItem(actionItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(.separator())
        menu.addItem(statusItem(title: appState.playerState.statusLine))
        menu.addItem(statusItem(title: "Providers: \(appState.providerRuntimeState.displayName)"))
        menu.addItem(statusItem(title: "Translation: \(appState.translationRuntimeState.displayName)"))
        let trackTitle = appState.playerState.track?.displayTitle ?? "No current track"
        menu.addItem(statusItem(title: Self.truncatedTrackTitle(trackTitle), toolTip: trackTitle))

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: appState.isLiveModeRunning ? "Stop Listening to Apple Music" : "Listen to Apple Music",
            action: #selector(toggleLiveAppleMusic)
        ))

        let offsetItem = NSMenuItem(title: "Lyric Offset (\(offsetMenuLabel(for: appState)))", action: nil, keyEquivalent: "")
        let offsetMenu = NSMenu()
        offsetMenu.autoenablesItems = false
        offsetMenu.addItem(actionItem(
            title: "Nudge Earlier -0.5s",
            action: #selector(nudgeLyricOffset),
            keyEquivalent: "[",
            representedObject: -0.5
        ))
        offsetMenu.addItem(actionItem(
            title: "Nudge Later +0.5s",
            action: #selector(nudgeLyricOffset),
            keyEquivalent: "]",
            representedObject: 0.5
        ))
        offsetMenu.addItem(actionItem(
            title: "Nudge Earlier -2s",
            action: #selector(nudgeLyricOffset),
            representedObject: -2.0
        ))
        offsetMenu.addItem(actionItem(
            title: "Nudge Later +2s",
            action: #selector(nudgeLyricOffset),
            representedObject: 2.0
        ))
        offsetMenu.addItem(.separator())
        offsetMenu.addItem(actionItem(
            title: resetLabel(for: appState),
            action: #selector(resetLyricOffset)
        ))
        let clearOffsetsItem = actionItem(
            title: "Clear All Per-Track Offsets (\(appState.perTrackOffsets.count))",
            action: #selector(clearAllPerTrackOffsets)
        )
        clearOffsetsItem.isEnabled = !appState.perTrackOffsets.isEmpty
        offsetMenu.addItem(clearOffsetsItem)
        offsetItem.submenu = offsetMenu
        menu.addItem(offsetItem)

        menu.addItem(actionItem(
            title: appState.isMockPreviewRunning ? "Stop Mock Preview" : "Start Mock Preview",
            action: #selector(toggleMockPreview)
        ))

        menu.addItem(actionItem(
            title: "Reset Mock Time",
            action: #selector(resetMockPlayback)
        ))

        let mockStateItem = NSMenuItem(title: "Mock Overlay State", action: nil, keyEquivalent: "")
        let mockStateMenu = NSMenu()
        mockStateMenu.autoenablesItems = false
        mockStateMenu.addItem(actionItem(
            title: "Ready",
            action: #selector(setOverlayContentState),
            representedObject: "ready"
        ))
        mockStateMenu.addItem(actionItem(
            title: "Loading",
            action: #selector(setOverlayContentState),
            representedObject: "loading"
        ))
        mockStateMenu.addItem(actionItem(
            title: "Unavailable",
            action: #selector(setOverlayContentState),
            representedObject: "unavailable"
        ))
        mockStateMenu.addItem(actionItem(
            title: "Error",
            action: #selector(setOverlayContentState),
            representedObject: "error"
        ))
        mockStateItem.submenu = mockStateMenu
        menu.addItem(mockStateItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "Quit MusicFloat",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
    }

    private func actionItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = representedObject
        item.isEnabled = true
        return item
    }

    private func statusItem(title: String, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = toolTip
        return item
    }

    private static func truncatedTrackTitle(_ title: String) -> String {
        guard title.count > maxTrackMenuTitleLength else { return title }
        return "\(title.prefix(maxTrackMenuTitleLength - 3))..."
    }

    private func offsetMenuLabel(for appState: AppState) -> String {
        let value = formattedOffset(appState.effectiveLyricOffsetSeconds)
        switch appState.lyricOffsetScope {
        case .perTrack:
            return "\(value), this track"
        case .global:
            return "\(value), global"
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let roundedTenths = Int((seconds * 10).rounded())
        let sign = roundedTenths < 0 ? "-" : "+"
        let magnitude = abs(roundedTenths)
        return "\(sign)\(magnitude / 10).\(magnitude % 10)s"
    }

    private func resetLabel(for appState: AppState) -> String {
        switch appState.lyricOffsetScope {
        case .perTrack:
            return "Reset This Track (Use Global)"
        case .global:
            return "Reset Global to 0"
        }
    }

    @objc private func toggleOverlay() {
        commands?.toggleOverlay()
    }

    @objc private func toggleOverlayLock() { commands?.toggleOverlayLock() }

    @objc private func toggleEdgeSnapping() { commands?.toggleEdgeSnapping() }

    @objc private func toggleMockPreview() {
        commands?.toggleMockPreview()
    }

    @objc private func toggleLiveAppleMusic() {
        AppTelemetry.menuBar.notice("Toggle live Apple Music requested from AppKit status menu")
        commands?.toggleLiveAppleMusic()
    }

    @objc private func nudgeLyricOffset(_ sender: NSMenuItem) {
        let delta = (sender.representedObject as? NSNumber)?.doubleValue
            ?? sender.representedObject as? Double
            ?? 0
        commands?.nudgeLyricOffset(delta)
    }

    @objc private func resetLyricOffset() {
        commands?.resetLyricOffset()
    }

    @objc private func clearAllPerTrackOffsets() {
        commands?.clearAllPerTrackOffsets()
    }

    @objc private func resetMockPlayback() {
        commands?.resetMockPlayback()
        refreshStatusIcon()
    }

    @objc private func setOverlayContentState(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "ready":
            commands?.setOverlayContentState(.ready)
        case "loading":
            commands?.setOverlayContentState(.loading)
        case "unavailable":
            commands?.setOverlayContentState(.unavailable)
        case "error":
            commands?.setOverlayContentState(.failed("Mock provider failed before real integrations were enabled"))
        default:
            break
        }
    }

    @objc private func openSettings() {
        commands?.openSettings()
    }

    @objc private func quit() {
        commands?.quit()
    }

    private static func statusImage(for artwork: NSImage?) -> NSImage {
        if let artwork, let image = renderedArtworkIcon(from: artwork) {
            return image
        }

        let fallback = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicFloat")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    private static func renderedArtworkIcon(from artwork: NSImage) -> NSImage? {
        let sourceSize = artwork.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let targetSize = NSSize(width: 18, height: 18)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        let sourceSide = min(sourceSize.width, sourceSize.height)
        let sourceRect = NSRect(
            x: (sourceSize.width - sourceSide) / 2,
            y: (sourceSize.height - sourceSide) / 2,
            width: sourceSide,
            height: sourceSide
        )

        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let clipPath = NSBezierPath(roundedRect: targetRect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        clipPath.addClip()
        artwork.draw(
            in: targetRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        clipPath.lineWidth = 1
        clipPath.stroke()
        rendered.unlockFocus()
        rendered.isTemplate = false
        return rendered
    }
}

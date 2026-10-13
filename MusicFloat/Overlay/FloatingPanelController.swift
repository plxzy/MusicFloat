import AppKit
import OSLog
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let userDefaults: UserDefaults
    private var isObservingScreenChanges = false
    private var isAdjustingFrame = false
    private var pendingMove: Task<Void, Never>?
    private weak var appState: AppState?

    private enum DefaultsKey {
        static let originX = "floatingPanelOriginX"
        static let originY = "floatingPanelOriginY"
        static let placement = "floatingPanelPlacementV2"
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        super.init()
    }

    override convenience init() {
        self.init(userDefaults: .standard)
    }

    func show(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void = {},
        playbackCommands: LyricsOverlayPlaybackCommands = .disabled
    ) {
        AppTelemetry.measure("FloatingPanelShow") {
            self.appState = appState
            let didCreatePanel = panel == nil
            let panel = panel ?? makePanel(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands
            )
            self.panel = panel
            installScreenChangeObserverIfNeeded()
            if !didCreatePanel {
                updateContent(
                    appState: appState,
                    onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                    playbackCommands: playbackCommands,
                    in: panel
                )
            }
            updateInteraction(appState: appState)
            applySize(appState: appState, to: panel)

            AppTelemetry.windowing.info("Show floating panel created=\(didCreatePanel)")
            panel.orderFrontRegardless()
        }
    }

    func hide(releaseResources: Bool = false) {
        AppTelemetry.measure("FloatingPanelHide") {
            AppTelemetry.windowing.info(
                "Hide floating panel hasPanel=\(self.panel != nil) releaseResources=\(releaseResources)"
            )
            if let panel { persistPlacement(panel.frame, userInitiated: pendingMove != nil) }
            pendingMove?.cancel()
            pendingMove = nil
            panel?.orderOut(nil)

            if releaseResources {
                panel?.contentView = nil
                panel = nil
            }
        }
    }

    func updateLayout(appState: AppState) {
        guard panel != nil else { return }
        // Defer to the next runloop tick: callers may invoke this from inside a
        // SwiftUI layout pass (e.g. .onChange of panelHeight), and resizing the
        // panel with display:true synchronously runs -layoutSubtreeIfNeeded,
        // which AppKit rejects when the view is already being laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            AppTelemetry.measure("FloatingPanelUpdateLayout") {
                self.applySize(appState: appState, to: panel)
            }
        }
    }

    private func applySize(appState: AppState, to panel: NSPanel) {
        let panelSize = panelSize(for: appState)
        let frame = FloatingPanelPlacement.framePreservingTopCenter(
            currentFrame: panel.frame,
            size: panelSize
        )
        setFrame(clamped(frame), for: panel)
        persistPlacement(panel.frame)
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        guard let visibleFrame = screen(for: frame)?.visibleFrame else {
            return frame
        }

        return FloatingPanelPlacement.clamped(frame, to: visibleFrame)
    }

    private func screen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
    }

    private func updateContent(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void,
        playbackCommands: LyricsOverlayPlaybackCommands,
        in panel: NSPanel
    ) {
        guard let hostingView = panel.contentView as? NSHostingView<LyricsOverlayView> else { return }
        hostingView.rootView = LyricsOverlayView(
            appState: appState,
            onTranslationPreparationCompleted: onTranslationPreparationCompleted,
            onPresentationLayoutChanged: { [weak self] in
                self?.updateLayout(appState: appState)
            },
            playbackCommands: playbackCommands
        )
    }

    private func makePanel(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void,
        playbackCommands: LyricsOverlayPlaybackCommands
    ) -> NSPanel {
        AppTelemetry.measure("FloatingPanelCreate") {
            AppTelemetry.windowing.info("Create floating panel")
            let panelSize = panelSize(for: appState)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.delegate = self
            panel.isMovableByWindowBackground = !appState.isOverlayLocked
            panel.isMovable = !appState.isOverlayLocked
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true

            let hostingView = NSHostingView(rootView: LyricsOverlayView(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                onPresentationLayoutChanged: { [weak self] in
                    self?.updateLayout(appState: appState)
                },
                playbackCommands: playbackCommands
            ))
            // The controller owns the panel frame (see applySize). Without this,
            // NSHostingView pushes SwiftUI's ideal size into window constraints
            // and silently overrides the expanded/collapsed heights.
            hostingView.sizingOptions = []
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView

            panel.setFrame(initialFrame(for: panelSize), display: false)

            return panel
        }
    }

    private func panelSize(for appState: AppState) -> NSSize {
        NSSize(
            width: appState.overlayWidthPreset.width,
            height: LyricsOverlayLayout.panelHeight(
                for: appState.overlaySnapshot,
                isLyricsExpanded: appState.isLyricsOverlayExpanded
            )
        )
    }

    private func initialFrame(for size: NSSize) -> NSRect {
        if let frame = restoredFrame(for: size) { return frame }
        if let restoredOrigin = restoredOrigin() {
            return clamped(NSRect(origin: restoredOrigin, size: size))
        }

        let screen = activeScreen() ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return FloatingPanelPlacement.defaultFrame(size: size, visibleFrame: visibleFrame)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    private func restoredOrigin() -> NSPoint? {
        guard userDefaults.object(forKey: DefaultsKey.originX) != nil,
              userDefaults.object(forKey: DefaultsKey.originY) != nil else {
            return nil
        }
        return NSPoint(
            x: userDefaults.double(forKey: DefaultsKey.originX),
            y: userDefaults.double(forKey: DefaultsKey.originY)
        )
    }

    private static func displayIdentifier(_ screen: NSScreen) -> String {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let serial = CGDisplaySerialNumber(displayID)
        // Some displays do not report a serial. Their system display ID is a
        // best-effort fallback, rather than treating identical models as one.
        if serial == 0 && CGDisplayIsBuiltin(displayID) == 0 { return "display-\(displayID)" }
        return "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(serial)"
    }

    private var savedPosition: FloatingPanelPlacement.SavedPosition? {
        userDefaults.data(forKey: DefaultsKey.placement).flatMap {
            try? JSONDecoder().decode(FloatingPanelPlacement.SavedPosition.self, from: $0)
        }
    }

    private func restoredFrame(for size: NSSize) -> NSRect? {
        guard let placement = savedPosition else { return nil }
        let displays = NSScreen.screens.map {
            FloatingPanelPlacement.Display(id: Self.displayIdentifier($0), visibleFrame: $0.visibleFrame)
        }
        return FloatingPanelPlacement.restoredFrame(
            placement, size: size, displays: displays,
            fallbackDisplayID: (activeScreen() ?? NSScreen.main).map(Self.displayIdentifier)
        )
    }

    private func persistPlacement(_ frame: NSRect, userInitiated: Bool = false) {
        guard let screen = screen(for: frame) else { return }
        let placement = FloatingPanelPlacement.savedPosition(
            frame, display: .init(id: Self.displayIdentifier(screen), visibleFrame: screen.visibleFrame),
            previous: savedPosition, connectedDisplayIDs: NSScreen.screens.map(Self.displayIdentifier),
            userInitiated: userInitiated
        )
        if let data = try? JSONEncoder().encode(placement) {
            userDefaults.set(data, forKey: DefaultsKey.placement)
        }
    }

    func updateInteraction(appState: AppState) {
        panel?.isMovable = !appState.isOverlayLocked
        panel?.isMovableByWindowBackground = !appState.isOverlayLocked
        if appState.isOverlayLocked {
            if pendingMove != nil, let panel { persistPlacement(panel.frame, userInitiated: true) }
            pendingMove?.cancel()
            pendingMove = nil
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, notification.object as? NSPanel === panel else { return }
        pendingMove?.cancel()
        pendingMove = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.finishPanelMove()
        }
    }

    private func finishPanelMove() {
        pendingMove = nil
        guard let panel else { return }
        // Wait for release so snapping never fights an active cross-screen drag.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            return
        }
        if appState?.snapsOverlayToEdges == true,
           appState?.isOverlayLocked == false,
           let visibleFrame = screen(for: panel.frame)?.visibleFrame {
            setFrame(FloatingPanelPlacement.snapped(panel.frame, to: visibleFrame), for: panel)
        }
        persistPlacement(panel.frame, userInitiated: true)
    }

    private func setFrame(_ frame: NSRect, for panel: NSPanel) {
        isAdjustingFrame = true
        defer { isAdjustingFrame = false }
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func installScreenChangeObserverIfNeeded() {
        guard !isObservingScreenChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        isObservingScreenChanges = true
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        // Same recursion guard as updateLayout: notifications can deliver while
        // AppKit is mid-layout (space switches, display reconfigure), and
        // setFrame(display: true) would synchronously call layoutSubtreeIfNeeded.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.pendingMove?.cancel()
            self.pendingMove = nil
            let size = self.appState.map(self.panelSize) ?? panel.frame.size
            let frame = self.restoredFrame(for: size)
                ?? self.clamped(NSRect(origin: panel.frame.origin, size: size))
            self.setFrame(frame, for: panel)
            AppTelemetry.windowing.info("Floating panel clamped after screen change")
        }
    }
}

nonisolated enum FloatingPanelPlacement {
    struct Display {
        let id: String
        let visibleFrame: NSRect
    }

    struct SavedPosition: Codable {
        let displayID: String
        let horizontalFraction: Double
        let verticalFraction: Double
    }

    static func savedPosition(
        _ frame: NSRect, display: Display, previous: SavedPosition? = nil,
        connectedDisplayIDs: [String] = [], userInitiated: Bool = true
    ) -> SavedPosition {
        if !userInitiated, let previous, !connectedDisplayIDs.contains(previous.displayID) { return previous }
        let bounds = display.visibleFrame
        return SavedPosition(
            displayID: display.id,
            horizontalFraction: min(1, max(0, (frame.minX - bounds.minX) / max(1, bounds.width - frame.width))),
            verticalFraction: min(1, max(0, (frame.minY - bounds.minY) / max(1, bounds.height - frame.height)))
        )
    }

    static func restoredFrame(
        _ position: SavedPosition, size: NSSize, displays: [Display], fallbackDisplayID: String?
    ) -> NSRect? {
        guard position.horizontalFraction.isFinite, position.verticalFraction.isFinite,
              let display = displays.first(where: { $0.id == position.displayID })
                ?? displays.first(where: { $0.id == fallbackDisplayID }) ?? displays.first else { return nil }
        let bounds = display.visibleFrame
        return clamped(NSRect(
            x: bounds.minX + min(1, max(0, position.horizontalFraction)) * max(0, bounds.width - size.width),
            y: bounds.minY + min(1, max(0, position.verticalFraction)) * max(0, bounds.height - size.height),
            width: size.width, height: size.height
        ), to: bounds)
    }

    static func snapped(_ frame: NSRect, to visibleFrame: NSRect, padding: CGFloat = 12, threshold: CGFloat = 18) -> NSRect {
        let inset = min(max(0, padding), max(0, (visibleFrame.width - frame.width) / 2), max(0, (visibleFrame.height - frame.height) / 2))
        let bounds = visibleFrame.insetBy(dx: inset, dy: inset)
        var result = clamped(frame, to: visibleFrame)
        func snap(_ current: CGFloat, between lower: CGFloat, and upper: CGFloat) -> CGFloat {
            let nearest = abs(current - lower) <= abs(current - upper) ? lower : upper
            return abs(current - nearest) <= threshold ? nearest : current
        }
        result.origin.x = snap(result.minX, between: bounds.minX, and: bounds.maxX - result.width)
        result.origin.y = snap(result.minY, between: bounds.minY, and: bounds.maxY - result.height)
        return result
    }

    static func defaultFrame(
        size: NSSize,
        visibleFrame: NSRect,
        topInset: CGFloat = 88
    ) -> NSRect {
        clamped(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - topInset,
                width: size.width,
                height: size.height
            ),
            to: visibleFrame
        )
    }

    static func framePreservingTopCenter(currentFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var clamped = frame
        clamped.size.width = min(clamped.width, visibleFrame.width)
        clamped.size.height = min(clamped.height, visibleFrame.height)
        clamped.origin.x = min(
            max(clamped.origin.x, visibleFrame.minX),
            visibleFrame.maxX - clamped.width
        )
        clamped.origin.y = min(
            max(clamped.origin.y, visibleFrame.minY),
            visibleFrame.maxY - clamped.height
        )
        return clamped
    }
}

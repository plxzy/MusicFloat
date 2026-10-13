import AppKit
import OSLog
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject {
    private var panel: NSPanel?
    private let userDefaults: UserDefaults
    private var isObservingScreenChanges = false

    private enum DefaultsKey {
        static let originX = "floatingPanelOriginX"
        static let originY = "floatingPanelOriginY"
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
            let didCreatePanel = panel == nil
            let panel = panel ?? makePanel(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands
            )
            self.panel = panel
            installScreenChangeObserverIfNeeded()
            updateContent(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands,
                in: panel
            )
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
            if let panel {
                persistFrameOrigin(panel.frame)
            }
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
        panel.setFrame(clamped(frame), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: panel.frame.size)
        persistFrameOrigin(panel.frame)
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        guard let visibleFrame = screen(for: frame)?.visibleFrame else {
            return frame
        }

        return FloatingPanelPlacement.clamped(frame, to: visibleFrame)
    }

    private func screen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.visibleFrame.contains(center) }
            ?? NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
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
            panel.isMovableByWindowBackground = true
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

    private func persistFrameOrigin(_ frame: NSRect) {
        userDefaults.set(Double(frame.origin.x), forKey: DefaultsKey.originX)
        userDefaults.set(Double(frame.origin.y), forKey: DefaultsKey.originY)
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
            let frame = self.clamped(panel.frame)
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
            self.persistFrameOrigin(frame)
            AppTelemetry.windowing.info("Floating panel clamped after screen change")
        }
    }
}

extension FloatingPanelController {
    nonisolated static func testPlacementDefaultFrame(
        size: NSSize,
        visibleFrame: NSRect,
        topInset: CGFloat
    ) -> NSRect {
        FloatingPanelPlacement.defaultFrame(
            size: size,
            visibleFrame: visibleFrame,
            topInset: topInset
        )
    }

    nonisolated static func testPlacementClamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        FloatingPanelPlacement.clamped(frame, to: visibleFrame)
    }

    nonisolated static func testPlacementFramePreservingTopCenter(
        currentFrame: NSRect,
        size: NSSize
    ) -> NSRect {
        FloatingPanelPlacement.framePreservingTopCenter(currentFrame: currentFrame, size: size)
    }
}

private enum FloatingPanelPlacement {
    nonisolated static func defaultFrame(
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

    nonisolated static func framePreservingTopCenter(currentFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    nonisolated static func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
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

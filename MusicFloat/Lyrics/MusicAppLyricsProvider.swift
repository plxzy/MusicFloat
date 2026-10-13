import Foundation
import AppKit
import ApplicationServices
import OSLog

/// Pulls lyrics from the Music app's current track via integrated local paths.
///
/// AppleScript can expose unsynced library metadata. Apple Music catalog
/// streams usually keep that field empty even when the Music UI is showing
/// synced lyrics, so this provider can also read the visible lyrics panel via
/// Accessibility before external providers are allowed to run.
@MainActor
enum MusicAppLyricsProvider {
    private(set) static var requiresAccessibilityPermission = false
    private(set) static var shouldRetryVisibleLyrics = false
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    /// Keep expensive AX attribute dumps opt-in. Dumping several lyric buttons
    /// on the main actor is useful during UI forensics, but it can make the
    /// live button feel frozen on real Music.app trees.
    private static let axDumpEnabled = false
    private static var pendingAXDump = axDumpEnabled
    private static let axTraversalNodeLimit = 700
    private static let axTraversalTimeLimit: TimeInterval = 0.08

    private static let script = """
    try
        launch application id "com.apple.Music"
        tell application id "com.apple.Music"
            if it is not running then return "__NOT_RUNNING__"
            set pState to (player state as string)
            if pState is "playing" or pState is "paused" then
                try
                    set lyricsText to lyrics of current track
                    if lyricsText is missing value then return "__EMPTY__"
                    if lyricsText is "" then return "__EMPTY__"
                    return "__LYRICS__" & linefeed & lyricsText
                on error errMsg number errNo
                    return "__ERROR__||" & errNo & "||" & errMsg
                end try
            else
                return "__STATE__||" & pState
            end if
        end tell
    on error errMsg number errNo
        return "__SCRIPT_ERROR__||" & errNo & "||" & errMsg
    end try
    """

    static func fetchCurrentTrackLyrics() async -> LyricsDocument? {
        requiresAccessibilityPermission = false
        shouldRetryVisibleLyrics = false

        guard AppleMusicEventListener.isMusicAppRunning else {
            AppTelemetry.performance.info("Music.app AppleScript lyrics skipped because Music is not running")
            return nil
        }
        guard let raw = await (MusicScriptingBridge.isEnabled
            ? MusicScriptingBridge.lyricsString()
            : AppleScriptRunner.runStringOffMain(script)) else {
            AppTelemetry.performance.info("Music.app AppleScript lyrics returned no script result")
            return nil
        }
        guard raw.hasPrefix("__LYRICS__\n") else {
            logEmptyResult(raw)
            markVisibleLyricsFallbackNeeded(for: raw)
            return nil
        }
        let trimmed = raw
            .dropFirst("__LYRICS__\n".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return LyricsParser.parsePlain(trimmed, source: .musicApp)
    }

    private static func markVisibleLyricsFallbackNeeded(for raw: String) {
        guard raw == "__EMPTY__" || raw.hasPrefix("__ERROR__||") else {
            return
        }
        if hasAccessibilityTrust(prompt: false) {
            requiresAccessibilityPermission = false
            shouldRetryVisibleLyrics = true
        } else {
            requiresAccessibilityPermission = true
            shouldRetryVisibleLyrics = false
        }
    }

    /// Returns just the active visible lyric line text, without wrapping it
    /// in a `LyricsDocument`. Used by the calibration pass to align an LRCLIB
    /// timed document against Music.app's ground truth.
    static func fetchCurrentVisibleLyricsLineText() -> String? {
        fetchCurrentVisibleLyricsLineDocument()?.lines.first?.text
    }

    /// Apple Music catalog streams often show synced lyrics in Music's UI while
    /// AppleScript's `lyrics of current track` metadata remains empty. When the
    /// lyrics panel is visible, read the current top lyric line from Music's
    /// accessibility tree as an integrated source before falling back to LRCLIB.
    static func fetchCurrentVisibleLyricsLineDocument(promptForAccessibility: Bool = false) -> LyricsDocument? {
        AppTelemetry.measure("MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument") {
            fetchCurrentVisibleLyricsLineDocumentImpl(promptForAccessibility: promptForAccessibility)
        }
    }

    private static func fetchCurrentVisibleLyricsLineDocumentImpl(promptForAccessibility: Bool = false) -> LyricsDocument? {
        guard hasAccessibilityTrust(prompt: promptForAccessibility) else {
            requiresAccessibilityPermission = true
            shouldRetryVisibleLyrics = false
            return nil
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .first(where: { !$0.isTerminated }) else {
            return nil
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [VisibleLyricLine] = []
        var containerFrame: CGRect? = nil
        var traversalBudget = AXTraversalBudget(
            nodeLimit: axTraversalNodeLimit,
            timeLimit: axTraversalTimeLimit
        )
        collectVisibleLyricLines(
            from: root,
            inLyricsContainer: false,
            containerFrame: &containerFrame,
            into: &lines,
            depth: 0,
            budget: &traversalBudget
        )

        let viable = lines.filter {
            $0.size.height > 0 && !$0.text.hasPrefix("Written By:")
        }
        guard !viable.isEmpty else {
            shouldRetryVisibleLyrics = !traversalBudget.isExhausted
            AppTelemetry.performance.info(
                "Music.app AX lyrics panel had no visible lyric line limited=\(traversalBudget.isExhausted, privacy: .public) visited=\(traversalBudget.visitedNodes, privacy: .public) elapsed=\(traversalBudget.elapsed, privacy: .public)"
            )
            return nil
        }

        let current = pickActiveLine(from: viable, containerFrame: containerFrame)
            ?? viable.min(by: { $0.position.y < $1.position.y })!

        shouldRetryVisibleLyrics = false
        AppTelemetry.performance.info(
            "Lyrics hit musicAppAX active=\(current.isSelected, privacy: .public) h=\(current.size.height) font=\(current.fontSize ?? -1) y=\(current.position.y) containerMidY=\(containerFrame?.midY ?? -1, privacy: .public) cand=\(viable.count)"
        )
        return LyricsDocument(
            source: .musicAppUI,
            lines: [LyricLine(id: 0, text: current.text, startTime: nil)],
            isTimed: false
        )
    }

    /// Returns the actively highlighted lyric line, if one can be identified.
    ///
    /// Music.app renders the active line larger than its neighbors and (on
    /// recent builds) marks it via `AXSelected`. Detect either, in that order,
    /// to avoid the "topmost visible button" heuristic which is wrong as soon
    /// as the panel hasn't auto-scrolled yet.
    private static func pickActiveLine(
        from candidates: [VisibleLyricLine],
        containerFrame: CGRect?
    ) -> VisibleLyricLine? {
        // Restrict the pool to buttons whose vertical midpoint sits inside
        // the lyrics scroll container. Music keeps inactive lines rendered
        // off-viewport for prefetch, and some of those are taller than the
        // active line (long wrapped lyrics) — including them in the height
        // ranking causes the picker to lock onto an invisible line. Only
        // candidates the user can actually see should be considered.
        let visiblePool: [VisibleLyricLine]
        if let frame = containerFrame, frame.height > 0 {
            let inside = candidates.filter {
                let midY = $0.position.y + $0.size.height / 2
                return midY >= frame.minY && midY <= frame.maxY
            }
            visiblePool = inside.isEmpty ? candidates : inside
        } else {
            visiblePool = candidates
        }
        let candidates = visiblePool

        if let selected = candidates.first(where: { $0.isSelected }) {
            return selected
        }
        // Font-size on inner StaticText (kept opportunistically — Music.app
        // doesn't expose AXFont today, but if a future build does, font is a
        // cleaner signal than button height).
        let fontSizes = candidates.compactMap(\.fontSize)
        if fontSizes.count >= 2 {
            let sorted = fontSizes.sorted()
            let median = sorted[sorted.count / 2]
            if let top = candidates
                .filter({ $0.fontSize != nil })
                .max(by: { ($0.fontSize ?? 0) < ($1.fontSize ?? 0) }),
               let topFont = top.fontSize,
               median > 0,
               topFont >= median * 1.10 {
                return top
            }
        }
        // Button-height: confirmed via AXDUMP on current Music.app that the
        // active line's button frame is ~1.33× the height of inactive lines
        // (the button auto-resizes for the larger rendered font). This is the
        // primary working signal. Require a clear margin (1.20×) over the
        // median so a uniform-height panel doesn't false-pick. When multiple
        // candidates clear the threshold (e.g. a wrapped 2-line inactive
        // lyric ties the active line's height), break the tie by proximity
        // to the container's vertical center.
        let heights = candidates.map(\.size.height).sorted()
        if heights.count >= 2 {
            let median = heights[heights.count / 2]
            let threshold = median * 1.20
            let tall = candidates.filter { $0.size.height >= threshold && median > 0 }
            if !tall.isEmpty {
                if tall.count == 1 { return tall[0] }
                if let frame = containerFrame {
                    let centerY = frame.midY
                    return tall.min(by: {
                        let a = abs($0.position.y + $0.size.height / 2 - centerY)
                        let b = abs($1.position.y + $1.size.height / 2 - centerY)
                        return a < b
                    })
                }
                return tall.max(by: { $0.size.height < $1.size.height })
            }
        }
        // Last resort — uniform-height panel (every line has the same height
        // because none is rendered as "active" yet, e.g. instrumental break).
        // Use geometric centering inside the lyrics container.
        if let frame = containerFrame, frame.height > 0 {
            let visible = candidates.filter {
                let midY = $0.position.y + $0.size.height / 2
                return midY >= frame.minY && midY <= frame.maxY
            }
            let pool = visible.isEmpty ? candidates : visible
            let centerY = frame.midY
            return pool.min(by: {
                let a = abs($0.position.y + $0.size.height / 2 - centerY)
                let b = abs($1.position.y + $1.size.height / 2 - centerY)
                return a < b
            })
        }
        return nil
    }

    private static func hasAccessibilityTrust(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        if prompt {
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        AppTelemetry.performance.info("Music.app AX lyrics unavailable because Accessibility trust is missing")
        return false
    }

    private struct VisibleLyricLine {
        let text: String
        let position: CGPoint
        let size: CGSize
        let isSelected: Bool
        /// Font size of the inner StaticText, if exposed. Music renders the
        /// active line larger than its neighbors — when available this is a
        /// far more discriminating signal than the button's outer height
        /// (which is padded and inflated by wrapped lines).
        let fontSize: CGFloat?
    }

    private struct AXTraversalBudget {
        let nodeLimit: Int
        let timeLimit: TimeInterval
        let startedAt = Date()
        private(set) var visitedNodes = 0
        private(set) var isExhausted = false

        var elapsed: TimeInterval {
            Date().timeIntervalSince(startedAt)
        }

        mutating func visit() -> Bool {
            guard !isExhausted else { return false }
            visitedNodes += 1
            if visitedNodes > nodeLimit || elapsed > timeLimit {
                isExhausted = true
                return false
            }
            return true
        }
    }

    private static func collectVisibleLyricLines(
        from element: AXUIElement,
        inLyricsContainer: Bool,
        containerFrame: inout CGRect?,
        into lines: inout [VisibleLyricLine],
        depth: Int,
        budget: inout AXTraversalBudget
    ) {
        guard depth <= 20, budget.visit() else { return }

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let description = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let value = stringAttribute(element, kAXValueAttribute as CFString) ?? ""
        let justEnteredContainer = !inLyricsContainer && (title == "Lyrics" || description == "Lyrics")
        let isLyricsContainer = inLyricsContainer || justEnteredContainer

        if justEnteredContainer,
           let position = pointAttribute(element, kAXPositionAttribute as CFString),
           let size = sizeAttribute(element, kAXSizeAttribute as CFString) {
            // Record the lyrics container's frame so we can pick the active
            // line by geometric centering rather than font-size heuristics.
            // If multiple containers match (rare), prefer the largest one.
            let frame = CGRect(origin: position, size: size)
            if containerFrame == nil || frame.height > (containerFrame?.height ?? 0) {
                containerFrame = frame
            }
        }

        if isLyricsContainer, role == kAXButtonRole as String {
            let text = [title, value, description]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty,
               text != "Lyrics",
               let position = pointAttribute(element, kAXPositionAttribute as CFString),
               let size = sizeAttribute(element, kAXSizeAttribute as CFString) {
                let isSelected = boolAttribute(element, kAXSelectedAttribute as CFString) ?? false
                let fontSize = readFontSize(button: element)
                if pendingAXDump {
                    dumpAttributes(of: element, label: "lyric-button[\(lines.count)] text=\"\(text.prefix(40))\"")
                    if lines.count >= 4 {
                        pendingAXDump = false
                    }
                }
                lines.append(VisibleLyricLine(
                    text: text,
                    position: position,
                    size: size,
                    isSelected: isSelected,
                    fontSize: fontSize
                ))
            }
        }

        for child in elementChildren(element) {
            guard !budget.isExhausted else { return }
            collectVisibleLyricLines(
                from: child,
                inLyricsContainer: isLyricsContainer,
                containerFrame: &containerFrame,
                into: &lines,
                depth: depth + 1,
                budget: &budget
            )
        }
    }

    private static func elementChildren(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let rawValue = attribute(element, name),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = rawValue as! AXValue
        var point = CGPoint.zero
        guard unsafe AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        guard let rawValue = attribute(element, name),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = rawValue as! AXValue
        var size = CGSize.zero
        guard unsafe AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        guard unsafe AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard unsafe AXUIElementCopyAttributeNames(element, &names) == .success,
              let cfNames = names else { return [] }
        return (cfNames as NSArray).compactMap { $0 as? String }
    }

    /// Walks the button's descendants for an AXStaticText (or first text-like
    /// element) and reads its AXFont/AXFontSize, since Music renders the
    /// active line at a larger point size than its neighbors.
    private static func readFontSize(button: AXUIElement, depth: Int = 0) -> CGFloat? {
        guard depth <= 4 else { return nil }
        if let direct = fontSize(from: button) { return direct }
        for child in elementChildren(button) {
            if let size = readFontSize(button: child, depth: depth + 1) {
                return size
            }
        }
        return nil
    }

    private static func fontSize(from element: AXUIElement) -> CGFloat? {
        // AXFont is typically a dictionary like {AXFontSize: 24, AXFontName: ...}
        if let dict = attribute(element, "AXFont" as CFString) as? [String: Any],
           let n = dict["AXFontSize"] as? NSNumber {
            return CGFloat(n.doubleValue)
        }
        if let n = attribute(element, "AXFontSize" as CFString) as? NSNumber {
            return CGFloat(n.doubleValue)
        }
        return nil
    }

    /// One-shot diagnostic: log every attribute name + a stringified value for
    /// a candidate lyric button and its children. Used to discover which
    /// attribute Music.app sets on the active line on the current OS build.
    private static func dumpAttributes(of element: AXUIElement, label: String, depth: Int = 0) {
        guard depth <= 2 else { return }
        let indent = String(repeating: "  ", count: depth)
        let names = attributeNames(element)
        var summary: [String] = []
        for name in names {
            let raw = attribute(element, name as CFString)
            let valueStr: String
            switch raw {
            case let s as String: valueStr = "\"\(s.prefix(60))\""
            case let n as NSNumber: valueStr = n.stringValue
            case let arr as [AnyObject]: valueStr = "[\(arr.count) items]"
            case let dict as [String: Any]:
                valueStr = "{" + dict.keys.sorted().prefix(6).joined(separator: ",") + "}"
            case .some(let v):
                let cfType = CFGetTypeID(v)
                if cfType == AXValueGetTypeID() {
                    valueStr = "<AXValue>"
                } else {
                    valueStr = "<\(type(of: v))>"
                }
            case .none: valueStr = "nil"
            }
            summary.append("\(name)=\(valueStr)")
        }
        AppTelemetry.performance.info("AXDUMP \(indent)\(label, privacy: .public) :: \(summary.joined(separator: " | "), privacy: .public)")
        for (i, child) in elementChildren(element).enumerated() {
            dumpAttributes(of: child, label: "child[\(i)]", depth: depth + 1)
        }
    }

    private static func logEmptyResult(_ raw: String) {
        if raw == "__EMPTY__" {
            AppTelemetry.performance.info("Music.app AppleScript lyrics empty for current track; trying Apple Music web")
        } else if raw.hasPrefix("__STATE__||") {
            let state = raw.replacingOccurrences(of: "__STATE__||", with: "")
            AppTelemetry.performance.info("Music.app AppleScript lyrics unavailable in player state=\(state, privacy: .public)")
        } else if raw.hasPrefix("__ERROR__||") || raw.hasPrefix("__SCRIPT_ERROR__||") {
            AppTelemetry.performance.error("Music.app AppleScript lyrics failed: \(raw, privacy: .public)")
        } else if raw == "__NOT_RUNNING__" {
            AppTelemetry.performance.info("Music.app AppleScript lyrics skipped because Music is not running")
        } else {
            AppTelemetry.performance.info("Music.app AppleScript lyrics returned unexpected empty marker; falling back")
        }
    }
}

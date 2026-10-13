import AppKit
import OSLog
import SwiftUI
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

enum LyricsOverlayLayout {
    static let expandedPanelHeight: CGFloat = 248
    static let collapsedPanelHeight: CGFloat = 148
    static let albumCoverSize: CGFloat = 96
    static let cornerRadius: CGFloat = 18

    static func panelHeight(for snapshot: LyricsOverlaySnapshot, isLyricsExpanded: Bool) -> CGFloat {
        displaysLyrics(for: snapshot, isLyricsExpanded: isLyricsExpanded) ? expandedPanelHeight : collapsedPanelHeight
    }

    static func displaysLyrics(for snapshot: LyricsOverlaySnapshot, isLyricsExpanded: Bool) -> Bool {
        isLyricsExpanded && snapshot.hasDisplayableLyrics
    }
}

extension LyricsOverlaySnapshot {
    var hasDisplayableLyrics: Bool {
        guard contentState == .ready else { return false }
        return activeLine != nil || !lyricWindow.isEmpty
    }
}

@MainActor
struct LyricsOverlayPlaybackCommands {
    var playPause: () -> Void
    var previousTrack: () -> Void
    var nextTrack: () -> Void
    var setVolume: (Int) -> Void
    var seek: (TimeInterval) -> Void

    static let disabled = LyricsOverlayPlaybackCommands(
        playPause: {},
        previousTrack: {},
        nextTrack: {},
        setVolume: { _ in },
        seek: { _ in }
    )
}

struct LyricsOverlayView: View {
    @Bindable var appState: AppState
    var onTranslationPreparationCompleted: () -> Void = {}
    var onPresentationLayoutChanged: () -> Void = {}
    var playbackCommands: LyricsOverlayPlaybackCommands = .disabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var showsVolumeSlider = false
    @State private var draftVolume = 50.0
    @State private var isScrubbingVolume = false
    @State private var isScrubbingPlayback = false
    @State private var draftPlaybackPosition = 0.0
    #if ENABLE_APPLE_TRANSLATION
    @State private var preparationConfiguration: TranslationSession.Configuration?
    @State private var preparationRequest: PreparedTranslationRequest?
    @State private var preparedTranslationIdentifiers: Set<String> = []
    #endif

    var body: some View {
        #if ENABLE_APPLE_TRANSLATION
        let request = preparationRequest
        content
            .translationTask(preparationConfiguration) { session in
                guard let request else { return }
                await prepareTranslationLanguages(with: session, request: request)
            }
            .task(id: appState.translationPreparationContextID) {
                scheduleTranslationPreparationIfNeeded()
            }
            .onDisappear {
                cancelTranslationPreparation()
            }
        #else
        content
        #endif
    }

    private var content: some View {
        let snapshot = appState.overlaySnapshot
        let panelHeight = LyricsOverlayLayout.panelHeight(
            for: snapshot,
            isLyricsExpanded: appState.isLyricsOverlayExpanded
        )

        return overlayContent(for: snapshot)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            LyricsOverlayBackgroundSurface(
                displayOptions: OverlayAccessibilityDisplayOptions(
                    reduceTransparency: reduceTransparency,
                    increaseContrast: colorSchemeContrast == .increased
                ),
                colorScheme: colorScheme
            )
        }
        .contentShape(Rectangle())
        // NSHostingView consumes mouse-down events, so the panel's
        // isMovableByWindowBackground never triggers. Child controls (buttons,
        // the scrub DragGesture) still win over this parent gesture.
        .gesture(WindowDragGesture(), isEnabled: !appState.isOverlayLocked)
        .onAppear {
            AppTelemetry.windowing.info("Lyrics overlay view appeared")
            syncDraftVolume()
            #if ENABLE_APPLE_TRANSLATION
            scheduleTranslationPreparationIfNeeded()
            #endif
        }
        .onDisappear {
            AppTelemetry.windowing.info("Lyrics overlay view disappeared")
        }
        .onChange(of: appState.musicVolume) {
            syncDraftVolume()
        }
        .onChange(of: appState.playerState.track?.id) {
            resetDraftPlaybackPosition()
        }
        .onChange(of: panelHeight) {
            onPresentationLayoutChanged()
        }
    }

    @ViewBuilder
    private func overlayContent(for snapshot: LyricsOverlaySnapshot) -> some View {
        let displaysLyrics = LyricsOverlayLayout.displaysLyrics(
            for: snapshot,
            isLyricsExpanded: appState.isLyricsOverlayExpanded
        )

        if appState.isLiveModeRunning {
            VStack(alignment: .leading, spacing: displaysLyrics ? 12 : 0) {
                HStack(alignment: .top, spacing: 14) {
                    albumCoverView(artwork: appState.nowPlayingArtwork)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(snapshot.trackText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        playbackSliderRow
                        playbackControlsRow(for: snapshot)
                    }
                    .frame(height: LyricsOverlayLayout.albumCoverSize, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: LyricsOverlayLayout.albumCoverSize, alignment: .top)

                if displaysLyrics {
                    lyricBlock(for: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: displaysLyrics ? .topLeading : .center)
        } else {
            HStack(alignment: .center, spacing: 14) {
                if appState.nowPlayingArtwork != nil {
                    albumCoverView(artwork: appState.nowPlayingArtwork)
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(snapshot.contentState.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stateTint(for: snapshot.contentState))
                            .lineLimit(1)

                        Text(snapshot.statusText)
                            .lineLimit(1)

                        Text(snapshot.attributionText)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(snapshot.trackText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if displaysLyrics {
                        lyricBlock(for: snapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func playbackControlsRow(for snapshot: LyricsOverlaySnapshot) -> some View {
        HStack(spacing: 7) {
            playbackButton(
                systemName: "backward.fill",
                label: "Previous track",
                help: "Previous track",
                isEnabled: playbackControlsEnabled,
                isActive: false,
                action: playbackCommands.previousTrack
            )

            playbackButton(
                systemName: appState.playerState.playbackStatus == .playing ? "pause.fill" : "play.fill",
                label: appState.playerState.playbackStatus == .playing ? "Pause" : "Play",
                help: appState.playerState.playbackStatus == .playing ? "Pause Apple Music" : "Play Apple Music",
                isEnabled: playbackControlsEnabled,
                isActive: false,
                symbolSize: 15,
                action: playbackCommands.playPause
            )

            playbackButton(
                systemName: "forward.fill",
                label: "Next track",
                help: "Next track",
                isEnabled: playbackControlsEnabled,
                isActive: false,
                action: playbackCommands.nextTrack
            )

            playbackButton(
                systemName: appState.isLyricsOverlayExpanded ? "quote.bubble.fill" : "quote.bubble",
                label: appState.isLyricsOverlayExpanded ? "Hide lyrics" : "Show lyrics",
                help: appState.isLyricsOverlayExpanded ? "Hide lyrics" : "Show lyrics",
                isEnabled: snapshot.hasDisplayableLyrics,
                isActive: appState.isLyricsOverlayExpanded && snapshot.hasDisplayableLyrics,
                symbolSize: 15,
                action: toggleLyricsExpansion
            )

            playbackButton(
                systemName: volumeSystemImageName,
                label: "Volume",
                help: showsVolumeSlider ? "Hide volume" : "Show volume",
                isEnabled: playbackControlsEnabled,
                isActive: showsVolumeSlider,
                symbolSize: 15,
                action: toggleVolumeSlider
            )

            if showsVolumeSlider {
                Slider(
                    value: $draftVolume,
                    in: 0...100,
                    onEditingChanged: { isEditing in
                        isScrubbingVolume = isEditing
                        if !isEditing {
                            commitVolumeChange()
                        }
                    }
                )
                .frame(width: volumeSliderWidth)
                .controlSize(.small)
                .disabled(!playbackControlsEnabled)
                .accessibilityLabel("Apple Music volume")
            }
        }
        .frame(height: 30, alignment: .leading)
    }

    @ViewBuilder
    private func lyricBlock(for snapshot: LyricsOverlaySnapshot) -> some View {
        LyricsLineStackView(snapshot: snapshot)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
    }

    @ViewBuilder
    private func albumCoverView(artwork: NSImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: LyricsOverlayLayout.albumCoverSize, height: LyricsOverlayLayout.albumCoverSize)
        .clipShape(shape)
        .overlay {
            shape.stroke(.separator.opacity(0.4), lineWidth: 1)
        }
        .accessibilityLabel(artwork == nil ? "Album artwork unavailable" : "Album artwork")
    }

    private var playbackSliderRow: some View {
        let duration = playbackDuration
        return MusicPlaybackProgressSlider(
            value: playbackPositionBinding(duration: duration),
            in: 0...max(1, duration),
            isEnabled: playbackControlsEnabled && duration > 0,
            onEditingChanged: playbackScrubEditingChanged
        )
        .accessibilityLabel("Playback position")
        .frame(height: 18, alignment: .leading)
    }

    private func playbackButton(
        systemName: String,
        label: String,
        help: String,
        isEnabled: Bool,
        isActive: Bool,
        symbolSize: CGFloat = 13,
        action: @escaping () -> Void
    ) -> some View {
        let activeColor = Color(red: 1.0, green: 0.17, blue: 0.34)
        let foregroundColor: Color = isActive ? activeColor : (isEnabled ? .primary : .secondary)

        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(
            isActive ? activeColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(activeColor.opacity(0.62), lineWidth: 1)
            }
        }
        .opacity(isEnabled ? 1 : 0.48)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
    }

    private var playbackControlsEnabled: Bool {
        appState.isLiveModeRunning && !appState.isPlaybackCommandInFlight
    }

    private var playbackDuration: TimeInterval {
        max(0, appState.playerState.track?.duration ?? 0)
    }

    private var currentPlaybackPosition: TimeInterval {
        let duration = playbackDuration
        let current = isScrubbingPlayback ? draftPlaybackPosition : appState.effectiveElapsedTime
        return MusicPlaybackCommand.clampedPlaybackPosition(current, duration: duration)
    }

    private func playbackPositionBinding(duration: TimeInterval) -> Binding<Double> {
        Binding(
            get: {
                currentPlaybackPosition
            },
            set: { nextValue in
                isScrubbingPlayback = true
                draftPlaybackPosition = MusicPlaybackCommand.clampedPlaybackPosition(nextValue, duration: duration)
            }
        )
    }

    private func playbackScrubEditingChanged(_ isEditing: Bool) {
        if isEditing {
            draftPlaybackPosition = currentPlaybackPosition
            isScrubbingPlayback = true
            return
        }

        let position = MusicPlaybackCommand.clampedPlaybackPosition(
            draftPlaybackPosition,
            duration: playbackDuration
        )
        draftPlaybackPosition = position
        isScrubbingPlayback = false
        playbackCommands.seek(position)
    }

    private var volumeSystemImageName: String {
        let volume = appState.musicVolume ?? MusicPlaybackCommand.clampedVolume(Int(draftVolume.rounded()))
        return volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private var volumeSliderWidth: CGFloat {
        appState.overlayWidthPreset == .compact ? 54 : 96
    }

    private func toggleLyricsExpansion() {
        appState.setLyricsOverlayExpanded(!appState.isLyricsOverlayExpanded)
    }

    private func toggleVolumeSlider() {
        syncDraftVolume()
        showsVolumeSlider.toggle()
    }

    private func syncDraftVolume() {
        guard !isScrubbingVolume else { return }
        guard let volume = appState.musicVolume else { return }
        draftVolume = Double(MusicPlaybackCommand.clampedVolume(volume))
    }

    private func commitVolumeChange() {
        let volume = MusicPlaybackCommand.clampedVolume(Int(draftVolume.rounded()))
        draftVolume = Double(volume)
        playbackCommands.setVolume(volume)
    }

    private func resetDraftPlaybackPosition() {
        draftPlaybackPosition = MusicPlaybackCommand.clampedPlaybackPosition(
            appState.effectiveElapsedTime,
            duration: playbackDuration
        )
        isScrubbingPlayback = false
    }

    private func stateTint(for state: OverlayContentState) -> Color {
        switch state {
        case .loading:
            .blue
        case .ready:
            .green
        case .unavailable:
            .secondary
        case .failed:
            .red
        }
    }

    #if ENABLE_APPLE_TRANSLATION
    private func scheduleTranslationPreparationIfNeeded() {
        if let preparationRequest, appState.ownsPreparedTranslationRequest(preparationRequest) { return }
        guard appState.isOverlayVisible,
              let download = appState.pendingTranslationDownload,
              !preparedTranslationIdentifiers.contains("\(download.source)->\(download.target)"),
              let request = appState.beginPreparedTranslationRequest() else {
            cancelTranslationPreparation()
            return
        }
        var configuration = preparationConfiguration ?? TranslationSession.Configuration(preferredStrategy: .lowLatency)
        configuration.source = Locale.Language(identifier: request.sourceLanguageIdentifier)
        configuration.target = Locale.Language(identifier: request.targetLanguageIdentifier)
        configuration.invalidate()
        preparationRequest = request
        preparationConfiguration = configuration
        AppTelemetry.windowing.notice(
            "Overlay translation preparation requested source=\(request.sourceLanguageIdentifier, privacy: .public) target=\(request.targetLanguageIdentifier, privacy: .public)"
        )
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
        if outcome == .ready || outcome == .retry {
            preparedTranslationIdentifiers.insert("\(request.sourceLanguageIdentifier)->\(request.targetLanguageIdentifier)")
        }
        if outcome == .retry {
            onTranslationPreparationCompleted()
        }
    }
    #endif

}

private struct OverlayAccessibilityDisplayOptions: Equatable {
    let reduceTransparency: Bool
    let increaseContrast: Bool
}

private struct LyricsOverlayBackgroundSurface: View {
    let displayOptions: OverlayAccessibilityDisplayOptions
    let colorScheme: ColorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LyricsOverlayLayout.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if displayOptions.reduceTransparency {
                shape.fill(reducedTransparencyFill)
            } else {
                shape.fill(.thinMaterial)
                shape.fill(surfaceGlaze)
            }

            shape.strokeBorder(borderGradient, lineWidth: strokeWidth)
        }
        .accessibilityHidden(true)
    }

    private var reducedTransparencyFill: Color {
        Color(nsColor: displayOptions.increaseContrast ? .windowBackgroundColor : .controlBackgroundColor)
    }

    private var surfaceGlaze: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.52),
                Color(nsColor: .controlAccentColor).opacity(colorScheme == .dark ? 0.05 : 0.08),
                Color.black.opacity(colorScheme == .dark ? 0.18 : 0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var borderGradient: LinearGradient {
        if displayOptions.increaseContrast {
            return LinearGradient(
                colors: [
                    Color(nsColor: .separatorColor).opacity(0.92),
                    Color(nsColor: .separatorColor).opacity(0.68)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.66),
                Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.42 : 0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var strokeWidth: CGFloat {
        displayOptions.increaseContrast ? 1.5 : 1
    }
}

private struct MusicPlaybackProgressSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let isEnabled: Bool
    private let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        isEnabled: Bool,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        _value = value
        self.range = range
        self.isEnabled = isEnabled
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let progress = normalizedProgress
            let fillWidth = width * CGFloat(progress)
            let knobSize: CGFloat = 12

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(isEnabled ? 0.30 : 0.18))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? 0.64 : 0.26))
                    .frame(width: max(0, fillWidth), height: 4)

                Circle()
                    .fill(Color.primary.opacity(isEnabled ? 0.92 : 0.34))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(0, fillWidth - knobSize / 2), max(0, width - knobSize)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            .allowsHitTesting(isEnabled)
        }
        .frame(minHeight: 18)
        .opacity(isEnabled ? 1 : 0.55)
        .disabled(!isEnabled)
        .accessibilityValue("\(Int((normalizedProgress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            adjustValue(direction)
        }
    }

    private var normalizedProgress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if !isDragging {
                    isDragging = true
                    onEditingChanged(true)
                }
                updateValue(at: gesture.location.x, width: width)
            }
            .onEnded { gesture in
                guard isEnabled else { return }
                updateValue(at: gesture.location.x, width: width)
                isDragging = false
                onEditingChanged(false)
            }
    }

    private func updateValue(at xPosition: CGFloat, width: CGFloat) {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let progress = min(1, max(0, Double(xPosition / max(width, 1))))
        value = range.lowerBound + progress * span
    }

    private func adjustValue(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else { return }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let step = max(span / 100, 1)

        onEditingChanged(true)
        switch direction {
        case .increment:
            value = min(range.upperBound, value + step)
        case .decrement:
            value = max(range.lowerBound, value - step)
        @unknown default:
            break
        }
        onEditingChanged(false)
    }
}

private struct LyricsLineStackView: View {
    let snapshot: LyricsOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if snapshot.lyricWindow.isEmpty {
                LyricsFallbackLineView(snapshot: snapshot)
            } else {
                ForEach(snapshot.lyricWindow) { row in
                    LyricsOverlayLineRowView(
                        row: row,
                        effectiveLyricTime: snapshot.effectiveLyricTime,
                        lyricClockReferenceDate: snapshot.lyricClockReferenceDate,
                        isLyricClockRunning: snapshot.isLyricClockRunning
                    )
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: snapshot.lyricWindow.map(\.id))
    }
}

private struct LyricsFallbackLineView: View {
    let snapshot: LyricsOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.lyricText)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if let translationText = snapshot.translationText {
                Text(translationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LyricsOverlayLineRowView: View {
    let row: LyricsOverlayLine
    let effectiveLyricTime: TimeInterval
    let lyricClockReferenceDate: Date
    let isLyricClockRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TimedLyricTextView(
                line: row.line,
                role: row.role,
                effectiveLyricTime: effectiveLyricTime,
                lyricClockReferenceDate: lyricClockReferenceDate,
                isLyricClockRunning: isLyricClockRunning
            )

            if let translationText = row.translationText {
                Text(translationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.role.opacity)
        .accessibilityAddTraits(row.role == .active ? .isSelected : [])
    }
}

private struct TimedLyricTextView: View {
    private static let lyricProgressRefreshInterval: TimeInterval = 0.12

    let line: LyricLine
    let role: LyricsOverlayLineRole
    let effectiveLyricTime: TimeInterval
    let lyricClockReferenceDate: Date
    let isLyricClockRunning: Bool

    var body: some View {
        if role == .active,
           usesSyllableTiming,
           isLyricClockRunning {
            TimelineView(.periodic(from: lyricClockReferenceDate, by: Self.lyricProgressRefreshInterval)) { context in
                timedText(at: effectiveLyricTime(at: context.date))
            }
        } else {
            timedText(at: effectiveLyricTime)
        }
    }

    @ViewBuilder
    private func timedText(at effectiveLyricTime: TimeInterval) -> some View {
        if let progress = progress(at: effectiveLyricTime),
           role == .active {
            progressText(progress: progress)
        } else {
            plainText
        }
    }

    private func effectiveLyricTime(at date: Date) -> TimeInterval {
        self.effectiveLyricTime + max(0, date.timeIntervalSince(lyricClockReferenceDate))
    }

    private func progress(at effectiveLyricTime: TimeInterval) -> Double? {
        guard usesSyllableTiming else { return nil }
        return LyricsOverlaySnapshotBuilder.timedLineProgress(
            in: line,
            at: effectiveLyricTime
        )
    }

    private var usesSyllableTiming: Bool {
        LyricsOverlaySnapshotBuilder.shouldRenderKaraokeProgress(for: line)
    }

    private var plainText: some View {
        Text(line.text)
            .font(role.lyricFont)
            .foregroundStyle(role == .active ? .primary : .secondary)
            .lineLimit(role == .active ? 2 : 1)
            .minimumScaleFactor(role == .active ? 0.78 : 0.86)
            .contentTransition(.opacity)
    }

    private func progressText(progress: Double) -> some View {
        plainText
            .foregroundStyle(.secondary.opacity(0.62))
            .overlay(alignment: fillAlignment) {
                GeometryReader { proxy in
                    plainText
                        .foregroundStyle(.primary)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: fillAlignment
                        )
                        .mask(alignment: fillAlignment) {
                            Rectangle()
                                .frame(width: max(1, proxy.size.width * CGFloat(progress)))
                        }
                }
                .allowsHitTesting(false)
            }
    }

    private var fillAlignment: Alignment {
        line.text.prefersRightToLeftLyricFill ? .trailing : .leading
    }
}

private extension LyricsOverlayLineRole {
    var lyricFont: Font {
        switch self {
        case .previous, .next:
            .system(.callout, weight: .medium)
        case .active:
            .system(.title3, weight: .semibold)
        }
    }

    var opacity: Double {
        switch self {
        case .previous, .next:
            0.54
        case .active:
            1
        }
    }
}

private extension String {
    var prefersRightToLeftLyricFill: Bool {
        unicodeScalars.first(where: { scalar in
            CharacterSet.letters.contains(scalar)
        })?.isRightToLeftLyricScalar == true
    }
}

private extension UnicodeScalar {
    var isRightToLeftLyricScalar: Bool {
        switch value {
        case 0x0590...0x05FF, // Hebrew
             0x0600...0x06FF, // Arabic
             0x0750...0x077F, // Arabic Supplement
             0x08A0...0x08FF, // Arabic Extended-A
             0xFB50...0xFDFF, // Arabic Presentation Forms-A
             0xFE70...0xFEFF: // Arabic Presentation Forms-B
            return true
        default:
            return false
        }
    }
}

#Preview {
    LyricsOverlayView(appState: AppState())
        .padding()
}

import AppKit
import OSLog

@MainActor
final class AppleMusicArtworkProvider {
    private let mediaCache: any MediaCache
    private let artworkDataProvider: () async -> Data?
    private var refreshTask: Task<Void, Never>?

    init(
        mediaCache: any MediaCache = EphemeralMediaCache(),
        artworkDataProvider: @escaping () async -> Data? = {
            await PublicAppleMusicArtworkProvider.currentTrackArtworkData()
        }
    ) {
        self.mediaCache = mediaCache
        self.artworkDataProvider = artworkDataProvider
    }

    func refreshArtwork(
        for track: NowPlayingTrack?,
        appState: AppState,
        onArtworkChanged: (@MainActor () -> Void)? = nil
    ) {
        refreshTask?.cancel()
        refreshTask = nil

        guard appState.isLiveModeRunning, let track else {
            appState.clearNowPlayingArtwork()
            onArtworkChanged?()
            return
        }

        appState.applyNowPlayingArtwork(nil, forTrackID: track.id)
        onArtworkChanged?()
        let cacheKey = Self.artworkCacheKey(for: track)
        refreshTask = Task { @MainActor [weak appState] in
            if case .data(let cachedData)? = await mediaCache.value(for: cacheKey),
               let image = NSImage(data: cachedData) {
                guard !Task.isCancelled, let appState else { return }
                AppTelemetry.performance.info("Music artwork cache hit")
                appState.applyNowPlayingArtwork(image, forTrackID: track.id)
                onArtworkChanged?()
                return
            }

            guard let data = await artworkDataProvider(),
                  let image = NSImage(data: data) else {
                guard !Task.isCancelled, let appState else { return }
                appState.applyNowPlayingArtwork(nil, forTrackID: track.id)
                onArtworkChanged?()
                return
            }
            await mediaCache.store(.data(data), for: cacheKey)
            guard !Task.isCancelled, let appState else { return }
            appState.applyNowPlayingArtwork(image, forTrackID: track.id)
            onArtworkChanged?()
        }
    }

    func cancel(appState: AppState, onArtworkChanged: (@MainActor () -> Void)? = nil) {
        refreshTask?.cancel()
        refreshTask = nil
        appState.clearNowPlayingArtwork()
        onArtworkChanged?()
    }

    static func artworkCacheKey(for track: NowPlayingTrack) -> MediaCacheKey {
        return MediaCacheKey(
            namespace: .artwork,
            rawValue: MediaCacheKey.redactedRawValue(
                prefix: "artwork-v1",
                components: [
                    track.providerName,
                    track.id,
                    String(track.duration)
                ]
            )
        )
    }
}

enum PublicAppleMusicArtworkProvider {
    private static let artworkScript = """
    tell application id "com.apple.Music"
        if it is running then
            try
                set artData to data of artwork 1 of current track
                return artData
            on error
                return ""
            end try
        else
            return ""
        end if
    end tell
    """

    static func currentTrackArtworkData() async -> Data? {
        guard await MainActor.run(body: { AppleMusicEventListener.isMusicAppRunning }) else {
            return nil
        }
        guard let data = await AppleScriptRunner.runDataOffMain(artworkScript),
              !data.isEmpty else {
            await MainActor.run {
                AppTelemetry.performance.info("Music artwork unavailable from AppleScript")
            }
            return nil
        }

        guard let thumbnailData = await ArtworkImageProcessor.downsampledImageData(from: data) else {
            await MainActor.run {
                AppTelemetry.performance.info("Music artwork unavailable after thumbnail downsampling")
            }
            return nil
        }

        return thumbnailData
    }

}

enum ArtworkImageProcessor {
    nonisolated static let defaultMaxPixelSize = 256

    nonisolated static func downsampledImageData(
        from data: Data,
        maxPixelSize: Int = defaultMaxPixelSize
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            downsampledImageDataSync(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func downsampledImageDataSync(
        from data: Data,
        maxPixelSize: Int
    ) -> Data? {
        autoreleasepool {
            guard let source = NSImage(data: data) else {
                return nil
            }

            let sourcePixelSize = source.bestPixelSize
            guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
                return nil
            }

            let normalizedMaxPixelSize = max(1, maxPixelSize)
            let targetPixelSize = scaledPixelSize(
                source: sourcePixelSize,
                maxPixelSize: normalizedMaxPixelSize
            )
            if max(sourcePixelSize.width, sourcePixelSize.height) <= CGFloat(normalizedMaxPixelSize) {
                return data
            }

            guard let bitmap = unsafe NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(targetPixelSize.width.rounded(.toNearestOrAwayFromZero)),
                pixelsHigh: Int(targetPixelSize.height.rounded(.toNearestOrAwayFromZero)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                return nil
            }
            bitmap.size = targetPixelSize

            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(
                in: NSRect(origin: .zero, size: targetPixelSize),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()

            return bitmap.representation(using: .png, properties: [:])
        }
    }

    nonisolated private static func scaledPixelSize(
        source: NSSize,
        maxPixelSize: Int
    ) -> NSSize {
        let maxDimension = max(source.width, source.height)
        guard maxDimension > CGFloat(maxPixelSize) else {
            return source
        }

        let scale = CGFloat(maxPixelSize) / maxDimension
        return NSSize(
            width: max(1, source.width * scale),
            height: max(1, source.height * scale)
        )
    }
}

private extension NSImage {
    nonisolated var bestPixelSize: NSSize {
        guard let largestRepresentation = representations.max(by: { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }) else {
            return size
        }

        guard largestRepresentation.pixelsWide > 0, largestRepresentation.pixelsHigh > 0 else {
            return size
        }

        return NSSize(width: largestRepresentation.pixelsWide, height: largestRepresentation.pixelsHigh)
    }
}

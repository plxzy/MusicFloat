import Foundation
import OSLog

/// Maps a `NowPlayingTrack` to the Apple Music catalog song ID needed by the
/// web-API lyrics endpoint.
///
/// Two paths:
/// 1. AppleScript — `URL of current track` is set when the track came from
///    the Apple Music catalog (not local files), and embeds the song ID as
///    the `i` query parameter. Free, no network.
/// 2. Catalog search — fallback when AppleScript doesn't expose the URL
///    (cloud library matches, older Music builds, etc.).
@MainActor
enum AppleMusicCatalogResolver {
    /// Result tuple: (storefront, songID). Storefront is the 2-letter region
    /// in the catalog URL ("us", "nl", …) — the web API endpoints are
    /// keyed by it.
    struct Identity: Equatable, Sendable {
        let storefront: String
        let songID: String
    }

    enum Resolution: Equatable, Sendable {
        case identity(Identity)
        case miss
        case transientFailure
    }

    private static let urlScript = """
    try
        tell application id "com.apple.Music"
            if it is not running then return ""
            try
                set u to (get URL of current track)
                if u is missing value then return ""
                return u as string
            on error
                return ""
            end try
        end tell
    on error
        return ""
    end try
    """

    static func resolve(
        track: NowPlayingTrack,
        developerToken: String,
        mediaUserToken: String,
        cachedStorefront: String?,
        session: URLSession = .shared,
        lookupID: String? = nil
    ) async -> Resolution {
        let effectiveLookupID = lookupID ?? Self.makeLookupID()
        if let local = await resolveFromAppleScript(lookupID: effectiveLookupID) {
            return .identity(local)
        }
        let storefront = cachedStorefront ?? "us"
        return await resolveViaSearch(
            track: track,
            storefront: storefront,
            developerToken: developerToken,
            mediaUserToken: mediaUserToken,
            session: session,
            lookupID: effectiveLookupID
        )
    }

    // MARK: - AppleScript URL parsing

    private static func resolveFromAppleScript(lookupID: String) async -> Identity? {
        guard let raw = await (MusicScriptingBridge.isEnabled
                ? MusicScriptingBridge.currentTrackURLString()
                : AppleScriptRunner.runStringOffMain(urlScript))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.host?.contains("music.apple.com") == true else {
            return nil
        }
        // music.apple.com/{cc}/album/{slug}/{album_id}?i={song_id}
        // music.apple.com/{cc}/song/{slug}/{song_id}
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let storefront = parts[0]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let songID = comps.queryItems?.first(where: { $0.name == "i" })?.value,
           !songID.isEmpty {
            AppTelemetry.performance.info("AM resolve via AppleScript lookup=\(lookupID, privacy: .public) storefront=\(storefront, privacy: .public) result=hit")
            return Identity(storefront: storefront, songID: songID)
        }
        if parts.count >= 4, parts[1] == "song" {
            AppTelemetry.performance.info("AM resolve via AppleScript lookup=\(lookupID, privacy: .public) storefront=\(storefront, privacy: .public) result=hit")
            return Identity(storefront: storefront, songID: parts[3])
        }
        return nil
    }

    // MARK: - Catalog search fallback

    nonisolated private struct SearchResponse: Decodable, Sendable {
        struct Results: Decodable, Sendable {
            struct Songs: Decodable, Sendable {
                struct Datum: Decodable, Sendable {
                    let id: String
                    let attributes: Attributes?
                }
                struct Attributes: Decodable, Sendable {
                    let name: String?
                    let artistName: String?
                    let albumName: String?
                    let durationInMillis: Int?
                    let hasLyrics: Bool?
                    let hasTimeSyncedLyrics: Bool?
                    let audioLocale: String?
                }
                let data: [Datum]
            }
            let songs: Songs?
        }
        let results: Results
    }

    private static func resolveViaSearch(
        track: NowPlayingTrack,
        storefront: String,
        developerToken: String,
        mediaUserToken: String,
        session: URLSession,
        lookupID: String
    ) async -> Resolution {
        let term = "\(track.title) \(track.artist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .miss }

        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return .miss }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        req.setValue(mediaUserToken, forHTTPHeaderField: "media-user-token")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse {
                    AppTelemetry.performance.info("AM search non-2xx lookup=\(lookupID, privacy: .public) status=\(http.statusCode)")
                }
                return .transientFailure
            }
            let decoded = try await decode(SearchResponse.self, from: data)
            let candidates = decoded.results.songs?.data ?? []
            guard let best = pickBest(from: candidates, track: track) else {
                AppTelemetry.performance.info("AM search no viable match lookup=\(lookupID, privacy: .public) candidates=\(candidates.count, privacy: .public)")
                return .miss
            }
            AppTelemetry.performance.info("AM resolve via search lookup=\(lookupID, privacy: .public) storefront=\(storefront, privacy: .public) result=hit")
            return .identity(Identity(storefront: storefront, songID: best.id))
        } catch {
            AppTelemetry.performance.error("AM search failed lookup=\(lookupID, privacy: .public) reason=\(Self.safeNetworkReason(error), privacy: .public)")
            return .transientFailure
        }
    }

    private static func pickBest(
        from items: [SearchResponse.Results.Songs.Datum],
        track: NowPlayingTrack
    ) -> SearchResponse.Results.Songs.Datum? {
        let title = normalize(track.title)
        let artist = normalize(track.artist)
        let album = normalize(track.album)
        guard !title.isEmpty, !artist.isEmpty else { return items.first }
        let hasLyricsSignal = items.contains {
            $0.attributes?.hasLyrics == true || $0.attributes?.hasTimeSyncedLyrics == true
        }

        func score(_ item: SearchResponse.Results.Songs.Datum) -> Double {
            var s = 0.0
            let aTitle = normalize(item.attributes?.name)
            let aArtist = normalize(item.attributes?.artistName)
            let aAlbum = normalize(item.attributes?.albumName)
            if aTitle == title { s += 3.0 }
            else if aTitle.contains(title) || title.contains(aTitle) { s += 2.0 }
            if aArtist == artist { s += 2.0 }
            else if aArtist.contains(artist) || artist.contains(aArtist) { s += 1.0 }
            if !album.isEmpty {
                if aAlbum == album { s += 1.0 }
                else if aAlbum.contains(album) || album.contains(aAlbum) { s += 0.5 }
            }
            if track.duration > 0, let ms = item.attributes?.durationInMillis {
                let delta = abs(Double(ms) / 1000.0 - track.duration)
                if delta <= 1.0 { s += 1.5 }
                else if delta <= 3.0 { s += 0.5 }
            }
            if item.attributes?.hasTimeSyncedLyrics == true {
                s += 1.25
            } else if item.attributes?.hasLyrics == true {
                s += 0.5
            } else if hasLyricsSignal {
                s -= 0.75
            }
            if item.attributes?.audioLocale?.isEmpty == false {
                s += 0.15
            }
            return s
        }

        return items.max { score($0) < score($1) }
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(type, from: data)
        }.value
    }

    private static func safeNetworkReason(_ error: any Error) -> String {
        guard let urlError = error as? URLError else {
            return "transport"
        }
        switch urlError.code {
        case .timedOut:
            return "timedOut"
        case .cancelled:
            return "cancelled"
        case .notConnectedToInternet:
            return "offline"
        default:
            return "urlError-\(urlError.code.rawValue)"
        }
    }

    private static func makeLookupID() -> String {
        String(UUID().uuidString.prefix(8))
    }
}

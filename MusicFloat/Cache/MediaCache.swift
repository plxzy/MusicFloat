import CryptoKit
import Foundation
import OSLog

nonisolated enum MediaCacheNamespace: String, Codable, Sendable {
    case artwork
    case lyrics
    case translation
}

nonisolated struct MediaCacheKey: Hashable, Sendable {
    let namespace: MediaCacheNamespace
    let rawValue: String

    static func redactedRawValue(prefix: String, components: [String]) -> String {
        var normalized = "\(prefix)\n"
        for component in components {
            normalized += "\(component.utf8.count):\(component)\n"
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { byte in
            let value = String(byte, radix: 16)
            return value.count == 1 ? "0\(value)" : value
        }.joined()
        return "\(prefix):\(hex)"
    }
}

nonisolated enum MediaCachePayload: Equatable, Sendable {
    case text(String)
    case data(Data)
    case unavailable

    var estimatedCost: Int {
        switch self {
        case .text(let value):
            value.utf8.count
        case .data(let data):
            data.count
        case .unavailable:
            1
        }
    }
}

nonisolated struct MediaCachePolicy: Equatable, Sendable {
    let maxEntries: Int
    let maxTotalCost: Int
    let artworkTTL: TimeInterval
    let lyricsTTL: TimeInterval
    let translationTTL: TimeInterval
    let unavailableTTL: TimeInterval

    init(
        maxEntries: Int = 64,
        maxTotalCost: Int = 2 * 1024 * 1024,
        artworkTTL: TimeInterval = 30 * 60,
        lyricsTTL: TimeInterval = 6 * 60 * 60,
        translationTTL: TimeInterval = 6 * 60 * 60,
        unavailableTTL: TimeInterval = 10 * 60
    ) {
        self.maxEntries = max(0, maxEntries)
        self.maxTotalCost = max(0, maxTotalCost)
        self.artworkTTL = max(0, artworkTTL)
        self.lyricsTTL = max(0, lyricsTTL)
        self.translationTTL = max(0, translationTTL)
        self.unavailableTTL = max(0, unavailableTTL)
    }

    func ttl(for key: MediaCacheKey, payload: MediaCachePayload) -> TimeInterval {
        if case .unavailable = payload {
            return unavailableTTL
        }

        switch key.namespace {
        case .artwork:
            return artworkTTL
        case .lyrics:
            return lyricsTTL
        case .translation:
            return translationTTL
        }
    }
}

nonisolated struct DiskMediaCachePolicy: Equatable, Sendable {
    let maxEntries: Int
    let maxTotalCost: Int
    let maxObjectCost: Int
    let persistedNamespaces: Set<MediaCacheNamespace>

    init(
        maxEntries: Int = 128,
        maxTotalCost: Int = 20 * 1024 * 1024,
        maxObjectCost: Int = 2 * 1024 * 1024,
        persistedNamespaces: Set<MediaCacheNamespace> = [.artwork, .translation]
    ) {
        self.maxEntries = max(0, maxEntries)
        self.maxTotalCost = max(0, maxTotalCost)
        self.maxObjectCost = max(0, maxObjectCost)
        self.persistedNamespaces = persistedNamespaces
    }
}

nonisolated struct MediaCacheUsageSummary: Equatable, Sendable {
    let memoryEntryCount: Int
    let memoryCost: Int
    let diskPersistenceEnabled: Bool
    let diskEntryCount: Int
    let diskCost: Int

    var displayText: String {
        let memory = Self.formattedByteCount(memoryCost)
        let disk = Self.formattedByteCount(diskCost)

        if diskPersistenceEnabled {
            return "Memory \(memory) - Disk \(disk)"
        }
        if diskCost > 0 {
            return "Memory \(memory) - Disk Off (\(disk) saved)"
        }
        return "Memory \(memory) - Disk Off"
    }

    private static func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1024 * 1024 ? [.useKB] : [.useMB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }
}

protocol MediaCache: Sendable {
    func value(for key: MediaCacheKey) async -> MediaCachePayload?
    func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async
    func removeAll() async
}

protocol UserControllableMediaCache: MediaCache {
    func setDiskPersistenceEnabled(_ isEnabled: Bool) async
    func usageSummary() async -> MediaCacheUsageSummary
}

actor EphemeralMediaCache: UserControllableMediaCache {
    private struct Entry {
        let payload: MediaCachePayload
        let expiresAt: Date
        let cost: Int
    }

    private var storage: [MediaCacheKey: Entry] = [:]
    private var order: [MediaCacheKey] = []
    private var totalCost = 0
    private let policy: MediaCachePolicy
    private let now: @Sendable () -> Date

    init(
        policy: MediaCachePolicy = MediaCachePolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.now = now
    }

    func value(for key: MediaCacheKey) async -> MediaCachePayload? {
        let timestamp = now()
        removeExpiredEntries(now: timestamp)
        guard let entry = storage[key] else {
            return nil
        }
        touch(key)
        return entry.payload
    }

    func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async {
        store(payload, for: key, expiresAt: now().addingTimeInterval(policy.ttl(for: key, payload: payload)))
    }

    func store(_ payload: MediaCachePayload, for key: MediaCacheKey, expiresAt: Date) {
        let timestamp = now()
        removeExpiredEntries(now: timestamp)

        let cost = payload.estimatedCost
        guard policy.maxEntries > 0, policy.maxTotalCost > 0, expiresAt > timestamp, cost <= policy.maxTotalCost else {
            removeEntry(for: key)
            return
        }

        removeEntry(for: key)
        storage[key] = Entry(payload: payload, expiresAt: expiresAt, cost: cost)
        order.append(key)
        totalCost += cost
        enforceLimits()
    }

    func removeAll() async {
        storage.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    func setDiskPersistenceEnabled(_ isEnabled: Bool) async {}

    func usageSummary() async -> MediaCacheUsageSummary {
        removeExpiredEntries(now: now())
        return MediaCacheUsageSummary(
            memoryEntryCount: storage.count,
            memoryCost: totalCost,
            diskPersistenceEnabled: false,
            diskEntryCount: 0,
            diskCost: 0
        )
    }

    private func removeExpiredEntries(now timestamp: Date) {
        let expired = order.filter { storage[$0]?.expiresAt ?? .distantPast <= timestamp }
        for key in expired {
            removeEntry(for: key)
        }
    }

    private func enforceLimits() {
        while storage.count > policy.maxEntries || totalCost > policy.maxTotalCost {
            guard let evict = order.first else { return }
            AppTelemetry.performance.info(
                "Media cache evicted namespace=\(evict.namespace.rawValue, privacy: .public) reason=limit"
            )
            removeEntry(for: evict)
        }
    }

    private func touch(_ key: MediaCacheKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func removeEntry(for key: MediaCacheKey) {
        if let entry = storage.removeValue(forKey: key) {
            totalCost -= entry.cost
        }
        order.removeAll { $0 == key }
    }
}

actor DiskBackedMediaCache: UserControllableMediaCache {
    private enum PayloadKind: String, Codable {
        case text
        case data
        case unavailable
    }

    private struct DiskPayloadRecord: Codable {
        let kind: PayloadKind
        let text: String?
        let data: Data?

        init(payload: MediaCachePayload) {
            switch payload {
            case .text(let value):
                kind = .text
                text = value
                data = nil
            case .data(let value):
                kind = .data
                text = nil
                data = value
            case .unavailable:
                kind = .unavailable
                text = nil
                data = nil
            }
        }

        var payload: MediaCachePayload? {
            switch kind {
            case .text:
                text.map(MediaCachePayload.text)
            case .data:
                data.map(MediaCachePayload.data)
            case .unavailable:
                .unavailable
            }
        }
    }

    private struct DiskEntry: Codable {
        let keyHash: String
        let namespace: MediaCacheNamespace
        let filename: String
        let byteSize: Int
        let createdAt: Date
        var lastAccessAt: Date
        let expiresAt: Date
    }

    private struct DiskIndex: Codable {
        let entries: [DiskEntry]
    }

    private let memoryCache: EphemeralMediaCache
    private let memoryPolicy: MediaCachePolicy
    private let diskPolicy: DiskMediaCachePolicy
    private let rootURL: URL
    private let indexURL: URL
    private let now: @Sendable () -> Date
    private var diskPersistenceEnabled: Bool
    private var initialized = false
    private var entriesByLookupKey: [String: DiskEntry] = [:]

    init(
        memoryPolicy: MediaCachePolicy = MediaCachePolicy(),
        diskPolicy: DiskMediaCachePolicy = DiskMediaCachePolicy(),
        diskPersistenceEnabled: Bool = false,
        rootURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.memoryPolicy = memoryPolicy
        self.diskPolicy = diskPolicy
        self.diskPersistenceEnabled = diskPersistenceEnabled
        self.now = now
        memoryCache = EphemeralMediaCache(policy: memoryPolicy, now: now)

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.rootURL = rootURL ?? cachesURL
            .appendingPathComponent("MusicFloat", isDirectory: true)
            .appendingPathComponent("MediaCache", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        indexURL = self.rootURL.appendingPathComponent("index.json", isDirectory: false)
    }

    func value(for key: MediaCacheKey) async -> MediaCachePayload? {
        if let memoryValue = await memoryCache.value(for: key) {
            return memoryValue
        }

        guard diskPersistenceEnabled,
              diskPolicy.persistedNamespaces.contains(key.namespace) else {
            return nil
        }

        ensureInitialized()
        let timestamp = now()
        pruneExpiredAndMissingEntries(now: timestamp)

        let lookup = lookupKey(for: key)
        guard var entry = entriesByLookupKey[lookup] else {
            return nil
        }
        let fileURL = fileURL(for: entry)
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(DiskPayloadRecord.self, from: data),
              let payload = record.payload else {
            removeDiskEntry(lookupKey: lookup)
            persistIndex()
            return nil
        }

        entry.lastAccessAt = timestamp
        entriesByLookupKey[lookup] = entry
        persistIndex()
        await memoryCache.store(payload, for: key, expiresAt: entry.expiresAt)
        AppTelemetry.performance.info(
            "Media cache disk hit namespace=\(key.namespace.rawValue, privacy: .public)"
        )
        return payload
    }

    func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async {
        await memoryCache.store(payload, for: key)

        guard diskPersistenceEnabled,
              diskPolicy.persistedNamespaces.contains(key.namespace) else {
            return
        }

        ensureInitialized()
        let ttl = memoryPolicy.ttl(for: key, payload: payload)
        let estimatedCost = payload.estimatedCost
        guard diskPolicy.maxEntries > 0,
              diskPolicy.maxTotalCost > 0,
              diskPolicy.maxObjectCost > 0,
              ttl > 0,
              estimatedCost <= diskPolicy.maxObjectCost else {
            removeDiskEntry(lookupKey: lookupKey(for: key))
            persistIndex()
            return
        }

        let record = DiskPayloadRecord(payload: payload)
        guard let data = try? JSONEncoder().encode(record),
              data.count <= diskPolicy.maxObjectCost else {
            removeDiskEntry(lookupKey: lookupKey(for: key))
            persistIndex()
            return
        }

        let timestamp = now()
        let keyHash = Self.stableHash(for: key)
        let lookup = lookupKey(namespace: key.namespace, keyHash: keyHash)
        let entry = DiskEntry(
            keyHash: keyHash,
            namespace: key.namespace,
            filename: "\(keyHash).json",
            byteSize: data.count,
            createdAt: timestamp,
            lastAccessAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(ttl)
        )

        do {
            try FileManager.default.createDirectory(
                at: namespaceDirectoryURL(key.namespace),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(for: entry), options: .atomic)
            entriesByLookupKey[lookup] = entry
            AppTelemetry.performance.info(
                "Media cache disk stored namespace=\(key.namespace.rawValue, privacy: .public) bytes=\(data.count)"
            )
        } catch {
            AppTelemetry.performance.error("Media cache disk store failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        pruneExpiredAndMissingEntries(now: timestamp)
        enforceDiskLimits()
        persistIndex()
    }

    func removeAll() async {
        await memoryCache.removeAll()

        do {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
        } catch {
            AppTelemetry.performance.error("Media cache clear failed: \(error.localizedDescription, privacy: .public)")
        }

        initialized = false
        entriesByLookupKey.removeAll(keepingCapacity: false)
        ensureInitialized()
    }

    func setDiskPersistenceEnabled(_ isEnabled: Bool) async {
        diskPersistenceEnabled = isEnabled
        if isEnabled {
            ensureInitialized()
        }
        AppTelemetry.settings.info("Disk media cache enabled=\(isEnabled)")
    }

    func usageSummary() async -> MediaCacheUsageSummary {
        let memorySummary = await memoryCache.usageSummary()
        ensureInitialized()
        pruneExpiredAndMissingEntries(now: now())
        return MediaCacheUsageSummary(
            memoryEntryCount: memorySummary.memoryEntryCount,
            memoryCost: memorySummary.memoryCost,
            diskPersistenceEnabled: diskPersistenceEnabled,
            diskEntryCount: entriesByLookupKey.count,
            diskCost: totalDiskCost()
        )
    }

    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            for namespace in diskPolicy.persistedNamespaces {
                try FileManager.default.createDirectory(
                    at: namespaceDirectoryURL(namespace),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            AppTelemetry.performance.error("Media cache init failed: \(error.localizedDescription, privacy: .public)")
        }

        entriesByLookupKey.removeAll(keepingCapacity: false)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(DiskIndex.self, from: data) {
            for entry in index.entries {
                let lookup = lookupKey(namespace: entry.namespace, keyHash: entry.keyHash)
                entriesByLookupKey[lookup] = entry
            }
        }

        pruneExpiredAndMissingEntries(now: now())
        enforceDiskLimits()
        persistIndex()
    }

    private func pruneExpiredAndMissingEntries(now timestamp: Date) {
        var didMutate = false
        for (lookup, entry) in entriesByLookupKey {
            if entry.expiresAt <= timestamp || !FileManager.default.fileExists(atPath: fileURL(for: entry).path) {
                removeDiskEntry(lookupKey: lookup)
                didMutate = true
            }
        }
        if didMutate {
            persistIndex()
        }
    }

    private func enforceDiskLimits() {
        var didMutate = false
        while entriesByLookupKey.count > diskPolicy.maxEntries || totalDiskCost() > diskPolicy.maxTotalCost {
            guard let lru = entriesByLookupKey.min(by: { $0.value.lastAccessAt < $1.value.lastAccessAt }) else {
                break
            }
            removeDiskEntry(lookupKey: lru.key)
            didMutate = true
        }
        if didMutate {
            persistIndex()
        }
    }

    private func removeDiskEntry(lookupKey: String) {
        guard let entry = entriesByLookupKey.removeValue(forKey: lookupKey) else { return }
        do {
            let url = fileURL(for: entry)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            AppTelemetry.performance.error("Media cache disk eviction failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistIndex() {
        let index = DiskIndex(entries: Array(entriesByLookupKey.values))
        do {
            let data = try JSONEncoder().encode(index)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            AppTelemetry.performance.error("Media cache index persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func totalDiskCost() -> Int {
        entriesByLookupKey.values.reduce(0) { $0 + max(0, $1.byteSize) }
    }

    private func fileURL(for entry: DiskEntry) -> URL {
        namespaceDirectoryURL(entry.namespace).appendingPathComponent(entry.filename, isDirectory: false)
    }

    private func namespaceDirectoryURL(_ namespace: MediaCacheNamespace) -> URL {
        rootURL.appendingPathComponent(namespace.rawValue, isDirectory: true)
    }

    private func lookupKey(for key: MediaCacheKey) -> String {
        lookupKey(namespace: key.namespace, keyHash: Self.stableHash(for: key))
    }

    private func lookupKey(namespace: MediaCacheNamespace, keyHash: String) -> String {
        "\(namespace.rawValue)|\(keyHash)"
    }

    nonisolated private static func stableHash(for key: MediaCacheKey) -> String {
        let normalized = "\(key.namespace.rawValue)|\(key.rawValue)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}

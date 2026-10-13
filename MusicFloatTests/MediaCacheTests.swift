import Foundation
import XCTest
@testable import MusicFloat

@MainActor
final class MediaCacheTests: XCTestCase {
    func testEphemeralCacheExpiresEntriesByNamespaceTTL() async {
        let clock = TestClock()
        let cache = EphemeralMediaCache(
            policy: MediaCachePolicy(
                maxEntries: 4,
                maxTotalCost: 1024,
                artworkTTL: 10,
                lyricsTTL: 20,
                translationTTL: 30,
                unavailableTTL: 5
            ),
            now: { clock.now }
        )
        let key = MediaCacheKey(namespace: .lyrics, rawValue: "track")

        await cache.store(.text("lyrics"), for: key)
        let initial = await cache.value(for: key)
        XCTAssertEqual(initial, .text("lyrics"))

        clock.advance(by: 21)
        let expired = await cache.value(for: key)
        XCTAssertNil(expired)
    }

    func testEphemeralCacheUsesShortUnavailableTTL() async {
        let clock = TestClock()
        let cache = EphemeralMediaCache(
            policy: MediaCachePolicy(
                maxEntries: 4,
                maxTotalCost: 1024,
                artworkTTL: 100,
                lyricsTTL: 100,
                translationTTL: 100,
                unavailableTTL: 5
            ),
            now: { clock.now }
        )
        let key = MediaCacheKey(namespace: .lyrics, rawValue: "miss")

        await cache.store(.unavailable, for: key)
        clock.advance(by: 6)

        let expired = await cache.value(for: key)
        XCTAssertNil(expired)
    }

    func testEphemeralCacheEvictsLeastRecentlyUsedEntryWhenFull() async {
        let cache = EphemeralMediaCache(
            policy: MediaCachePolicy(maxEntries: 2, maxTotalCost: 1024)
        )
        let first = MediaCacheKey(namespace: .lyrics, rawValue: "first")
        let second = MediaCacheKey(namespace: .lyrics, rawValue: "second")
        let third = MediaCacheKey(namespace: .lyrics, rawValue: "third")

        await cache.store(.text("1"), for: first)
        await cache.store(.text("2"), for: second)
        let firstHit = await cache.value(for: first)
        XCTAssertEqual(firstHit, .text("1"))
        await cache.store(.text("3"), for: third)

        let retained = await cache.value(for: first)
        let evicted = await cache.value(for: second)
        let inserted = await cache.value(for: third)
        XCTAssertEqual(retained, .text("1"))
        XCTAssertNil(evicted)
        XCTAssertEqual(inserted, .text("3"))
    }

    func testEphemeralCacheRejectsItemsLargerThanBudget() async {
        let cache = EphemeralMediaCache(
            policy: MediaCachePolicy(maxEntries: 4, maxTotalCost: 4)
        )
        let key = MediaCacheKey(namespace: .artwork, rawValue: "large")

        await cache.store(.data(Data(repeating: 0, count: 5)), for: key)

        let value = await cache.value(for: key)
        XCTAssertNil(value)
    }

    func testDiskBackedCachePersistsOptInPayloadAcrossInstances() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let key = MediaCacheKey(namespace: .translation, rawValue: "provider|document-hash|fr")
        let payload = MediaCachePayload.data(Data("translated lines".utf8))

        let first = DiskBackedMediaCache(
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )
        await first.store(payload, for: key)

        let second = DiskBackedMediaCache(
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )
        let restored = await second.value(for: key)

        XCTAssertEqual(restored, payload)
    }

    func testDiskBackedCacheRespectsDisabledPersistenceUntilEnabled() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let key = MediaCacheKey(namespace: .artwork, rawValue: "private-track-key")
        let payload = MediaCachePayload.data(Data([1, 2, 3, 4]))

        let writer = DiskBackedMediaCache(
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )
        await writer.store(payload, for: key)

        let disabledReader = DiskBackedMediaCache(
            diskPersistenceEnabled: false,
            rootURL: rootURL
        )
        let disabledRead = await disabledReader.value(for: key)
        XCTAssertNil(disabledRead)

        await disabledReader.setDiskPersistenceEnabled(true)
        let enabledRead = await disabledReader.value(for: key)
        XCTAssertEqual(enabledRead, payload)
    }

    func testDiskBackedCacheClearRemovesMemoryAndDiskPayloads() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let key = MediaCacheKey(namespace: .translation, rawValue: "clear-me")
        let cache = DiskBackedMediaCache(
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )

        await cache.store(.data(Data("payload".utf8)), for: key)
        await cache.removeAll()

        let value = await cache.value(for: key)
        let usage = await cache.usageSummary()
        XCTAssertNil(value)
        XCTAssertEqual(usage.memoryEntryCount, 0)
        XCTAssertEqual(usage.diskEntryCount, 0)
        XCTAssertEqual(usage.diskCost, 0)
    }

    func testDiskBackedCacheDoesNotPersistRawLookupKeyInIndexOrFilename() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let rawKey = "secret song title and private lyric"
        let cache = DiskBackedMediaCache(
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )

        await cache.store(.data(Data([9, 8, 7])), for: MediaCacheKey(namespace: .translation, rawValue: rawKey))

        let indexURL = rootURL.appendingPathComponent("index.json")
        let indexText = String(data: try Data(contentsOf: indexURL), encoding: .utf8) ?? ""
        let filenames = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).joined(separator: "\n")

        XCTAssertFalse(indexText.contains(rawKey))
        XCTAssertFalse(filenames.contains(rawKey))
    }

    func testDiskBackedCacheRemovesOldPayloadWhenReplacementEncodesTooLarge() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let key = MediaCacheKey(namespace: .translation, rawValue: "replace-large")
        let diskPolicy = DiskMediaCachePolicy(maxEntries: 8, maxTotalCost: 1024, maxObjectCost: 64)
        let writer = DiskBackedMediaCache(
            diskPolicy: diskPolicy,
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )

        await writer.store(.text("old"), for: key)
        await writer.store(.text(String(repeating: "x", count: 60)), for: key)

        let reader = DiskBackedMediaCache(
            diskPolicy: diskPolicy,
            diskPersistenceEnabled: true,
            rootURL: rootURL
        )
        let restored = await reader.value(for: key)

        XCTAssertNil(restored)
    }

    func testFirstRejectedDiskStorePreservesExistingIndexAndRemovesRejectedReplacement() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let diskPolicy = DiskMediaCachePolicy(maxEntries: 8, maxTotalCost: 1024, maxObjectCost: 64)
        let retainedKey = MediaCacheKey(namespace: .translation, rawValue: "retained")
        let replacedKey = MediaCacheKey(namespace: .translation, rawValue: "rejected-replacement")
        let writer = DiskBackedMediaCache(diskPolicy: diskPolicy, diskPersistenceEnabled: true, rootURL: rootURL)
        await writer.store(.text("keep"), for: retainedKey)
        await writer.store(.text("old"), for: replacedKey)

        let replacer = DiskBackedMediaCache(diskPolicy: diskPolicy, diskPersistenceEnabled: true, rootURL: rootURL)
        await replacer.store(.text(String(repeating: "x", count: 65)), for: replacedKey)

        let reader = DiskBackedMediaCache(diskPolicy: diskPolicy, diskPersistenceEnabled: true, rootURL: rootURL)
        let retained = await reader.value(for: retainedKey)
        let replaced = await reader.value(for: replacedKey)
        let usage = await reader.usageSummary()
        XCTAssertEqual(retained, .text("keep"))
        XCTAssertNil(replaced)
        XCTAssertEqual(usage.diskEntryCount, 1)
    }

    func testDiskPromotionKeepsOriginalExpiration() async throws {
        let rootURL = try makeTemporaryCacheDirectory()
        let clock = TestClock()
        let policy = MediaCachePolicy(translationTTL: 10)
        let key = MediaCacheKey(namespace: .translation, rawValue: "expires")
        let writer = DiskBackedMediaCache(
            memoryPolicy: policy, diskPersistenceEnabled: true, rootURL: rootURL, now: { clock.now }
        )
        await writer.store(.text("translation"), for: key)
        clock.advance(by: 9)

        let reader = DiskBackedMediaCache(
            memoryPolicy: policy, diskPersistenceEnabled: true, rootURL: rootURL, now: { clock.now }
        )
        let promoted = await reader.value(for: key)
        XCTAssertEqual(promoted, .text("translation"))
        clock.advance(by: 2)
        let expired = await reader.value(for: key)
        XCTAssertNil(expired)
    }

    private func makeTemporaryCacheDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFloatMediaCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

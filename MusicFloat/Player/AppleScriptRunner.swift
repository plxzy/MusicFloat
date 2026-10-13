import Foundation
@preconcurrency @unsafe import OSAKit
import OSLog

/// Minimal AppleScript wrapper for the small queries we issue against Music.app.
///
/// Kept intentionally tiny: string-result entry points only. AppleScript can
/// stall while Music.app is busy, so live-mode callers should use
/// `runStringOffMain(_:)` and then publish parsed state back on the main actor.
enum AppleScriptRunner {
    /// Runs `source` and returns the string description of its result.
    /// Returns `nil` on compile or execution error.
    nonisolated static func runString(_ source: String) -> String? {
        AppleScriptExecutor.shared.runStringSync(source)
    }

    nonisolated static func runStringOffMain(_ source: String) async -> String? {
        await AppleScriptExecutor.shared.runString(source)
    }

    /// Runs `source` off the main actor and returns raw Apple event descriptor bytes.
    nonisolated static func runDataOffMain(_ source: String) async -> Data? {
        await AppleScriptExecutor.shared.runData(source)
    }

    /// Runs `body` on the same long-lived scripting thread. ScriptingBridge
    /// calls are synchronous Apple events and share OSAKit's thread affinity.
    nonisolated static func performOffMain<Value: Sendable>(
        _ body: @escaping @Sendable () -> Value
    ) async -> Value {
        await AppleScriptExecutor.shared.perform(body)
    }
}

/// OSAKit is thread-affine and can throw Objective-C exceptions when its
/// language/component state is compiled from Swift's cooperative worker pool.
/// Keep all OSAScript and OSALanguage objects on one long-lived thread.
nonisolated private final class AppleScriptExecutor: @unchecked Sendable {
    static let shared = AppleScriptExecutor()

    private let maxCachedScripts = 24
    private var scripts: [String: OSAScript] = [:]
    private var scriptAccessOrder: [String] = []
    private var language: OSALanguage?
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var workerThread: Thread?

    private init() {
        let thread = Thread { [weak self] in
            self?.runWorker()
        }
        thread.name = "MusicFloat AppleScript"
        workerThread = thread
        thread.start()
    }

    nonisolated func runString(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            enqueue { [self] in
                continuation.resume(returning: runDescriptor(source)?.stringValue)
            }
        }
    }

    nonisolated func runData(_ source: String) async -> Data? {
        await withCheckedContinuation { continuation in
            enqueue { [self] in
                continuation.resume(returning: runDescriptor(source)?.rawDescriptorData)
            }
        }
    }

    nonisolated func perform<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            enqueue {
                continuation.resume(returning: body())
            }
        }
    }

    nonisolated func runStringSync(_ source: String) -> String? {
        if Thread.current === workerThread {
            return runDescriptor(source)?.stringValue
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = AppleScriptResultBox<String>()
        enqueue { [self] in
            result.value = runDescriptor(source)?.stringValue
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    private func runDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = compiledScript(for: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        guard let descriptor = unsafe script.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                logScriptError(errorInfo)
            }
            return nil
        }
        return descriptor
    }

    private func compiledScript(for source: String) -> OSAScript? {
        if let script = scripts[source] {
            recordScriptAccess(source)
            return script
        }

        if language == nil {
            language = OSALanguage(forName: "AppleScript")
        }

        let script = OSAScript(source: source, language: language)
        var errorInfo: NSDictionary?
        guard unsafe script.compileAndReturnError(&errorInfo) else {
            if let errorInfo {
                logScriptError(errorInfo)
            }
            return nil
        }

        scripts[source] = script
        scriptAccessOrder.append(source)
        evictOldScriptsIfNeeded()
        return script
    }

    private func recordScriptAccess(_ source: String) {
        scriptAccessOrder.removeAll { $0 == source }
        scriptAccessOrder.append(source)
    }

    private func evictOldScriptsIfNeeded() {
        while scripts.count > maxCachedScripts,
              let evictedSource = scriptAccessOrder.first {
            scriptAccessOrder.removeFirst()
            scripts.removeValue(forKey: evictedSource)
        }
    }

    private func logScriptError(_ errorInfo: NSDictionary) {
        let message = appleScriptErrorMessage(errorInfo)
        Task { @MainActor in
            AppTelemetry.performance.error("AppleScript error: \(message, privacy: .public)")
        }
    }

    private nonisolated func enqueue(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func runWorker() {
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool {
                job()
            }
        }
    }
}

nonisolated private final class AppleScriptResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

private nonisolated func appleScriptErrorMessage(_ errorInfo: NSDictionary) -> String {
    let message = (errorInfo[OSAScriptErrorMessageKey] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let number = errorInfo[OSAScriptErrorNumberKey].map { String(describing: $0) } ?? "unknown"
    if let message, !message.isEmpty {
        return "number=\(number) message=\(message)"
    }
    let keys = errorInfo.allKeys
        .map { String(describing: $0) }
        .sorted()
        .joined(separator: ",")
    return "number=\(number) message=unavailable keys=\(keys)"
}

private extension NSAppleEventDescriptor {
    nonisolated var rawDescriptorData: Data? {
        let payload = data
        if !payload.isEmpty { return payload }
        return coerce(toDescriptorType: typeData)?.data
    }
}

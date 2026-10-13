import Foundation
import OSLog

/// A prepared session belongs to one presentation request and one provider
/// context. Provider updates revoke its ownership even when the track is unchanged.
nonisolated struct PreparedTranslationRequest: Sendable {
    let id: UUID
    let contextID: UUID
    let trackID: String
    let document: LyricsDocument
    let sourceLanguageIdentifier: String
    let targetLanguageIdentifier: String
}

@MainActor
enum PreparedTranslationWork {
    enum Outcome: Equatable, Sendable {
        case ready
        case retry
        case cancelled
        case failed
        case superseded
    }

    static func run(
        request: PreparedTranslationRequest,
        appState: AppState,
        prepare: @MainActor () async throws -> Void,
        translate: @MainActor (LyricsDocument, String) async throws -> LyricTranslation?
    ) async -> Outcome {
        if Task.isCancelled {
            return appState.cancelPreparedTranslation(request) ? .cancelled : .superseded
        }
        guard appState.ownsPreparedTranslationRequest(request) else { return .superseded }
        do {
            try await prepare()
            try Task.checkCancellation()
            guard appState.preparedTranslationDidStart(request) else { return .superseded }
            let translation = try await translate(request.document, request.targetLanguageIdentifier)
            try Task.checkCancellation()
            guard appState.completePreparedTranslation(request, translation: translation) else { return .superseded }
            AppTelemetry.performance.notice("Prepared translation completed available=\(translation != nil)")
            return translation == nil ? .retry : .ready
        } catch {
            if error is CancellationError || Task.isCancelled {
                guard appState.cancelPreparedTranslation(request) else { return .superseded }
                AppTelemetry.performance.info("Prepared translation cancelled")
                return .cancelled
            }
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? "Translation preparation failed" : "Translation preparation failed: \(detail)"
            guard appState.failPreparedTranslation(request, reason: reason) else { return .superseded }
            AppTelemetry.performance.error("Prepared translation failed")
            return .failed
        }
    }
}

import XCTest
@testable import MusicFloat

@MainActor
final class AppStateTranslationPreferencesTests: XCTestCase {
    func testSystemLanguageDefaultIsStoredAsStableIdentifier() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.systemLanguageDefault.\(UUID().uuidString)")!

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.preferredTranslationLanguageIdentifier, AppState.systemLanguageIdentifier)
        XCTAssertEqual(
            defaults.string(forKey: "preferredTranslationLanguageIdentifier"),
            AppState.systemLanguageIdentifier
        )
    }

    func testInvalidStoredTargetLanguageFallsBackToSystemLanguage() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.invalidLanguage.\(UUID().uuidString)")!
        defaults.set("French", forKey: "preferredTranslationLanguageIdentifier")

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.preferredTranslationLanguageIdentifier, AppState.systemLanguageIdentifier)
        XCTAssertEqual(
            defaults.string(forKey: "preferredTranslationLanguageIdentifier"),
            AppState.systemLanguageIdentifier
        )
    }

    func testOverlayLockAndSnappingPreferencesRoundTrip() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.overlayPlacementPreferences.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        XCTAssertFalse(appState.isOverlayLocked)
        XCTAssertFalse(appState.snapsOverlayToEdges)

        appState.setOverlayLocked(true)
        appState.setSnapsOverlayToEdges(true)
        let restored = AppState(userDefaults: defaults)
        XCTAssertTrue(restored.isOverlayLocked)
        XCTAssertTrue(restored.snapsOverlayToEdges)

        restored.setOverlayLocked(false)
        restored.setSnapsOverlayToEdges(false)
        let unlocked = AppState(userDefaults: defaults)
        XCTAssertFalse(unlocked.isOverlayLocked)
        XCTAssertFalse(unlocked.snapsOverlayToEdges)
    }

    func testPreparedSessionTranslatesCapturedDocumentDirectly() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        let expected = preparedTranslation("Prepared session result")

        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: {},
            translate: { document, target in
                XCTAssertEqual(document, request.document)
                XCTAssertEqual(target, "fr")
                XCTAssertEqual(appState.translationRuntimeState, .translating)
                return expected
            }
        )

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(appState.translation, expected)
        XCTAssertEqual(appState.translationRuntimeState, .ready)
        XCTAssertFalse(appState.ownsPreparedTranslationRequest(request))
    }

    func testProviderReplacementDuringPreparationPreservesNewerResult() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        let newer = preparedTranslation("New pipeline result")
        var translated = false

        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: {
                appState.setProviderRuntimeState(.loading)
                appState.applyTranslation(newer)
                appState.setTranslationRuntimeState(.ready)
            },
            translate: { _, _ in
                translated = true
                return self.preparedTranslation("Stale prepared result")
            }
        )

        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(translated)
        XCTAssertEqual(appState.translation, newer)
        XCTAssertEqual(appState.translationRuntimeState, .ready)
    }

    func testProviderReplacementDuringTranslationPreservesNewerState() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())

        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: {},
            translate: { _, _ in
                appState.clearTranslation()
                appState.setTranslationRuntimeState(.checkingAvailability)
                return self.preparedTranslation("Stale prepared result")
            }
        )

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(appState.translation.lines.isEmpty)
        XCTAssertEqual(appState.translationRuntimeState, .checkingAvailability)
    }

    func testPreparedRequestCannotReviveAfterContextChangesAndReturns() throws {
        let mutations: [(String, @MainActor (AppState) -> Void)] = [
            ("track", { state in
                let original = state.playerState
                let document = state.lyricsDocument
                state.updatePlayerState(PlayerState(playbackStatus: .stopped, track: nil, elapsedTime: 0, updatedAt: Date()))
                state.updatePlayerState(original)
                state.applyLyricsDocument(document)
            }),
            ("lyrics", { state in
                let document = state.lyricsDocument
                state.applyLyricsDocument(LyricsDocument(source: .none, lines: [], isTimed: false))
                state.applyLyricsDocument(document)
            }),
            ("target", { state in
                state.preferredTranslationLanguageIdentifier = "de"
                state.preferredTranslationLanguageIdentifier = "fr"
            }),
            ("translation visibility", { state in
                state.showsTranslation = false
                state.showsTranslation = true
            }),
            ("overlay visibility", { state in
                state.isOverlayVisible = false
                state.isOverlayVisible = true
            }),
            ("runtime mode", { state in
                state.runtimeFeatureFlags = .liveAppleMusic
                state.runtimeFeatureFlags = .architectureDefault
            }),
            ("same provider state", { state in
                state.setProviderRuntimeState(state.providerRuntimeState)
            }),
            ("same translation state", { state in
                state.setTranslationRuntimeState(state.translationRuntimeState)
            })
        ]

        for (name, mutate) in mutations {
            let appState = preparedAppState()
            let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
            mutate(appState)
            let currentState = appState.translationRuntimeState
            let currentTranslation = appState.translation

            XCTAssertFalse(appState.preparedTranslationDidStart(request), name)
            XCTAssertFalse(appState.completePreparedTranslation(request, translation: preparedTranslation("Stale result")), name)
            XCTAssertFalse(appState.cancelPreparedTranslation(request), name)
            XCTAssertFalse(appState.failPreparedTranslation(request, reason: "Stale error"), name)
            XCTAssertEqual(appState.translationRuntimeState, currentState, name)
            XCTAssertEqual(appState.translation, currentTranslation, name)
        }
    }

    func testCancellationAfterTranslationCannotApplyUncooperativeResult() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        let task = Task { @MainActor in
            await PreparedTranslationWork.run(
                request: request,
                appState: appState,
                prepare: {},
                translate: { _, _ in
                    unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
                    return self.preparedTranslation("Cancelled result")
                }
            )
        }

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(appState.translation.lines.isEmpty)
        XCTAssertEqual(appState.translationRuntimeState, .idle)
        XCTAssertFalse(appState.ownsPreparedTranslationRequest(request))
    }

    func testCurrentPreparationFailureReleasesOwnership() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: { throw NSError(domain: "PreparedTranslationTest", code: 1) },
            translate: { _, _ in
                XCTFail("A failed preparation must not translate")
                return nil
            }
        )

        XCTAssertEqual(outcome, .failed)
        guard case .failed = appState.translationRuntimeState else {
            return XCTFail("Expected current preparation failure")
        }
        XCTAssertFalse(appState.ownsPreparedTranslationRequest(request))
    }

    func testEmptyPreparedTranslationAllowsProviderRetry() async throws {
        let appState = preparedAppState()
        let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        let outcome = await PreparedTranslationWork.run(
            request: request,
            appState: appState,
            prepare: {},
            translate: { _, _ in nil }
        )

        XCTAssertEqual(outcome, .retry)
        XCTAssertEqual(appState.translationRuntimeState, .idle)
        XCTAssertFalse(appState.ownsPreparedTranslationRequest(request))
    }

    func testStaleCancellationAndFailureLeaveReplacementUntouched() async throws {
        for cancellation in [true, false] {
            let appState = preparedAppState()
            let request = try XCTUnwrap(appState.beginPreparedTranslationRequest())
            let newer = preparedTranslation("Replacement")
            let outcome = await PreparedTranslationWork.run(
                request: request,
                appState: appState,
                prepare: {
                    appState.applyTranslation(newer)
                    appState.setTranslationRuntimeState(.ready)
                    if cancellation { throw CancellationError() }
                    throw NSError(domain: "PreparedTranslationTest", code: 1)
                },
                translate: { _, _ in
                    XCTFail("An obsolete preparation must not translate")
                    return nil
                }
            )

            XCTAssertEqual(outcome, .superseded)
            XCTAssertEqual(appState.translation, newer)
            XCTAssertEqual(appState.translationRuntimeState, .ready)
        }
    }

    func testOnlyOnePresentationCanOwnPreparedTranslation() throws {
        let appState = preparedAppState()
        let first = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        XCTAssertNil(appState.beginPreparedTranslationRequest())
        XCTAssertTrue(appState.ownsPreparedTranslationRequest(first))

        appState.setTranslationRuntimeState(.needsDownload(source: "en", target: "fr"))
        let replacement = try XCTUnwrap(appState.beginPreparedTranslationRequest())
        XCTAssertFalse(appState.cancelPreparedTranslation(first))
        XCTAssertTrue(appState.ownsPreparedTranslationRequest(replacement))
    }

    private func preparedAppState() -> AppState {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.preparedTranslation.\(UUID().uuidString)")!
        defaults.set("fr", forKey: "preferredTranslationLanguageIdentifier")
        let state = AppState(userDefaults: defaults)
        state.isOverlayVisible = true
        state.applyLyricsDocument(LyricsDocument(
            source: .mock,
            lines: [LyricLine(id: 0, text: "Test source", startTime: 0)],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        ))
        state.clearTranslation()
        state.setTranslationRuntimeState(.needsDownload(source: "en", target: "fr"))
        return state
    }

    private func preparedTranslation(_ text: String) -> LyricTranslation {
        LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: text)]
        )
    }
}

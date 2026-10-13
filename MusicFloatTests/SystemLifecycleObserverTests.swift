import AppKit
import XCTest
@testable import MusicFloat

final class SystemLifecycleObserverTests: XCTestCase {
    @MainActor
    private final class CallbackState {
        var isStopped = false
    }

    @MainActor
    func testObserverRoutesWorkspaceSuspendAndResumeEvents() async {
        let center = NotificationCenter()
        var suspended: [SystemLifecycleObserver.Event] = []
        var resumed: [SystemLifecycleObserver.Event] = []
        let state = CallbackState()
        let suspendExpectation = expectation(description: "suspend callbacks delivered")
        suspendExpectation.expectedFulfillmentCount = 2
        let resumeExpectation = expectation(description: "resume callbacks delivered")
        resumeExpectation.expectedFulfillmentCount = 2
        let stoppedExpectation = expectation(description: "stopped observer does not deliver callbacks")
        stoppedExpectation.isInverted = true

        let observer = SystemLifecycleObserver(
            notificationCenter: center,
            onSuspend: { event in
                if state.isStopped {
                    stoppedExpectation.fulfill()
                    return
                }
                suspended.append(event)
                suspendExpectation.fulfill()
            },
            onResume: { event in
                if state.isStopped {
                    stoppedExpectation.fulfill()
                    return
                }
                resumed.append(event)
                resumeExpectation.fulfill()
            }
        )

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await fulfillment(of: [suspendExpectation, resumeExpectation], timeout: 1.0)

        XCTAssertEqual(suspended, [.willSleep, .sessionDidResignActive])
        XCTAssertEqual(resumed, [.didWake, .sessionDidBecomeActive])

        state.isStopped = true
        observer.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [stoppedExpectation], timeout: 0.1)

        XCTAssertEqual(suspended, [.willSleep, .sessionDidResignActive])
    }
}

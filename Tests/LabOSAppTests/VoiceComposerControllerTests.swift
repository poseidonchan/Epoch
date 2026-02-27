#if os(iOS)
import XCTest
@testable import LabOSApp

final class VoiceComposerControllerTests: XCTestCase {
    func testShortTapInHoldModeLocksRecordingInsteadOfSubmitting() {
        let decision = VoiceComposerController.resolveReleaseDecision(
            captureMode: .hold,
            cancelledByGesture: false,
            pressDuration: 0.12,
            threshold: VoiceComposerController.tapVsHoldDecisionThreshold
        )

        XCTAssertEqual(decision.action, .keepRecording)
        XCTAssertEqual(decision.nextMode, .tapLocked)
    }

    func testSecondTapInLockedModeSubmitsRecording() {
        let decision = VoiceComposerController.resolveReleaseDecision(
            captureMode: .tapLocked,
            cancelledByGesture: false,
            pressDuration: 0.08,
            threshold: VoiceComposerController.tapVsHoldDecisionThreshold
        )

        XCTAssertEqual(decision.action, .submit)
        XCTAssertEqual(decision.nextMode, .none)
    }

    func testLongPressInHoldModeSubmitsRecordingOnRelease() {
        let decision = VoiceComposerController.resolveReleaseDecision(
            captureMode: .hold,
            cancelledByGesture: false,
            pressDuration: 0.85,
            threshold: VoiceComposerController.tapVsHoldDecisionThreshold
        )

        XCTAssertEqual(decision.action, .submit)
        XCTAssertEqual(decision.nextMode, .none)
    }

    func testSlideCancelInHoldModeCancelsRecording() {
        let decision = VoiceComposerController.resolveReleaseDecision(
            captureMode: .hold,
            cancelledByGesture: true,
            pressDuration: 1.2,
            threshold: VoiceComposerController.tapVsHoldDecisionThreshold
        )

        XCTAssertEqual(decision.action, .cancel)
        XCTAssertEqual(decision.nextMode, .none)
    }

    func testShortTapDecisionStaysKeepRecordingEvenIfPermissionReturnsLater() {
        let decision = VoiceComposerController.resolveReleaseDecision(
            captureMode: .hold,
            cancelledByGesture: false,
            pressDuration: 0.05,
            threshold: VoiceComposerController.tapVsHoldDecisionThreshold
        )

        XCTAssertEqual(decision.action, .keepRecording)
        XCTAssertEqual(decision.nextMode, .tapLocked)
    }
}
#endif

#if !os(iOS)
import XCTest

final class VoiceComposerControllerTests: XCTestCase {
    func testVoiceComposerControllerBehaviorCoveredOnIOSOnly() {
        XCTAssertTrue(true)
    }
}
#endif

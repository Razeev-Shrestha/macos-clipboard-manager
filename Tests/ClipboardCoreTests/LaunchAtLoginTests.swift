import XCTest
@testable import ClipboardCore

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testNativeStatusIsReportedWithoutRegisteringOnInit() {
        var registerCount = 0
        let boundary = LaunchAtLoginNativeBoundary(
            status: { .requiresApproval },
            register: { registerCount += 1 },
            unregister: {}
        )

        let controller = LaunchAtLoginController(native: boundary)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertEqual(registerCount, 0)
    }

    func testRegisterSuccessUsesObservedStatus() {
        var observedStatus: LaunchAtLoginStatus = .disabled
        var registerCount = 0
        let boundary = LaunchAtLoginNativeBoundary(
            status: { observedStatus },
            register: { registerCount += 1; observedStatus = .enabled },
            unregister: { observedStatus = .disabled }
        )
        let controller = LaunchAtLoginController(native: boundary)

        XCTAssertEqual(controller.setEnabled(true), .enabled)
        XCTAssertEqual(controller.setEnabled(true), .enabled)
        XCTAssertEqual(registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(controller.setEnabled(false), .disabled)
    }

    func testSetEnabledRefreshesExternalNativeStatusBeforeIdempotenceCheck() {
        var observedStatus: LaunchAtLoginStatus = .enabled
        var registerCount = 0
        var unregisterCount = 0
        let boundary = LaunchAtLoginNativeBoundary(
            status: { observedStatus },
            register: { registerCount += 1; observedStatus = .enabled },
            unregister: { unregisterCount += 1; observedStatus = .disabled }
        )
        let controller = LaunchAtLoginController(native: boundary)

        // Simulate a user revoking the registration outside this controller.
        observedStatus = .disabled
        XCTAssertEqual(controller.setEnabled(true), .enabled)
        XCTAssertEqual(registerCount, 1)

        // And the inverse: a stale cached disabled state must not skip unregister.
        observedStatus = .enabled
        XCTAssertEqual(controller.setEnabled(false), .disabled)
        XCTAssertEqual(unregisterCount, 1)
    }

    func testRegisterFailureWithApprovalStatusPreservesAuthoritativeState() {
        var observedStatus: LaunchAtLoginStatus = .disabled
        let boundary = LaunchAtLoginNativeBoundary(
            status: { observedStatus },
            register: {
                observedStatus = .requiresApproval
                throw TestError.failed
            },
            unregister: {}
        )
        let controller = LaunchAtLoginController(native: boundary)

        XCTAssertEqual(controller.setEnabled(true), .requiresApproval)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testRegisterFailureDoesNotClaimEnabled() {
        let boundary = LaunchAtLoginNativeBoundary(
            status: { .disabled },
            register: { throw TestError.failed },
            unregister: {}
        )
        let controller = LaunchAtLoginController(native: boundary)

        XCTAssertEqual(controller.setEnabled(true), .failed)
        XCTAssertEqual(controller.status, .failed)
    }

    func testUnregisterFailureWhenAlreadyDisabledRemainsDisabled() {
        let boundary = LaunchAtLoginNativeBoundary(
            status: { .disabled },
            register: {},
            unregister: { throw TestError.failed }
        )
        let controller = LaunchAtLoginController(native: boundary)

        XCTAssertEqual(controller.setEnabled(false), .disabled)
    }

    private enum TestError: Error {
        case failed
    }
}

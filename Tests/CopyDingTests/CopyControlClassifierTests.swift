import XCTest
@testable import CopyDing

final class CopyControlClassifierTests: XCTestCase {
    func testRecognisesStandardCopyMenuItem() {
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXMenuItem",
            commandCharacter: nil,
            labels: ["Copy"]
        ))
    }

    func testRejectsMenuItemKeyboardEquivalentWithoutCopyLabel() {
        XCTAssertFalse(CopyControlClassifier.isCopyControl(
            role: "AXMenuItem",
            commandCharacter: "C",
            labels: []
        ))
    }

    func testRecognisesContextMenuCopyItems() {
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXMenuItem",
            commandCharacter: nil,
            labels: ["Copy link"]
        ))
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXMenuItem",
            commandCharacter: nil,
            labels: ["Copy to Clipboard"]
        ))
    }

    func testRejectsCopyLabeledButtonOutsideContextMenu() {
        XCTAssertFalse(CopyControlClassifier.isCopyControl(
            role: "AXButton",
            commandCharacter: nil,
            labels: ["Copy"]
        ))
    }

    func testRejectsUnrelatedControls() {
        XCTAssertFalse(CopyControlClassifier.isCopyControl(
            role: "AXButton",
            commandCharacter: nil,
            labels: ["Copyright information"]
        ))
        XCTAssertFalse(CopyControlClassifier.isCopyControl(
            role: "AXLink",
            commandCharacter: nil,
            labels: ["Copy"]
        ))
        XCTAssertFalse(CopyControlClassifier.isCopyControl(
            role: "AXButton",
            commandCharacter: nil,
            labels: ["Share"]
        ))
    }

    func testSuccessSoundModesHaveExpectedTitles() {
        XCTAssertEqual(
            SuccessSoundMode.allCases.map(\.title),
            ["Off", "⌘C only", "Any clipboard change"]
        )
    }
}

#if APP_STORE
@MainActor
final class AppStoreEntitlementTests: XCTestCase {
    func testAccessStartsWithoutTrialOrPro() {
        XCTAssertEqual(
            AppStoreEntitlementManager.accessState(
                hasPro: false,
                trialPurchaseDate: nil,
                now: Date()
            ),
            .trialNotStarted
        )
    }

    func testAccessIsActiveForVerifiedTrialDate() {
        let purchaseDate = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            AppStoreEntitlementManager.accessState(
                hasPro: false,
                trialPurchaseDate: purchaseDate,
                now: purchaseDate.addingTimeInterval(3 * 24 * 60 * 60)
            ),
            .trialActive(daysRemaining: 11)
        )
    }

    func testAccessExpiresAfterFourteenDays() {
        let purchaseDate = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            AppStoreEntitlementManager.accessState(
                hasPro: false,
                trialPurchaseDate: purchaseDate,
                now: purchaseDate.addingTimeInterval(AppStoreEntitlementManager.trialDuration)
            ),
            .trialExpired
        )
    }

    func testProTakesPriorityOverExpiredTrial() {
        XCTAssertEqual(
            AppStoreEntitlementManager.accessState(
                hasPro: true,
                trialPurchaseDate: Date.distantPast,
                now: Date()
            ),
            .pro
        )
    }
}
#endif

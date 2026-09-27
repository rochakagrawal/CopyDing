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

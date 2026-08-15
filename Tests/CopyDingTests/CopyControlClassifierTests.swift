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

    func testRecognisesMenuItemKeyboardEquivalent() {
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXMenuItem",
            commandCharacter: "C",
            labels: []
        ))
    }

    func testRecognisesLabelledCopyButtons() {
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXButton",
            commandCharacter: nil,
            labels: ["Copy link"]
        ))
        XCTAssertTrue(CopyControlClassifier.isCopyControl(
            role: "AXButton",
            commandCharacter: nil,
            labels: ["copyToClipboardButton"]
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
}

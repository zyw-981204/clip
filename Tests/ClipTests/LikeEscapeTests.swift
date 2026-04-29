import XCTest
@testable import Clip

final class LikeEscapeTests: XCTestCase {
    func testEscapesPercent() {
        XCTAssertEqual(LikeEscape.escape("a%b"), "a\\%b")
    }

    func testEscapesUnderscore() {
        XCTAssertEqual(LikeEscape.escape("a_b"), "a\\_b")
    }

    func testEscapesBackslash() {
        XCTAssertEqual(LikeEscape.escape("a\\b"), "a\\\\b")
    }

    func testPlainStringUnchanged() {
        XCTAssertEqual(LikeEscape.escape("git status"), "git status")
    }

    func testEmptyString() {
        XCTAssertEqual(LikeEscape.escape(""), "")
    }

    func testMixed() {
        XCTAssertEqual(LikeEscape.escape("50%_off\\now"), "50\\%\\_off\\\\now")
    }
}

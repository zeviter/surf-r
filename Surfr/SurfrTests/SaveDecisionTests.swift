import XCTest
@testable import Surfr

final class SaveDecisionTests: XCTestCase {
    private let id1 = UUID()
    private let id2 = UUID()

    func test_new_isSave() {
        XCTAssertEqual(SaveDecision.classify(username: "a", password: "p", existing: [], neverListed: false), .save)
    }

    func test_exactDuplicate_noPrompt() {
        XCTAssertEqual(SaveDecision.classify(username: "a", password: "p", existing: [(id1, "a", "p")], neverListed: false), .noPrompt)
    }

    func test_sameUsernameDifferentPassword_update() {
        XCTAssertEqual(SaveDecision.classify(username: "a", password: "new", existing: [(id1, "a", "old")], neverListed: false), .update(itemID: id1))
    }

    func test_differentUsername_isSave() {
        XCTAssertEqual(SaveDecision.classify(username: "b", password: "p", existing: [(id1, "a", "p")], neverListed: false), .save)
    }

    func test_neverListed_wins() {
        XCTAssertEqual(SaveDecision.classify(username: "a", password: "p", existing: [(id1, "a", "old")], neverListed: true), .neverListed)
    }

    func test_exactDuplicateAmongMany_noPrompt() {
        let existing = [(id1, "other", "x"), (id2, "a", "p")]
        XCTAssertEqual(SaveDecision.classify(username: "a", password: "p", existing: existing, neverListed: false), .noPrompt)
    }
}

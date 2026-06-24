import XCTest
@testable import Surfr

/// Slice 9 — the vault navigation STACK: Back/ESC pop one level; an item opened from Security Check
/// returns to Security Check; popping at the root signals "close the surface".
final class VaultNavTests: XCTestCase {

    func test_pushPop_returnsToParent() {
        var nav = VaultNav()
        XCTAssertNil(nav.current)
        XCTAssertTrue(nav.atRoot)

        nav.push(.detail(UUID()))
        nav.push(.editLogin(UUID()))
        XCTAssertTrue(nav.pop())                       // edit → detail
        if case .detail = nav.current {} else { XCTFail("expected detail after popping edit") }
        XCTAssertTrue(nav.pop())                       // detail → list (root)
        XCTAssertTrue(nav.atRoot)
        XCTAssertFalse(nav.pop())                      // at root: nothing to pop → caller closes surface
    }

    /// The Bug-1 fix: an item opened FROM Security Check pops back to Security Check, not the list.
    func test_itemOpenedFromSecurityCheck_returnsToSecurityCheck() {
        var nav = VaultNav()
        nav.push(.securityCheck)
        nav.push(.editLogin(UUID()))                   // open a weak item's editor from Security Check
        XCTAssertTrue(nav.pop())
        XCTAssertEqual(nav.current, .securityCheck)     // back lands on Security Check, not the list
        XCTAssertTrue(nav.pop())
        XCTAssertTrue(nav.atRoot)
    }

    /// A note opened from the Notes segment returns to the list (one level), and its editor pops to the
    /// note detail — origin/stack threading is type-agnostic.
    func test_typedScreens_popOneLevel() {
        var nav = VaultNav()
        let id = UUID()
        nav.push(.detail(id))
        nav.push(.editAddress(id))
        XCTAssertTrue(nav.pop())                        // editAddress → detail
        XCTAssertEqual(nav.current, .detail(id))
        XCTAssertTrue(nav.pop())                        // detail → list
        XCTAssertTrue(nav.atRoot)
    }

    func test_openItemID_tracksDetailAndEdit() {
        var nav = VaultNav()
        let id = UUID()
        nav.push(.detail(id));        XCTAssertEqual(nav.openItemID, id)
        nav.push(.editNote(id));      XCTAssertEqual(nav.openItemID, id)
        nav.reset();                  XCTAssertNil(nav.openItemID)
        nav.push(.securityCheck);     XCTAssertNil(nav.openItemID)   // not an item screen
    }
}

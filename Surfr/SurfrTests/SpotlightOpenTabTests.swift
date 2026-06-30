import XCTest
@testable import Surfr

/// C2 — the omnibox open-tab (switch-to-tab) source matching. Pure (no DB): match by title OR URL,
/// dedupe by URL, cap at 4, and carry the tab id so selection switches rather than navigates.
final class SpotlightOpenTabTests: XCTestCase {

    private func tab(_ title: String, _ url: String) -> OpenTabRef {
        OpenTabRef(id: UUID(), title: title, url: URL(string: url)!)
    }

    func test_matchesByTitleOrURL_caseInsensitive_andCarriesTabID() {
        let gh = tab("GitHub — surf-r", "https://github.com/zeviter/surf-r")
        let tabs = [gh, tab("Hacker News", "https://news.ycombinator.com")]

        let byTitle = SpotlightOmnibox.matchingOpenTabs(query: "github", openTabs: tabs)
        XCTAssertEqual(byTitle.count, 1)
        XCTAssertEqual(byTitle.first?.source, .openTab)
        XCTAssertEqual(byTitle.first?.tabID, gh.id)         // selection switches to THIS tab

        let byURL = SpotlightOmnibox.matchingOpenTabs(query: "YCOMBINATOR", openTabs: tabs)   // case-insensitive URL
        XCTAssertEqual(byURL.count, 1)
        XCTAssertEqual(byURL.first?.title, "Hacker News")

        XCTAssertTrue(SpotlightOmnibox.matchingOpenTabs(query: "nomatch", openTabs: tabs).isEmpty)
        XCTAssertTrue(SpotlightOmnibox.matchingOpenTabs(query: "", openTabs: tabs).isEmpty)   // empty query → none
    }

    func test_dedupesByURL_andCapsAtFour() {
        let url = "https://example.com/page"
        let dupes = [tab("A", url), tab("B", url)]   // same URL twice
        XCTAssertEqual(SpotlightOmnibox.matchingOpenTabs(query: "example", openTabs: dupes).count, 1)

        let many = (0..<7).map { tab("Example \($0)", "https://example.com/\($0)") }
        XCTAssertEqual(SpotlightOmnibox.matchingOpenTabs(query: "example", openTabs: many).count, 4)   // capped
    }
}

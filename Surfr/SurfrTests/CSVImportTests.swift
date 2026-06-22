import XCTest
import SurfrCore
@testable import Surfr

final class CSVParserTests: XCTestCase {
    func test_quotesCommasNewlinesEscapes() {
        let text = "a,b,c\n\"x,y\",\"line1\nline2\",\"he said \"\"hi\"\"\"\n"
        let rows = CSV.parse(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["x,y", "line1\nline2", "he said \"hi\""])
    }

    func test_noTrailingEmptyRow() {
        XCTAssertEqual(CSV.parse("a,b\n1,2\n").count, 2)   // not 3
        XCTAssertEqual(CSV.parse("a,b\r\n1,2").count, 2)   // CRLF
    }
}

@MainActor
final class CSVImportTests: XCTestCase {

    func test_lastPass_mapsFields_andTOTP() throws {
        let csv = """
        url,username,password,totp,extra,name,grouping,fav
        https://github.com,alice,p@ss,JBSWY3DPEHPK3PXP,my note,GitHub,Dev,0
        https://x.com,bob,"pw,with,commas",,,X,,0
        """
        let r = try CSVImport.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.format, "LastPass")
        XCTAssertTrue(r.totpMayBeMissing)
        XCTAssertEqual(r.candidates.count, 2)

        let gh = r.candidates[0]
        XCTAssertEqual(gh.title, "GitHub")
        XCTAssertEqual(gh.hosts.first?.host, "github.com")
        XCTAssertEqual(gh.payload.username, "alice")
        XCTAssertEqual(gh.payload.password, "p@ss")
        XCTAssertEqual(gh.payload.notes, "my note")
        XCTAssertEqual(gh.payload.totp, "JBSWY3DPEHPK3PXP")

        XCTAssertEqual(r.candidates[1].payload.password, "pw,with,commas")   // quoted commas survived
        XCTAssertNil(r.candidates[1].payload.totp)                            // empty totp → nil
    }

    func test_bitwarden_chrome_safari_detected() throws {
        let bw = "folder,favorite,type,name,notes,login_uri,login_username,login_password,login_totp\n,,login,GH,n,https://github.com,alice,pw,\n"
        XCTAssertEqual(try CSVImport.parse(data: Data(bw.utf8)).format, "Bitwarden")

        let chrome = "name,url,username,password\nGitHub,https://github.com,alice,pw\n"
        XCTAssertEqual(try CSVImport.parse(data: Data(chrome.utf8)).format, "Chrome")

        let safari = "Title,URL,Username,Password,Notes,OTPAuth\nGitHub,https://github.com,alice,pw,,\n"
        XCTAssertEqual(try CSVImport.parse(data: Data(safari.utf8)).format, "Safari")
    }

    func test_malformedRows_skippedAndReported_notFatal() throws {
        let csv = """
        url,username,password,totp,extra,name,grouping,fav
        https://a.com,u,p,,,A,,0

        ,,,,,,,
        https://b.com,u2,p2,,,B,,0
        """
        let r = try CSVImport.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.candidates.count, 2, "valid rows still imported")
        XCTAssertEqual(r.skipped.count, 2, "blank + all-empty rows reported")
    }

    func test_unrecognizedFormat_throws() {
        let csv = "alpha,beta,gamma\n1,2,3\n"
        XCTAssertThrowsError(try CSVImport.parse(data: Data(csv.utf8))) { error in
            guard case ImportError.unrecognizedFormat(let supported) = error else { return XCTFail("wrong error") }
            XCTAssertTrue(supported.contains("LastPass"))
        }
    }

    func test_host_messyURL_reducesToRegistrableDomain() {
        // A full LastPass sign-in URL (query/fragment/messy) must reduce to the bare registrable domain.
        XCTAssertEqual(CSVImport.host(from: "https://www.amazon.co.uk/ap/signin?openid.return_to=https://www.amazon.co.uk/&x=y"), "amazon.co.uk")
        XCTAssertEqual(CSVImport.host(from: "www.github.com"), "github.com")
        XCTAssertEqual(CSVImport.host(from: "https://accounts.google.com/signin"), "google.com")
    }

    func test_headerOnly_throwsNoDataRows() {
        let csv = "url,username,password,totp,extra,name,grouping,fav\n"
        XCTAssertThrowsError(try CSVImport.parse(data: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? ImportError, .noDataRows)
        }
    }

    func test_notUTF8_throws() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01])
        XCTAssertThrowsError(try CSVImport.parse(data: bytes)) { error in
            XCTAssertEqual(error as? ImportError, .notUTF8)
        }
    }
}

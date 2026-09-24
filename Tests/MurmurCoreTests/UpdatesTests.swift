import XCTest
@testable import MurmurCore

final class UpdatesTests: XCTestCase {
    func release(tag: String = "v0.1.4", assets: String? = nil, extra: String = "") -> String {
        let list = assets ?? #"[{"name":"Murmur-\#(tag).zip","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/Murmur-\#(tag).zip"}]"#
        return #"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"Notes","assets":\#(list)\#(extra)}"#
    }

    func testVersions() {
        XCTAssertLessThan(ReleaseVersion("0.1.3")!, ReleaseVersion("v0.1.10")!)
        XCTAssertLessThan(ReleaseVersion("0.9")!, ReleaseVersion("1.0.0")!)
        XCTAssertEqual(ReleaseVersion("v1.2"), ReleaseVersion("1.2.0"))
        XCTAssertEqual(ReleaseVersion("0.2.0-beta")?.description, "0.2.0")
        XCTAssertNil(ReleaseVersion("latest"))
        XCTAssertNil(ReleaseVersion(""))
    }

    func testFindsTheNewestReleaseAndItsZip() async throws {
        let client = FakeHTTPClient { _ in (200, self.release()) }
        let latest = try await UpdateChecker(repository: "o/r", client: client).latest()
        XCTAssertEqual(latest.tag, "v0.1.4")
        XCTAssertEqual(latest.download.absoluteString, "https://github.com/o/r/releases/download/v0.1.4/Murmur-v0.1.4.zip")
        XCTAssertEqual(latest.notes, "Notes")
        XCTAssertEqual(client.requests.first?.url?.absoluteString, "https://api.github.com/repos/o/r/releases/latest")
        XCTAssertTrue(UpdateChecker.isNewer(latest, than: "0.1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latest, than: "0.1.4"))
        XCTAssertFalse(UpdateChecker.isNewer(latest, than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(latest, than: "dev"), "an unversioned build is never offered one")
    }

    func testPicksTheMurmurZipAmongOtherFiles() throws {
        let assets = #"[{"name":"notes.txt","browser_download_url":"https://github.com/o/r/releases/download/v0.1.4/notes.txt"},{"name":"Murmur-v0.1.4.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.1.4/m.zip"}]"#
        XCTAssertEqual(try UpdateChecker.parse(Data(release(assets: assets).utf8)).download.absoluteString,
                       "https://github.com/o/r/releases/download/v0.1.4/m.zip")
    }

    func testNothingToInstall() async {
        XCTAssertThrowsError(try UpdateChecker.parse(Data(release(assets: "[]").utf8))) {
            XCTAssertEqual($0 as? UpdateError, .noDownload("v0.1.4"))
        }
        XCTAssertThrowsError(try UpdateChecker.parse(Data(release(extra: #","prerelease":true"#).utf8))) {
            XCTAssertEqual($0 as? UpdateError, .noRelease)
        }
        do {
            _ = try await UpdateChecker(repository: "o/r", client: FakeHTTPClient { _ in (404, #"{"message":"Not Found"}"#) }).latest()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .noRelease)
        }
        do {
            _ = try await UpdateChecker(repository: "not a repo").latest()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .badRepository("not a repo"))
        }
    }

    func testConfig() throws {
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
        XCTAssertTrue(Config().updates.checkAutomatically)
        XCTAssertFalse(try Config.parse(#"{ "updates": { "checkAutomatically": false } }"#).updates.checkAutomatically)
    }
}

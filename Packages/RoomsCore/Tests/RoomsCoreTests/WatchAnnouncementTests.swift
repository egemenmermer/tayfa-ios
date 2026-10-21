import XCTest
@testable import RoomsCore

final class WatchAnnouncementTests: XCTestCase {
    func testRoundTripsTheDesktopPacket() throws {
        XCTAssertEqual(WatchAnnouncement.topic, "rooms-watch-v1")
        let watching = try JSONSerialization.jsonObject(with: WatchAnnouncement.payload(watching: "bob")) as? [String: String]
        XCTAssertEqual(watching, ["watching": "bob"])
        XCTAssertEqual(String(decoding: WatchAnnouncement.payload(watching: nil), as: UTF8.self), #"{"watching":null}"#)
        XCTAssertEqual(WatchAnnouncement.parse(WatchAnnouncement.payload(watching: "bob")), .some("bob"))
        XCTAssertEqual(WatchAnnouncement.parse(WatchAnnouncement.payload(watching: nil)), .some(nil))
    }

    func testIgnoresMalformedAnnouncements() {
        XCTAssertNil(WatchAnnouncement.parse(Data(#"{"watching":42}"#.utf8)))
        XCTAssertNil(WatchAnnouncement.parse(Data(#"{"other":"bob"}"#.utf8)))
        XCTAssertNil(WatchAnnouncement.parse(Data(#"{"watching":""}"#.utf8)))
        XCTAssertNil(WatchAnnouncement.parse(Data("not json".utf8)))
    }
}

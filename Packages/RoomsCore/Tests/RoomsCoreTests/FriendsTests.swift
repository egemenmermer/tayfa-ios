import XCTest
@testable import RoomsCore

final class FriendsTests: XCTestCase {
    private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    func testRelationsKeepKnownKindsAndValidIDs() {
        let me = json(#"{"relations":[{"_id":"a","status":"Friend"},{"_id":"b","status":"Incoming"},{"_id":"c","status":"Outgoing"},{"_id":"d","status":"Blocked"},{"_id":"e","status":"BlockedOther"},{"_id":"../x","status":"Friend"}]}"#)
        XCTAssertEqual(Friend.relations(me).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(Friend.relations(me).map(\.relationship), [.friend, .incoming, .outgoing, .blocked])
    }
    func testUserParsesHandleAndHidesInvisibleAsOffline() throws {
        let friend = try Friend(user: json(#"{"_id":"a","username":"osman","discriminator":"0420","display_name":"Osman","online":true,"status":{"presence":"Invisible"}}"#), relationship: .friend)
        XCTAssertEqual(friend.handle, "osman#0420"); XCTAssertEqual(friend.name, "Osman"); XCTAssertFalse(friend.online)
        let busy = try Friend(user: json(#"{"_id":"b","username":"ece","online":true,"status":{"presence":"Busy"}}"#), relationship: .incoming)
        XCTAssertTrue(busy.online); XCTAssertEqual(busy.presence, .busy)
    }
    func testHandleNeedsTheFourDigitTag() {
        XCTAssertEqual(Friend.validHandle(" osman#0420 "), "osman#0420")
        XCTAssertNil(Friend.validHandle("osman")); XCTAssertNil(Friend.validHandle("o#0420")); XCTAssertNil(Friend.validHandle("osman#42"))
    }
}

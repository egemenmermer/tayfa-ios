import XCTest
@testable import RoomsCore

final class MusicTests: XCTestCase {
    func testSnapshotDecodesDesktopContract() throws {
        let raw = #"{"channelId":"room","identity":"rooms-music-room","status":"playing","queue":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Song","durationSec":257}],"currentId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","positionSec":140.5,"error":null}"#
        let snapshot = try JSONDecoder().decode(MusicSnapshot.self, from: Data(raw.utf8))
        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.current?.title, "Song")
        XCTAssertEqual(snapshot.currentIndex, 0)
        XCTAssertNil(snapshot.matchCandidates)
        XCTAssertEqual(MusicClock.format(snapshot.positionSec), "2:20")
    }
    func testInputDistinguishesLinksFromSearch() {
        XCTAssertEqual(MusicInput("https://open.spotify.com/track/x"), .link("https://open.spotify.com/track/x"))
        XCTAssertEqual(MusicInput("  tarkan şımarık "), .search("tarkan şımarık"))
        XCTAssertEqual(MusicInput("http://insecure.test/a.mp3"), .invalid)
        XCTAssertEqual(MusicInput("www.youtube.com"), .invalid)
        XCTAssertEqual(MusicInput("a"), .invalid)
    }
    func testCommandsMatchDesktopPayloads() {
        XCTAssertEqual(MusicCommand.add(url: "https://x.test/a", playNow: true).json,
                       .object(["type": .string("add"), "url": .string("https://x.test/a"), "offerCandidates": .bool(true), "playNow": .bool(true)]))
        XCTAssertEqual(MusicCommand.seek(id: "t", positionSec: 9000).json,
                       .object(["type": .string("seek"), "id": .string("t"), "positionSec": .number(7200)]))
        XCTAssertEqual(MusicCommand.pause.json, .object(["type": .string("pause")]))
    }
    func testErrorCodesHaveTurkishMessages() {
        XCTAssertEqual(MusicError(code: "MUSIC_JOIN_FIRST").errorDescription, "Önce ses odasına katıl.")
        XCTAssertEqual(MusicError(code: "SOMETHING_NEW").errorDescription, "DJ sunucusu yanıt vermedi. Biraz sonra yeniden dene.")
    }
}

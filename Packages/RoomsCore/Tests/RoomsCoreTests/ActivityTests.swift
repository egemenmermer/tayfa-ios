import XCTest
@testable import RoomsCore

final class ActivityTests: XCTestCase {
    private let sample = #"""
    {"protocolVersion":1,"serverTimeMs":2000,"events":[],"room":{"roomId":"room","revision":4,
     "participants":[{"userId":"host","displayName":"Host","joinedAt":1,"lastSeenAt":1,"canControl":true,"canCreate":true},
                     {"userId":"ece","displayName":"Ece","joinedAt":2,"lastSeenAt":2,"canControl":true}],
     "primary":{"activity":"youtube","title":"Birlikte izle","hostUserId":"host","startedAt":1,"state":"live"},
     "timeline":{"playing":true,"positionSec":10,"rate":1,"effectiveServerTimeMs":1000,"epoch":2,"itemId":"a"},
     "queue":[{"id":"a","addedBy":"ece","media":{"kind":"youtube","videoId":"aaaaaaaaaaa","title":"İlk"}},
              {"id":"b","addedBy":"host","media":{"kind":"youtube","videoId":"bbbbbbbbbbb","title":"İkinci"}}],
     "polls":[],"whiteboard":[]}}
    """#
    func testDecodesTheDesktopSnapshotAndFollowsTheQueue() throws {
        let room = try JSONDecoder().decode(ActivityResponse.self, from: Data(sample.utf8)).room
        XCTAssertEqual(room.current?.id, "a"); XCTAssertEqual(room.next?.id, "b")
        XCTAssertTrue(room.directs("ece")); XCTAssertFalse(room.ends("ece")); XCTAssertTrue(room.ends("host"))
        XCTAssertNil(room.participant("me")); XCTAssertTrue(room.canStart("me"))
    }
    func testHostModeLimitsSteeringToHostAndInvitedPeople() throws {
        let hostMode = sample.replacingOccurrences(of: #""state":"live"}"#, with: #""state":"live","controlMode":"host","controllers":["can"]}"#)
        let room = try JSONDecoder().decode(ActivityResponse.self, from: Data(hostMode.utf8)).room
        XCTAssertFalse(room.directs("ece")); XCTAssertTrue(room.directs("host")); XCTAssertTrue(room.directs("can"))
    }
    func testExpectedPositionAdvancesOnlyWhilePlaying() throws {
        let timeline = try JSONDecoder().decode(ActivityResponse.self, from: Data(sample.utf8)).room.timeline
        XCTAssertEqual(WatchSync.expectedPosition(timeline, nowMs: 4000, serverOffsetMs: 0), 13, accuracy: 0.001)
        XCTAssertEqual(WatchSync.expectedPosition(timeline, nowMs: 3000, serverOffsetMs: 1000), 13, accuracy: 0.001)
        XCTAssertTrue(WatchSync.ranAhead(expected: 40, duration: 300)); XCTAssertFalse(WatchSync.ranAhead(expected: 290, duration: 300))
    }
    func testCommandsMatchTheProtocol() {
        let envelope = ActivityCommand.envelope(.add(itemID: "x1", videoID: "aaaaaaaaaaa", title: "  ", start: true), commandID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, expectedRevision: 7)
        XCTAssertEqual(envelope["protocolVersion"], .number(1)); XCTAssertEqual(envelope["expectedRevision"], .number(7))
        XCTAssertEqual(envelope["commandId"], .string("00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(envelope["command"]["type"], .string("queue.add"))
        XCTAssertEqual(envelope["command"]["media"]["title"], .string("YouTube videosu"))
        XCTAssertEqual(ActivityCommand.next(fromItemID: "a", skip: false).json["reason"], .string("ended"))
        XCTAssertEqual(ActivityCommand.playback(playing: true, positionSec: -4).json["positionSec"], .number(0))
    }
    func testYouTubeLinksAndIds() {
        XCTAssertEqual(YouTubeLink.videoID("https://youtu.be/dQw4w9WgXcQ?t=3"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.videoID("https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=x"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.videoID("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.videoID("dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(YouTubeLink.videoID("https://evil.example/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeLink.videoID("çok güzel şarkı"))
    }
    func testPollsCountVotesAndFollowTheCloseRule() throws {
        let withPoll = sample.replacingOccurrences(of: #""polls":[]"#, with: #""polls":[{"id":"p1","question":"Film mi dizi mi?","options":[{"id":"o1","label":"Film"},{"id":"o2","label":"Dizi"}],"votes":{"host":"o1","ece":"o1"},"createdBy":"ece","closed":false}]"#)
        let room = try JSONDecoder().decode(ActivityResponse.self, from: Data(withPoll.utf8)).room
        let poll = try XCTUnwrap(room.polls?.first)
        XCTAssertEqual(poll.count("o1"), 2); XCTAssertEqual(poll.count("o2"), 0)
        XCTAssertTrue(room.closes(poll, "ece")); XCTAssertTrue(room.closes(poll, "host"))
        let command = ActivityCommand.pollCreate(pollID: "p2", question: " Ne izleyelim? ", options: ["Film", " ", "Dizi"]).json
        XCTAssertEqual(command["type"], .string("poll.create")); XCTAssertEqual(command["question"], .string("Ne izleyelim?"))
        XCTAssertEqual(command["options"], .array([.object(["id": .string("o1"), "label": .string("Film")]), .object(["id": .string("o2"), "label": .string("Dizi")])]))
        XCTAssertEqual(ActivityCommand.pollVote(pollID: "p1", optionID: "o2").json["optionId"], .string("o2"))
    }
    func testErrorCodesUseDesktopText() {
        XCTAssertEqual(ActivityError(code: "SESSION_HOST_REQUIRED").localizedDescription, "Bunu yalnızca oturumun hostu yapabilir.")
    }
}

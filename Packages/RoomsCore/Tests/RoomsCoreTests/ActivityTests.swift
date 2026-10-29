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

final class ChatPollTests: XCTestCase {
    private let id = "Ab3dEf6hIj9k"
    private func room(polls: String, roomID: String = "chan") throws -> ActivityRoom {
        let json = #"""
        {"protocolVersion":1,"serverTimeMs":1,"room":{"roomId":"\#(roomID)","revision":9,
         "participants":[{"userId":"me","displayName":"Ben","joinedAt":1,"lastSeenAt":1,"canControl":false},
                         {"userId":"mod","displayName":"Mod","joinedAt":1,"lastSeenAt":1,"canControl":true}],
         "timeline":{"playing":false,"positionSec":0,"rate":1,"effectiveServerTimeMs":1,"epoch":0},
         "queue":[],"polls":\#(polls),"whiteboard":[]}}
        """#
        return try JSONDecoder().decode(ActivityResponse.self, from: Data(json.utf8)).room
    }
    private func poll(votes: String = #"{"me":"o2","a":"o2","b":"o1"}"#, closed: Bool = false, createdBy: String = "a") -> String {
        #"[{"id":"\#(id)","question":"Akşam ne yiyelim?","options":[{"id":"o1","label":"Pizza"},{"id":"o2","label":"Kebap"},{"id":"o3","label":"Çorba"}],"votes":\#(votes),"createdBy":"\#(createdBy)","closed":\#(closed)}]"#
    }

    func testParsesTheDesktopMessageForBothLanguages() {
        XCTAssertEqual(ChatPoll.pollID(in: "📊 Anket: Akşam ne yiyelim? — Tayfa’nın yeni sürümünde oy ver. #\(id)"), id)
        XCTAssertEqual(ChatPoll.pollID(in: "  📊 Poll: Dinner? — vote in the latest Tayfa. #\(id)\n"), id)
        XCTAssertEqual(ChatPoll.pollID(in: "📊 x #\(id)"), id)
        XCTAssertEqual(ChatPoll.fallback("📊 Anket: Akşam ne yiyelim? — Tayfa’nın yeni sürümünde oy ver. #\(id)"), "Anket: Akşam ne yiyelim? — Tayfa’nın yeni sürümünde oy ver.")
    }
    func testMalformedAndForeignMessagesStayPlainText() {
        for content in ["", "merhaba", "📊 Anket #\(id) ve devamı", "alıntı 📊 Anket: x #\(id)", "> 📊 Anket: x #\(id)",
                        "📊 Anket: x #Ab3dEf6hIj9", "📊 Anket: x #Ab3dEf6hIj9kL", "📊 Anket: x #Ab3dEf6hIj9_", "📊 Anket: x #Ab3dEf6hIj9ğ",
                        "📊 Anket: x Ab3dEf6hIj9k", "📊 Anket: x#\(id)", "📊 #\(id)", "📊  #\(id)", "📊Anket: x #\(id)", "📊 Anket: x #\(id) "
                            + "https://example.com", "https://static.klipy.com/a/b.gif"] {
            XCTAssertNil(ChatPoll.pollID(in: content), content)
        }
        XCTAssertEqual(ChatPoll.fallback("merhaba"), "merhaba")
    }
    func testBuildsVoteAndCloseRequestsForTheActivityProtocol() throws {
        let command = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let vote = try XCTUnwrap(ChatPoll.voteRequest(pollID: id, optionID: "o2", commandID: command, expectedRevision: 9))
        XCTAssertEqual(vote["protocolVersion"], .number(1)); XCTAssertEqual(vote["expectedRevision"], .number(9))
        XCTAssertEqual(vote["commandId"], .string("00000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(vote["command"]["type"], .string("poll.vote"))
        XCTAssertEqual(vote["command"]["pollId"], .string(id)); XCTAssertEqual(vote["command"]["optionId"], .string("o2"))
        XCTAssertEqual(ChatPoll.closeRequest(pollID: id, commandID: command, expectedRevision: 3)?["command"]["type"], .string("poll.close"))
        XCTAssertNil(ChatPoll.voteRequest(pollID: "short", optionID: "o1", commandID: command, expectedRevision: 1))
        XCTAssertNil(ChatPoll.voteRequest(pollID: id, optionID: "", commandID: command, expectedRevision: 1))
    }
    func testSummaryComesFromTheSnapshotOnly() throws {
        guard case .live(let summary) = ChatPollPhase.resolve(room: try room(polls: poll()), channelID: "chan", pollID: id, me: "me", failure: nil) else { return XCTFail("not live") }
        XCTAssertEqual(summary.question, "Akşam ne yiyelim?"); XCTAssertEqual(summary.voters, 3); XCTAssertEqual(summary.myVote, "o2")
        XCTAssertEqual(summary.options.map(\.count), [1, 2, 0]); XCTAssertEqual(summary.options.map(\.percent), [33, 67, 0])
        XCTAssertEqual(summary.options.map(\.mine), [false, true, false])
        XCTAssertFalse(summary.canClose); XCTAssertTrue(summary.canVote("o3")); XCTAssertFalse(summary.canVote("zzz"))
        XCTAssertEqual(summary.result, "Kebap · 2 oy")
    }
    func testClosedPollsAndCloseRights() throws {
        let closed = try room(polls: poll(closed: true))
        guard case .live(let summary) = ChatPollPhase.resolve(room: closed, channelID: "chan", pollID: id, me: "mod", failure: nil) else { return XCTFail("not live") }
        XCTAssertTrue(summary.closed); XCTAssertFalse(summary.canVote("o1")); XCTAssertFalse(summary.canClose)
        let open = try room(polls: poll(votes: "{}"))
        guard case .live(let moderated) = ChatPollPhase.resolve(room: open, channelID: "chan", pollID: id, me: "mod", failure: nil),
              case .live(let own) = ChatPollPhase.resolve(room: try room(polls: poll(createdBy: "me")), channelID: "chan", pollID: id, me: "me", failure: nil) else { return XCTFail("not live") }
        XCTAssertTrue(moderated.canClose); XCTAssertTrue(own.canClose)
        XCTAssertEqual(moderated.result, "Henüz oy yok"); XCTAssertEqual(moderated.options.map(\.percent), [0, 0, 0])
    }
    func testLoadingNotFoundAndErrorStates() throws {
        XCTAssertEqual(ChatPollPhase.resolve(room: nil, channelID: "chan", pollID: id, me: "me", failure: nil), .loading)
        XCTAssertEqual(ChatPollPhase.resolve(room: nil, channelID: "chan", pollID: id, me: "me", failure: "Bağlantı kurulamadı"), .failed("Bağlantı kurulamadı"))
        XCTAssertEqual(ChatPollPhase.resolve(room: try room(polls: "[]"), channelID: "chan", pollID: id, me: "me", failure: nil), .notFound)
        // A snapshot of another channel's room never shows this message's poll.
        XCTAssertEqual(ChatPollPhase.resolve(room: try room(polls: poll(), roomID: "other"), channelID: "chan", pollID: id, me: "me", failure: nil), .loading)
    }
}

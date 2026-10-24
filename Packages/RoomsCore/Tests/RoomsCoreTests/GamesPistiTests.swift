import XCTest
@testable import RoomsCore

/// Pişti view model: round-index vs seat-number mapping, sides in 2p/4p, playable cards, deal summary math,
/// match standings and the event tracker. Fixtures are hand-written from `packages/games/src/pisti.ts` + `match.ts`.
final class GamesPistiTests: XCTestCase {
    private func card(_ id: String, _ suit: String, _ rank: Int) -> String { #"{"id":"\#(id)","suit":"\#(suit)","rank":\#(rank)}"# }
    private func seat(_ number: Int, _ id: String) -> String {
        #"{"seat":\#(number),"userId":"\#(id)","name":"\#(id.capitalized)","bot":false,"chips":0,"connected":true}"#
    }
    private func list(_ values: [Int]) -> String { "[" + values.map(String.init).joined(separator: ",") + "]" }

    /// A Pişti table. `seats` lists (seat number, user) in JOIN order, deliberately not sorted.
    private func game(seats: [(Int, String)], view: String, turn: Int? = nil, legal: [String] = ["play"], series: String? = nil, status: String = "playing") throws -> GameState {
        let seatsJSON = seats.map { seat($0.0, $0.1) }.joined(separator: ",")
        let legalJSON = legal.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"""
        {"kind":"rooms-pisti-v1","ownerId":"ece","status":"\#(status)","seats":[\#(seatsJSON)],"turn":\#(turn.map(String.init) ?? "null"),
         "view":\#(view.dropLast()),"legalActions":[\#(legalJSON)],"turnDeadline":null,"capacity":\#(seats.count),"spectators":[],"watching":false,
         "spectatorAccess":true,"statistics":{}\#(series.map { ",\"series\":" + $0 } ?? "")},"history":[]}
        """#
        return try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
    }
    private func view2p(viewer: Int? = 0, turn: Int? = 0, tableTop: String? = nil, tableCount: Int = 0, hand: [String]? = nil, extra: String = "") -> String {
        let handJSON = hand.map { "[" + $0.joined(separator: ",") + "]" } ?? "null"
        return #"""
        {"seats":2,"teams":false,"target":151,"viewerSeat":\#(viewer.map(String.init) ?? "null"),"turn":\#(turn.map(String.init) ?? "null"),
         "hand":\#(handJSON),"handCounts":[4,4],"tableCount":\#(tableCount),"tableTop":\#(tableTop ?? "null"),"deckCount":36,
         "capturedCounts":[0,0],"pisti":[0,0],"jackPisti":[0,0],"lastPlay":null,"lastCapture":null,"result":null\#(extra)}
        """#
    }
    private func view4p(viewer: Int?, turn: Int? = 0) -> String {
        #"""
        {"seats":4,"teams":true,"target":101,"viewerSeat":\#(viewer.map(String.init) ?? "null"),"turn":\#(turn.map(String.init) ?? "null"),
         "hand":null,"handCounts":[4,4,3,4],"tableCount":0,"tableTop":null,"deckCount":20,
         "capturedCounts":[10,6],"pisti":[1,0],"jackPisti":[0,1],"lastPlay":null,"lastCapture":null,"result":null}
        """#
    }
    private func read(_ json: String) throws -> PistiView { try JSONDecoder().decode(PistiView.self, from: Data(json.utf8)) }

    // MARK: Side and seat mapping

    func testTwoPlayerSidesAndPositions() throws {
        let view = try read(view2p(viewer: 1))
        XCTAssertEqual(view.sideCount, 2); XCTAssertFalse(view.teams)
        XCTAssertEqual(view.side(ofRound: 0), 0); XCTAssertEqual(view.side(ofRound: 1), 1)
        XCTAssertEqual(view.members(ofSide: 1), [1]); XCTAssertEqual(view.viewerSide, 1)
        XCTAssertEqual(view.position(ofRound: 1), .bottom); XCTAssertEqual(view.position(ofRound: 0), .top)
        XCTAssertEqual(view.round(at: .bottom), 1); XCTAssertEqual(view.round(at: .top), 0); XCTAssertNil(view.round(at: .left))
        XCTAssertFalse(view.isPartner(round: 0))
    }
    func testFourPlayerPartnersSitAcrossAndTurnOrderRunsCounterClockwise() throws {
        let view = try read(view4p(viewer: 1))
        XCTAssertEqual(view.sideCount, 2); XCTAssertTrue(view.teams)
        XCTAssertEqual(view.members(ofSide: 0), [0, 2]); XCTAssertEqual(view.members(ofSide: 1), [1, 3])
        XCTAssertEqual(view.viewerSide, 1)
        // Viewer is round 1: bottom; next player (round 2) on the right; partner (round 3) across; round 0 on the left.
        XCTAssertEqual(view.position(ofRound: 1), .bottom); XCTAssertEqual(view.position(ofRound: 2), .right)
        XCTAssertEqual(view.position(ofRound: 3), .top); XCTAssertEqual(view.position(ofRound: 0), .left)
        XCTAssertTrue(view.isPartner(round: 3)); XCTAssertFalse(view.isPartner(round: 2)); XCTAssertFalse(view.isPartner(round: 1))
        XCTAssertEqual(view.round(at: .top), 3)
    }
    func testSpectatorSeesRoundZeroAtTheBottomAndSideZeroAsHome() throws {
        let view = try read(view4p(viewer: nil))
        XCTAssertNil(view.viewerSeat); XCTAssertNil(view.viewerSide); XCTAssertEqual(view.homeSide, 0)
        XCTAssertEqual(view.position(ofRound: 0), .bottom); XCTAssertEqual(view.position(ofRound: 2), .top)
        XCTAssertFalse(view.isPartner(round: 2)); XCTAssertFalse(view.viewerToPlay)
        XCTAssertTrue(view.handCards(canPlay: true).isEmpty)
    }
    func testRoundIndexFollowsSeatNumberNotJoinOrder() throws {
        // Seat numbers 3 and 1 joined in that order: round 0 is seat 1 (Can), round 1 is seat 3 (Ece).
        let state = try game(seats: [(3, "ece"), (1, "can")], view: view2p(viewer: 1, turn: 1), turn: 3)
        XCTAssertEqual(state.pistiSeat(round: 0)?.userId, "can"); XCTAssertEqual(state.pistiSeat(round: 1)?.userId, "ece")
        let view = try XCTUnwrap(state.pistiView)
        XCTAssertEqual(state.pistiName(round: view.viewerSeat ?? -1, me: "ece"), "Sen")
        XCTAssertEqual(state.pistiName(round: 0, me: "ece"), "Can")
        XCTAssertEqual(state.pistiName(round: 7, me: "ece"), "Oyuncu")
        XCTAssertEqual(state.pistiSideName(view, side: 0, me: "ece"), "Can")
        // The host's turn is a seat number (3); the view's turn is the round index (1): both point at Ece.
        XCTAssertTrue(state.isMyTurn("ece")); XCTAssertTrue(view.viewerToPlay)
    }
    func testFourPlayerSideNamesJoinPartners() throws {
        let state = try game(seats: [(0, "ece"), (1, "can"), (2, "mert"), (3, "deniz")], view: view4p(viewer: 0), turn: 0)
        let view = try XCTUnwrap(state.pistiView)
        XCTAssertEqual(state.pistiSideName(view, side: 0, me: "ece"), "Sen + Mert")
        XCTAssertEqual(state.pistiSideName(view, side: 1, me: "ece"), "Can + Deniz")
    }

    // MARK: Playable cards

    func testEveryCardIsPlayableOnYourTurnAndCapturingOnesAreFlagged() throws {
        let top = card("0-spades-7", "spades", 7)
        let view = try read(view2p(tableTop: top, tableCount: 3, hand: [card("a", "hearts", 7), card("b", "clubs", 11), card("c", "hearts", 9), card("d", "clubs", 2)]))
        let cards = view.handCards(canPlay: true)
        XCTAssertEqual(cards.map(\.playable), [true, true, true, true])
        XCTAssertEqual(cards.map(\.takes), [true, true, false, false])  // same rank, jack
        XCTAssertEqual(cards.map(\.id), ["a", "b", "c", "d"])
    }
    func testNothingIsPlayableOutOfTurnWhileBusyOrAfterTheDeal() throws {
        let hand = [card("a", "hearts", 7), card("b", "clubs", 11)]
        let top = card("t", "spades", 7)
        XCTAssertEqual(try read(view2p(turn: 1, tableTop: top, tableCount: 2, hand: hand)).handCards(canPlay: true).map(\.playable), [false, false])
        XCTAssertEqual(try read(view2p(turn: 1, tableTop: top, tableCount: 2, hand: hand)).handCards(canPlay: true).map(\.takes), [false, false])
        // The server does not list play (or a command is in flight): `canPlay` false.
        XCTAssertEqual(try read(view2p(turn: 0, tableTop: top, tableCount: 2, hand: hand)).handCards(canPlay: false).map(\.playable), [false, false])
        // Deal over: the view carries a result.
        let over = try read(view2p(turn: nil, hand: hand, extra: "").replacingOccurrences(of: #""result":null"#, with: #""result":{"points":[10,5],"winners":[0]}"#))
        XCTAssertNotNil(over.result); XCTAssertFalse(over.viewerToPlay)
        XCTAssertEqual(over.handCards(canPlay: true).map(\.playable), [false, false])
    }
    func testJackNeverCapturesAnEmptyTable() throws {
        let view = try read(view2p(tableTop: nil, tableCount: 0, hand: [card("b", "clubs", 11), card("c", "hearts", 9)]))
        XCTAssertEqual(view.handCards(canPlay: true).map(\.takes), [false, false])
        XCTAssertEqual(view.handCards(canPlay: true).map(\.playable), [true, true])
    }
    func testPlayabilityFollowsTheServersLegalActions() throws {
        let hand = [card("a", "hearts", 7)]
        let mine = try game(seats: [(0, "ece"), (1, "can")], view: view2p(hand: hand), turn: 0)
        XCTAssertTrue(mine.can("play"))
        let notListed = try game(seats: [(0, "ece"), (1, "can")], view: view2p(hand: hand), turn: 0, legal: [])
        XCTAssertFalse(notListed.can("play"))
        XCTAssertEqual(try XCTUnwrap(notListed.pistiView).handCards(canPlay: notListed.can("play")).map(\.playable), [false])
    }
    func testPlayCommandCarriesTheCardId() {
        XCTAssertEqual(ActivityCommand.game(GameMove.pistiPlay(cardID: "0-clubs-11")).json["action"], .string("play"))
        XCTAssertEqual(ActivityCommand.game(GameMove.pistiPlay(cardID: "0-clubs-11")).json["payload"]["cardId"], .string("0-clubs-11"))
    }

    // MARK: Summary points

    func testDealSummarySplitsBonusesFromCardPoints() throws {
        // Side 0: 30 cards, 2 pişti, one jack pişti, card points 7; side 1: 22 cards.
        let json = #"""
        {"seats":2,"teams":false,"target":151,"viewerSeat":0,"turn":null,"hand":[],"handCounts":[0,0],"tableCount":0,"tableTop":null,"deckCount":0,
         "capturedCounts":[30,22],"pisti":[2,0],"jackPisti":[1,0],"lastPlay":null,"lastCapture":null,"result":{"points":[50,9],"winners":[0]}}
        """#
        let view = try read(json)
        let rows = view.summary(points: try XCTUnwrap(view.result).points)
        XCTAssertEqual(rows[0], PistiSideSummary(side: 0, cards: 30, mostCards: true, pisti: 2, jackPisti: 1, cardPoints: 7, total: 50))  // 50 - 3 - 20 - 20
        XCTAssertEqual(rows[1], PistiSideSummary(side: 1, cards: 22, mostCards: false, pisti: 0, jackPisti: 0, cardPoints: 9, total: 9))
        XCTAssertEqual(PistiPoints.pisti, 10); XCTAssertEqual(PistiPoints.jackPisti, 20); XCTAssertEqual(PistiPoints.mostCards, 3)
    }
    func testNobodyGetsMostCardsOnATie() throws {
        let json = #"""
        {"seats":2,"teams":false,"target":151,"viewerSeat":0,"turn":null,"handCounts":[0,0],"tableCount":0,"deckCount":0,
         "capturedCounts":[26,26],"pisti":[0,0],"jackPisti":[0,0],"result":{"points":[6,6],"winners":[0,1]}}
        """#
        let view = try read(json)
        let rows = view.summary(points: [6, 6])
        XCTAssertEqual(rows.map(\.mostCards), [false, false]); XCTAssertEqual(rows.map(\.cardPoints), [6, 6])
    }
    func testTeamSummaryUsesTheTeamsPointsOnce() throws {
        let json = #"""
        {"seats":4,"teams":true,"target":101,"viewerSeat":2,"turn":null,"handCounts":[0,0,0,0],"tableCount":0,"deckCount":0,
         "capturedCounts":[28,24],"pisti":[1,0],"jackPisti":[0,0],"result":{"points":[21,8,21,8],"winners":[0,2]}}
        """#
        let view = try read(json)
        let rows = view.summary(points: [21, 8, 21, 8])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].total, 21); XCTAssertEqual(rows[0].mostCards, true); XCTAssertEqual(rows[0].cardPoints, 8)  // 21 - 3 - 10
        XCTAssertEqual(rows[1].total, 8); XCTAssertEqual(rows[1].cardPoints, 8)
        XCTAssertEqual(view.sidePoints([21, 8, 21, 8], side: 1), 8)
    }

    // MARK: Match standings

    func testStandingsReadTotalsPerSideAndMarkTheWinner() throws {
        let series = try JSONDecoder().decode(GameSeries.self, from: Data(#"{"totals":[104,38,104,38],"rounds":[{"points":[30,10,30,10],"winners":[0,2]}],"winners":[0,2]}"#.utf8))
        let view = try read(view4p(viewer: 2))
        let rows = view.standings(series: series)
        XCTAssertEqual(rows.map(\.total), [104, 38]); XCTAssertEqual(rows.map(\.own), [true, false]); XCTAssertEqual(rows.map(\.winner), [true, false])
        XCTAssertEqual(rows[0].progress, 1); XCTAssertEqual(rows[1].progress, 38.0 / 101, accuracy: 0.0001)
        XCTAssertEqual(view.standings(series: nil).map(\.total), [0, 0])
    }

    // MARK: Narration

    func testLastLineNamesTheCaptureAndThePlay() throws {
        let json = #"""
        {"seats":2,"teams":false,"target":151,"viewerSeat":0,"turn":1,"hand":[],"handCounts":[3,4],"tableCount":0,"tableTop":null,"deckCount":30,
         "capturedCounts":[5,0],"pisti":[0,0],"jackPisti":[0,0],
         "lastPlay":{"seq":4,"seat":0,"card":\#(card("x", "clubs", 11)),"captured":true},
         "lastCapture":{"seq":4,"seat":0,"count":5,"kind":"capture","card":\#(card("x", "clubs", 11))},"result":null}
        """#
        let state = try game(seats: [(0, "ece"), (1, "can")], view: json, turn: 1)
        let line = PistiNarration.lastLine(try XCTUnwrap(state.pistiView), game: state, me: "ece")
        XCTAssertEqual(line, "Sen valeyle 5 kart aldın · Sen Sinek Vale attın")
        let other = PistiNarration.lastLine(try XCTUnwrap(state.pistiView), game: state, me: "can")
        XCTAssertEqual(other, "Ece valeyle 5 kart aldı · Ece Sinek Vale attı")
        XCTAssertEqual(PistiNarration.captureLine(.init(kind: .pisti), name: "Ece", you: false), "Ece pişti yaptı · +10")
    }
    func testOpeningLineAndUnknownCaptureKind() throws {
        let state = try game(seats: [(0, "ece"), (1, "can")], view: view2p(viewer: 0, turn: 1), turn: 1)
        XCTAssertEqual(PistiNarration.lastLine(try XCTUnwrap(state.pistiView), game: state, me: "ece"), "Can açıyor")
        let capture = try JSONDecoder().decode(PistiCaptureRecord.self, from: Data(#"{"seq":1,"seat":0,"count":2,"kind":"future-kind","card":null}"#.utf8))
        XCTAssertEqual(capture.kind, .capture)
        XCTAssertEqual(PistiNarration.captureLine(capture, name: "Can", you: false), "Can 2 kart aldı")
    }
    func testCardNamesAreTurkish() {
        XCTAssertEqual(PlayingCard(id: "a", suit: .spades, rank: 14).pistiName, "Maça As")
        XCTAssertEqual(PlayingCard(id: "b", suit: .hearts, rank: 12).pistiName, "Kupa Kız")
        XCTAssertEqual(PlayingCard(id: "c", suit: .diamonds, rank: 10).pistiName, "Karo 10")
    }

    // MARK: Events

    private func dealJSON(seq: Int?, seat: Int = 1, kind: String? = nil, count: Int = 2, rank: Int = 7) -> String {
        let play = seq.map { #"{"seq":\#($0),"seat":\#(seat),"card":\#(card("p\($0)", "hearts", rank)),"captured":\#(kind != nil)}"# } ?? "null"
        let capture = seq.flatMap { s in kind.map { #"{"seq":\#(s),"seat":\#(seat),"count":\#(count),"kind":"\#($0)","card":\#(card("p\(s)", "hearts", rank))}"# } } ?? "null"
        return #"""
        {"seats":2,"teams":false,"target":151,"viewerSeat":0,"turn":0,"hand":[],"handCounts":[4,3],"tableCount":1,"deckCount":30,
         "capturedCounts":[0,0],"pisti":[0,0],"jackPisti":[0,0],"lastPlay":\#(play),"lastCapture":\#(capture),"result":null}
        """#
    }
    private func makeSeries(rounds: Int, previous: String? = nil, winners: [Int]? = nil) throws -> GameSeries {
        let list = Array(repeating: #"{"points":[10,5],"winners":[0]}"#, count: rounds).joined(separator: ",")
        let json = #"{"totals":[10,5],"rounds":[\#(list)],"winners":\#(winners.map { "[" + $0.map(String.init).joined(separator: ",") + "]" } ?? "null"),"previous":\#(previous ?? "null")}"#
        return try JSONDecoder().decode(GameSeries.self, from: Data(json.utf8))
    }

    func testTrackerIgnoresTheFirstViewThenReportsPlaysAndPisti() throws {
        var tracker = PistiEventTracker()
        XCTAssertNil(tracker.observe(try read(dealJSON(seq: 3)), series: try makeSeries(rounds: 0)))
        XCTAssertNil(tracker.observe(try read(dealJSON(seq: 3)), series: try makeSeries(rounds: 0)), "same view again")
        let play = try XCTUnwrap(tracker.observe(try read(dealJSON(seq: 4, seat: 1)), series: try makeSeries(rounds: 0)))
        XCTAssertEqual(play.kind, .play); XCTAssertEqual(play.round, 1); XCTAssertEqual(play.count, 0); XCTAssertFalse(play.dealEnded); XCTAssertFalse(play.isPisti)
        let capture = try XCTUnwrap(tracker.observe(try read(dealJSON(seq: 5, seat: 0, kind: "capture", count: 4)), series: try makeSeries(rounds: 0)))
        XCTAssertEqual(capture.kind, .capture); XCTAssertEqual(capture.count, 4)
        let pisti = try XCTUnwrap(tracker.observe(try read(dealJSON(seq: 6, seat: 1, kind: "pisti")), series: try makeSeries(rounds: 0)))
        XCTAssertTrue(pisti.isPisti); XCTAssertEqual(pisti.bonus, 10); XCTAssertEqual(pisti.round, 1)
        let vale = try XCTUnwrap(tracker.observe(try read(dealJSON(seq: 7, seat: 0, kind: "jack-pisti", rank: 11)), series: try makeSeries(rounds: 0)))
        XCTAssertEqual(vale.kind, .jackPisti); XCTAssertEqual(vale.bonus, 20)
    }
    func testTrackerReadsTheFinishedDealFromPreviousWhenTheNextOneIsDealt() throws {
        var tracker = PistiEventTracker()
        _ = tracker.observe(try read(dealJSON(seq: 30)), series: try makeSeries(rounds: 0))
        // The last play of the deal was a pişti by round 1; the new deal is already on the table with no play yet.
        let finished = dealJSON(seq: 31, seat: 1, kind: "pisti")
        let fresh = dealJSON(seq: nil)
        let event = try XCTUnwrap(tracker.observe(try read(fresh), series: try makeSeries(rounds: 1, previous: finished)))
        XCTAssertTrue(event.dealEnded); XCTAssertEqual(event.kind, .pisti); XCTAssertEqual(event.round, 1)
        // The new deal's first play restarts seq at 1 and is still seen as new.
        let next = try XCTUnwrap(tracker.observe(try read(dealJSON(seq: 1, seat: 0)), series: try makeSeries(rounds: 1, previous: finished)))
        XCTAssertEqual(next.kind, .play); XCTAssertFalse(next.dealEnded)
    }
    func testTrackerUsesTheCurrentViewWhenTheMatchEnds() throws {
        var tracker = PistiEventTracker()
        _ = tracker.observe(try read(dealJSON(seq: 30)), series: try makeSeries(rounds: 2))
        let last = dealJSON(seq: 31, seat: 0, kind: "remainder", count: 3)
        let event = try XCTUnwrap(tracker.observe(try read(last), series: try makeSeries(rounds: 3, previous: dealJSON(seq: 2), winners: [0])))
        XCTAssertTrue(event.dealEnded); XCTAssertEqual(event.kind, .remainder); XCTAssertEqual(event.count, 3)
    }

    // MARK: Protocol

    func testSeriesPreviousDecodesAsAPistiView() throws {
        let previous = dealJSON(seq: 9, seat: 0, kind: "capture")
        let series = try makeSeries(rounds: 1, previous: previous)
        let view = try XCTUnwrap(series.pistiPrevious)
        XCTAssertEqual(view.lastPlay?.seq, 9); XCTAssertEqual(view.lastCapture?.kind, .capture)
        XCTAssertNil(try makeSeries(rounds: 0).pistiPrevious)
    }
    func testBrokenViewNeverFailsTheTable() throws {
        let state = try game(seats: [(0, "ece"), (1, "can")], view: #"{"unrelated":true}"#)
        XCTAssertNil(state.pistiView)
    }
}
extension PistiCaptureRecord {
    fileprivate init(kind: PistiCaptureKind) {
        self = try! JSONDecoder().decode(PistiCaptureRecord.self, from: Data(#"{"seq":1,"seat":0,"count":2,"kind":"\#(kind.rawValue)"}"#.utf8))
    }
}

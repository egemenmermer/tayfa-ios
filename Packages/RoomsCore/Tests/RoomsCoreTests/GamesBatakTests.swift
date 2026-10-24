import XCTest
@testable import RoomsCore

/// Batak iPhone table model: soft view reading (trump null while bidding), seat layout (next player on the right,
/// 3-player Gömmeli), hand sorting, legal cards with K1, bid grid, trick hold/sweep timing, summary and score sheet.
/// Fixtures are hand-written from `batakView` (packages/games/src/batak-table.ts).
final class GamesBatakTests: XCTestCase {
    private func card(_ id: String) -> PlayingCard {
        let suit: CardSuit = switch id.first {
        case "S": .spades
        case "H": .hearts
        case "C": .clubs
        default: .diamonds
        }
        return PlayingCard(id: id, suit: suit, rank: Int(id.dropFirst())!)
    }
    private func cardJSON(_ id: String) -> String {
        let c = card(id)
        return #"{"id":"\#(id)","suit":"\#(c.suit.rawValue)","rank":\#(c.rank)}"#
    }
    private func playsJSON(_ plays: [(Int, String)]) -> String { "[" + plays.map { #"{"seat":\#($0.0),"card":\#(cardJSON($0.1))}"# }.joined(separator: ",") + "]" }

    private func round(variant: String = "ihaleli", stage: String = "playing", turn: Int? = 0, bid: Int = 7, bidder: Int = 0,
                       trump: String? = "hearts", trumpBroken: Bool = false, rules: String? = nil, viewer: Int = 0, hand: [String] = [],
                       players: Int = 4, trick: [(Int, String)] = [], completed: [([(Int, String)], Int)] = [], tricks: [Int]? = nil,
                       bids: [Int]? = nil, bidLog: String = "[]", scores: [Int] = []) throws -> BatakRound {
        let hands = (0..<players).map { seat in
            #"{"seat":\#(seat),"cards":[\#(seat == viewer ? hand.map(cardJSON).joined(separator: ",") : "")],"count":\#(seat == viewer ? hand.count : 13)}"#
        }.joined(separator: ",")
        let done = completed.map { #"{"plays":\#(playsJSON($0.0)),"winner":\#($0.1)}"# }.joined(separator: ",")
        let list = { (values: [Int]) in "[" + values.map(String.init).joined(separator: ",") + "]" }
        let json = #"""
        {"variant":"\#(variant)","stage":"\#(stage)","turn":\#(turn.map(String.init) ?? "null"),"bid":\#(bid),
         "bids":\#(list(bids ?? Array(repeating: 0, count: players))),"bidder":\#(bidder),"passed":[],"bidLog":\#(bidLog),
         "trump":\#(trump.map { "\"\($0)\"" } ?? "null"),"trumpBroken":\#(trumpBroken)\#(rules.map { ",\"rules\":" + $0 } ?? ""),
         "tricks":\#(list(tricks ?? Array(repeating: 0, count: players))),"trick":\#(playsJSON(trick)),"scores":\#(list(scores)),
         "winners":null,"completedTricks":[\#(done)],"hands":[\#(hands)],"buriedCount":0,"buried":[]}
        """#
        return try JSONDecoder().decode(BatakRound.self, from: Data(json.utf8))
    }

    // MARK: Reading

    func testReadsTheRoundWhileTrumpIsStillNull() throws {
        let log = #"[{"seat":1,"action":"bid","amount":6},{"seat":2,"action":"pass"}]"#
        let r = try round(stage: "bidding", turn: 3, bid: 6, bidder: 1, trump: nil, bidLog: log)
        XCTAssertEqual(r.stage, .bidding); XCTAssertNil(r.trump)
        XCTAssertEqual(r.bidLog, [BatakBidEntry(seat: 1, pass: false, amount: 6), BatakBidEntry(seat: 2, pass: true, amount: nil)])
        XCTAssertEqual(r.lastBid(of: 1), "6"); XCTAssertEqual(r.lastBid(of: 2), "Pas"); XCTAssertNil(r.lastBid(of: 0))
        XCTAssertTrue(r.rules.noTrumpLeadUntilBroken, "K1 defaults on when the view has no rules")
        XCTAssertFalse(r.showsTrumpBroken, "no K1 chip before the trump is known")
        // An older service sent "spades" during the auction: still hidden.
        XCTAssertNil(try round(stage: "trump", trump: "spades").trump)
        XCTAssertEqual(try round(variant: "koz-maca", stage: "bidding", trump: nil).trump, .spades)
    }
    func testGameStateReadsTheRoundThroughTheView() throws {
        let json = #"""
        {"kind":"batak","ownerId":"ece","status":"playing",
         "seats":[{"seat":3,"userId":"can","name":"Can","bot":false,"chips":0,"connected":true},
                  {"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":0,"connected":true},
                  {"seat":1,"userId":"bot-1","name":"Bot","bot":true,"chips":0,"connected":true}],"turn":1,
         "view":{"variant":"gommeli","stage":"bidding","turn":1,"bid":0,"bids":[0,0,0],"bidder":1,"passed":[],"bidLog":[],"trump":null,
           "trumpBroken":false,"rules":{"noTrumpLeadUntilBroken":false},"tricks":[0,0,0],"trick":[],"scores":[],"winners":null,
           "completedTricks":[],"hands":[{"seat":0,"cards":[],"count":16},{"seat":1,"cards":[],"count":16},{"seat":2,"cards":[],"count":16}],
           "buriedCount":4,"buried":[],"legalActions":["bid","pass"],"spectators":[],"watching":false,"spectatorAccess":true,"statistics":{}},
         "history":[]}
        """#
        let state = try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
        XCTAssertNil(state.batak, "the strict RoomsCore view fails on trump null; that is why BatakRound exists")
        let r = try XCTUnwrap(state.batakRound)
        XCTAssertEqual(r.variant, .gommeli); XCTAssertEqual(r.playerCount(seated: 3), 3); XCTAssertEqual(r.buriedCount, 4)
        XCTAssertFalse(r.rules.noTrumpLeadUntilBroken)
        XCTAssertEqual(state.position(of: "can"), 2, "rounds index the seats sorted by number, not join order")
    }

    // MARK: Layout

    func testNextPlayerSitsOnTheRightInFourHanded() {
        // Viewer at round 2: round 3 plays next (right), then 0 (top), then 1 (left).
        XCTAssertEqual(BatakLayout.spot(of: 2, viewer: 2, players: 4), .bottom)
        XCTAssertEqual(BatakLayout.spot(of: 3, viewer: 2, players: 4), .right)
        XCTAssertEqual(BatakLayout.spot(of: 0, viewer: 2, players: 4), .top)
        XCTAssertEqual(BatakLayout.spot(of: 1, viewer: 2, players: 4), .left)
        XCTAssertEqual(BatakLayout.round(at: .right, viewer: 0, players: 4), 1)
        XCTAssertNil(BatakLayout.round(at: .topRight, viewer: 0, players: 4))
    }
    func testThreeHandedGommeliUsesTheTopCorners() {
        XCTAssertEqual(BatakLayout.spot(of: 1, viewer: 1, players: 3), .bottom)
        XCTAssertEqual(BatakLayout.spot(of: 2, viewer: 1, players: 3), .topRight, "next player: right-hand corner")
        XCTAssertEqual(BatakLayout.spot(of: 0, viewer: 1, players: 3), .topLeft)
        XCTAssertNil(BatakLayout.round(at: .right, viewer: 1, players: 3)); XCTAssertNil(BatakLayout.round(at: .top, viewer: 1, players: 3))
    }
    func testSpectatorSeesRoundZeroAtTheBottom() {
        XCTAssertEqual(BatakLayout.spot(of: 0, viewer: nil, players: 4), .bottom)
        XCTAssertEqual(BatakLayout.spot(of: 1, viewer: nil, players: 4), .right)
    }

    // MARK: Hand sorting

    func testHandAlternatesColoursAcesFirstTrumpLast() {
        let hand = ["D3", "S14", "H10", "C2", "S5", "H14", "D12", "C13"].map(card)
        XCTAssertEqual(BatakLayout.sortHand(hand, trump: nil).map(\.id), ["S14", "S5", "H14", "H10", "C13", "C2", "D12", "D3"])
        // Trump hearts goes rightmost; the rest keeps black/red alternation (♣ ♦ ♠ ♥).
        XCTAssertEqual(BatakLayout.sortHand(hand, trump: .hearts).map(\.id), ["C13", "C2", "D12", "D3", "S14", "S5", "H14", "H10"])
    }
    func testMissingSuitPicksTheOrderWithFewestSameColourNeighbours() {
        // No clubs, trump diamonds: ♠ ♥ then ♦ would put two reds together; ♥ ♠ ♦ alternates.
        let hand = ["S9", "H9", "D9"].map(card)
        XCTAssertEqual(BatakLayout.sortHand(hand, trump: .diamonds).map(\.id), ["H9", "S9", "D9"])
        XCTAssertEqual(BatakLayout.sortHand([], trump: .spades), [])
    }

    // MARK: Legal cards and K1

    func testLeadKeepsTrumpClosedUntilBroken() throws {
        let hand = ["H14", "S5", "C3"]
        XCTAssertEqual(try round(trump: "hearts", hand: hand).legalCardIDs(viewer: 0), ["S5", "C3"])
        XCTAssertEqual(try round(trump: "hearts", trumpBroken: true, hand: hand).legalCardIDs(viewer: 0), ["H14", "S5", "C3"])
        XCTAssertEqual(try round(trump: "hearts", rules: #"{"noTrumpLeadUntilBroken":false}"#, hand: hand).legalCardIDs(viewer: 0), ["H14", "S5", "C3"])
        XCTAssertEqual(try round(trump: "hearts", hand: ["H14", "H2"]).legalCardIDs(viewer: 0), ["H14", "H2"], "only trumps left")
        XCTAssertTrue(try round(trump: "hearts", trumpBroken: true, hand: hand).showsTrumpBroken)
    }
    func testFollowHeadAndTrumpRules() throws {
        // Must follow and beat the highest lead-suit card.
        XCTAssertEqual(try round(hand: ["S14", "S3", "H2"], trick: [(3, "S10")]).legalCardIDs(viewer: 0), ["S14"])
        // Someone trumped: following is enough.
        XCTAssertEqual(try round(hand: ["S14", "S3"], trick: [(2, "S10"), (3, "H2")]).legalCardIDs(viewer: 0), ["S14", "S3"])
        // Void: must trump, over the highest trump if possible.
        XCTAssertEqual(try round(hand: ["H3", "H12", "C5"], trick: [(2, "S10"), (3, "H10")]).legalCardIDs(viewer: 0), ["H12"])
        // Not my turn, or no trump yet: nothing playable.
        XCTAssertEqual(try round(turn: 1, hand: ["S3"]).legalCardIDs(viewer: 0), [])
        XCTAssertEqual(try round(stage: "trump", hand: ["S3"]).legalCardIDs(viewer: 0), [])
        XCTAssertEqual(try round(hand: ["S3"]).legalCardIDs(viewer: nil), [])
    }

    // MARK: Auction

    func testBidGridStartsAtTheMinimumLegalBid() throws {
        XCTAssertEqual(try round(stage: "bidding", bid: 0, trump: nil).bidOptions, Array(5...13), "İhaleli opens at 5")
        XCTAssertEqual(try round(stage: "bidding", bid: 9, trump: nil).bidOptions, Array(10...13))
        XCTAssertEqual(try round(variant: "esli", stage: "bidding", bid: 0, trump: nil).bidOptions, Array(8...13))
        XCTAssertEqual(try round(variant: "gommeli", stage: "bidding", bid: 12, trump: nil, players: 3).bidOptions, Array(13...16))
        XCTAssertEqual(try round(stage: "bidding", bid: 13, trump: nil).bidOptions, [], "nothing above the maximum, no trap")
        XCTAssertEqual(try round(variant: "koz-maca", stage: "bidding", bid: 0, trump: nil).bidOptions, Array(1...13))
    }
    func testKozMacaPassReadsAsOne() throws {
        let r = try round(variant: "koz-maca", stage: "bidding", trump: nil, bidLog: #"[{"seat":0,"action":"pass","amount":1}]"#)
        XCTAssertEqual(r.lastBid(of: 0), "1"); XCTAssertEqual(r.bidLine(r.bidLog[0], name: "Ece"), "Ece 1 el dedi")
    }

    // MARK: Trick hold and sweep

    func testCompletedTrickHoldsThenSweepsThenClears() throws {
        var tracker = BatakTrickTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(tracker.observe(try round(trick: [(0, "S2"), (1, "S5"), (2, "S9")]), deal: 0, now: t0), "first view is the baseline")
        let done = try round(turn: 3, completed: [([(0, "S2"), (1, "S5"), (2, "S9"), (3, "S14")], 3)])
        XCTAssertTrue(tracker.observe(done, deal: 0, now: t0))
        XCTAssertEqual(tracker.held?.winner, 3); XCTAssertEqual(tracker.held?.plays.count, 4)
        XCTAssertEqual(tracker.phase(at: t0.addingTimeInterval(1.19)), .holding)
        XCTAssertEqual(tracker.nextChange(after: t0), t0.addingTimeInterval(1.2))
        XCTAssertEqual(tracker.phase(at: t0.addingTimeInterval(1.3)), .sweeping)
        XCTAssertNil(tracker.phase(at: t0.addingTimeInterval(1.56)))
        tracker.expire(at: t0.addingTimeInterval(1.6)); XCTAssertNil(tracker.held)
    }
    func testNextLeadCutsTheHoldShort() throws {
        var tracker = BatakTrickTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.observe(try round(), deal: 0, now: t0)
        let plays = [(0, "S2"), (1, "S5"), (2, "S9"), (3, "S14")]
        tracker.observe(try round(turn: 3, completed: [(plays, 3)]), deal: 0, now: t0)
        tracker.observe(try round(turn: 0, trick: [(3, "C4")], completed: [(plays, 3)]), deal: 0, now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(tracker.phase(at: t0.addingTimeInterval(0.41)), .sweeping)
        // Completion and the next lead in the same update: straight to the sweep.
        var other = BatakTrickTracker()
        other.observe(try round(), deal: 0, now: t0)
        other.observe(try round(turn: 0, trick: [(3, "C4")], completed: [(plays, 3)]), deal: 0, now: t0)
        XCTAssertEqual(other.phase(at: t0), .sweeping)
    }
    func testFreshDealClearsTheHeldTrick() throws {
        var tracker = BatakTrickTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        let plays = [(0, "S2"), (1, "S5"), (2, "S9"), (3, "S14")]
        tracker.observe(try round(completed: [(plays, 3)]), deal: 0, now: t0)
        tracker.observe(try round(completed: [(plays, 3), (plays, 1)]), deal: 0, now: t0)
        XCTAssertNotNil(tracker.held)
        XCTAssertFalse(tracker.observe(try round(stage: "bidding", trump: nil), deal: 1, now: t0.addingTimeInterval(0.2)))
        XCTAssertNil(tracker.held)
    }

    // MARK: Summary and sheet

    func testSummaryMarksAndTeamTricks() throws {
        let made = try round(stage: "ended", turn: nil, bid: 7, bidder: 1, tricks: [2, 7, 4, 0], scores: [2, 7, 4, -7])
        let rows = made.summary(players: 4)
        XCTAssertEqual(rows[1].mark, .made); XCTAssertEqual(rows[1].contract, 7); XCTAssertNil(rows[3].mark, "no batak penalty by default")
        let penalty = try round(stage: "ended", turn: nil, bid: 9, bidder: 1, rules: #"{"defenderBatakPenalty":true}"#, tricks: [2, 7, 4, 0])
        XCTAssertEqual(penalty.summary(players: 4)[1].mark, .set); XCTAssertEqual(penalty.summary(players: 4)[3].mark, .batak)
        // Eşli: the team's tricks count (rounds 1+3 vs 0+2).
        let esli = try round(variant: "esli", stage: "ended", turn: nil, bid: 8, bidder: 3, tricks: [1, 5, 4, 3])
        XCTAssertEqual(esli.taken(by: 1), 8); XCTAssertEqual(esli.summary(players: 4)[1].mark, .made); XCTAssertNil(esli.summary(players: 4)[0].contract)
        XCTAssertEqual(BatakSummaryMark.made.title, "Çıktı"); XCTAssertEqual(BatakSummaryMark.set.title, "Battı")
        // Koz Maça: everyone's call is their contract.
        let koz = try round(variant: "koz-maca", stage: "ended", turn: nil, trump: "spades", tricks: [3, 2, 4, 4], bids: [3, 3, 4, 1])
        XCTAssertEqual(koz.summary(players: 4).map(\.mark), [.made, .set, .made, .made])
    }
    func testScoreSheetSumsHistoryRows() throws {
        let entries = try JSONDecoder().decode([GameHistoryEntry].self, from: Data(#"""
        [{"hand":1,"endedAt":1,"result":{"scores":[5,-7,3,1]}},{"hand":2,"endedAt":2,"result":{"scores":[-6,2,4,0]}},
         {"hand":3,"endedAt":3,"result":{"winner":"x"}}]
        """#.utf8))
        let sheet = BatakScoreSheet(history: entries, players: 4)
        XCTAssertEqual(sheet.rows, [[5, -7, 3, 1], [-6, 2, 4, 0]]); XCTAssertEqual(sheet.totals, [-1, -5, 7, 1])
    }
}

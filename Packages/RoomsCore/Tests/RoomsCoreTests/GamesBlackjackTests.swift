import XCTest
@testable import RoomsCore

/// iPhone Blackjack table model; fixtures follow `blackjackTableView` + `gameView` in the desktop repository.
final class GamesBlackjackTests: XCTestCase {
    private func card(_ rank: Int, _ suit: CardSuit = .spades) -> PlayingCard { PlayingCard(id: "\(rank)-\(suit.rawValue)", suit: suit, rank: rank) }
    private func cardJSON(_ rank: Int, _ suit: String = "spades") -> String { #"{"id":"\#(rank)-\#(suit)","suit":"\#(suit)","rank":\#(rank)}"# }

    private func state(status: String = "playing", turn: String = "0", seats: String? = nil, view: String, legal: [String] = [], history: String = "[]") throws -> GameState {
        let seatList = seats ?? #"""
        [{"seat":2,"userId":"can","name":"Can","bot":false,"chips":980,"connected":true,"pendingNextHand":false},
         {"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":990,"connected":true,"pendingNextHand":false}]
        """#
        let legalJSON = "[" + legal.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = #"""
        {"kind":"blackjack","ownerId":"ece","status":"\#(status)","seats":\#(seatList),"turn":\#(turn),
         "view":{\#(view),"tableName":"blackjack","spectators":[],"watching":false,"spectatorAccess":true,
                 "legalActions":\#(legalJSON),"turnDeadline":47000,"capacity":7,"statistics":{}},
         "history":\#(history)}
        """#
        return try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
    }
    private func hand(_ cards: [String], bet: Int = 10, state: String = "playing", split: Bool = false, extra: String = "") -> String {
        #"{"cards":[\#(cards.joined(separator: ","))],"bet":\#(bet),"state":"\#(state)","split":\#(split)\#(extra)}"#
    }
    private func player(_ id: String, credits: Int = 990, bet: Int = 10, hands: [String], active: Int = 0, extra: String = "") -> String {
        #"{"userId":"\#(id)","credits":\#(credits),"bet":\#(bet),"activeHand":\#(active),"hands":[\#(hands.joined(separator: ","))]\#(extra)}"#
    }

    // MARK: Totals

    func testSoftTotalTextShowsBothCountsWhileTheHandIsOpen() {
        XCTAssertEqual(BlackjackTotal.label([card(14), card(6)], settled: false), "7/17")
        XCTAssertEqual(BlackjackTotal.label([card(14), card(6)], settled: true), "17")
        XCTAssertEqual(BlackjackTotal.label([card(14), card(13)], settled: false), "21")
        XCTAssertEqual(BlackjackTotal.label([card(14), card(14)], settled: false), "2/12")
        XCTAssertEqual(BlackjackTotal.label([card(14), card(6), card(13)], settled: false), "17")
        XCTAssertEqual(BlackjackTotal.label([card(10), card(9)], settled: false), "19")
        XCTAssertEqual(BlackjackTotal.label([], settled: false), "")
        XCTAssertEqual(BlackjackTotal([card(14), card(14), card(9)]).best, 21)
        XCTAssertEqual(BlackjackTotal([card(13), card(12), card(5)]).best, 25)
    }

    // MARK: Chips

    func testChipBreakdownUsesTheLargestDenominationsFirst() {
        XCTAssertEqual(BlackjackChips.stack(236), [100, 100, 25, 5, 5, 1])
        XCTAssertEqual(BlackjackChips.stack(0), [])
        XCTAssertEqual(BlackjackChips.stack(-5), [])
        let grouped = BlackjackChips.breakdown(1135)
        XCTAssertEqual(grouped.map(\.value), [500, 100, 25, 5])
        XCTAssertEqual(grouped.map(\.count), [2, 1, 1, 2])
        XCTAssertEqual(BlackjackChips.maxBet(37), 36)
        XCTAssertEqual(BlackjackChips.maxBet(1), 0)
        XCTAssertTrue(BlackjackChips.canAdd(20, to: 10, chips: 30))
        XCTAssertFalse(BlackjackChips.canAdd(20, to: 10, chips: 29))
        XCTAssertTrue(BlackjackChips.betButtons.allSatisfy { $0 % 2 == 0 })
    }

    // MARK: Controls

    private var playingView: String {
        let ece = player("ece", hands: [hand([cardJSON(8), cardJSON(8, "hearts")])])
        let can = player("can", credits: 980, bet: 20, hands: [hand([cardJSON(10), cardJSON(9)], bet: 20)])
        return #""revision":3,"dealer":[\#(cardJSON(10, "clubs"))],"dealerHiddenCount":1,"players":[\#(ece),\#(can)],"turn":0,"insurancePending":false,"rules":{"insurance":true,"surrender":true},"finished":false,"results":[]"#
    }

    func testPlayButtonsFollowLegalActions() throws {
        let game = try state(view: playingView, legal: ["hit", "stand", "surrender", "double", "split"])
        let round = try XCTUnwrap(game.blackjackRound)
        XCTAssertEqual(round.actingUserId, "ece"); XCTAssertTrue(round.rules.surrender)
        var controls = BlackjackControls(game: game, round: round, me: "ece", busy: false)
        XCTAssertTrue(controls.showPlay)
        XCTAssertEqual([controls.hit, controls.stand, controls.double, controls.split, controls.surrender], [true, true, true, true, true])
        XCTAssertEqual(controls.insurance, .none); XCTAssertFalse(controls.betting); XCTAssertFalse(controls.rebuy)

        // Only what the server lists; busy disables everything.
        let limited = try state(view: playingView, legal: ["hit", "stand"])
        controls = BlackjackControls(game: limited, round: limited.blackjackRound, me: "ece", busy: false)
        XCTAssertEqual([controls.hit, controls.stand, controls.double, controls.split, controls.surrender], [true, true, false, false, false])
        controls = BlackjackControls(game: limited, round: limited.blackjackRound, me: "ece", busy: true)
        XCTAssertFalse(controls.hit || controls.stand)

        // Someone else's turn: the row is visible but dead; a spectator gets no row.
        let other = try state(turn: "2", view: playingView.replacingOccurrences(of: #""turn":0"#, with: #""turn":1"#))
        controls = BlackjackControls(game: other, round: other.blackjackRound, me: "ece", busy: false)
        XCTAssertTrue(controls.showPlay); XCTAssertFalse(controls.hit || controls.stand)
        controls = BlackjackControls(game: other, round: other.blackjackRound, me: "zeynep", busy: false)
        XCTAssertFalse(controls.showPlay)
    }

    func testInsurancePromptState() throws {
        let view = playingView
            .replacingOccurrences(of: #""insurancePending":false"#, with: #""insurancePending":true"#)
            .replacingOccurrences(of: cardJSON(10, "clubs"), with: cardJSON(14, "clubs"))
        let game = try state(view: view, legal: ["insurance", "decline-insurance"])
        let round = try XCTUnwrap(game.blackjackRound)
        XCTAssertFalse(round.isActive("ece", hand: 0), "no hand is highlighted while insurance is asked")
        var controls = BlackjackControls(game: game, round: round, me: "ece", busy: false)
        XCTAssertEqual(controls.insurance, .mine(canTake: true, stake: 5))
        XCTAssertFalse(controls.showPlay); XCTAssertFalse(controls.hit)

        let broke = try state(view: view, legal: ["decline-insurance"])
        controls = BlackjackControls(game: broke, round: broke.blackjackRound, me: "ece", busy: false)
        XCTAssertEqual(controls.insurance, .mine(canTake: false, stake: 5))

        controls = BlackjackControls(game: game, round: round, me: "can", busy: false)
        XCTAssertEqual(controls.insurance, .waiting(name: "Ece"))

        // Older services: no insurance keys at all.
        let old = try state(view: playingView.replacingOccurrences(of: #","insurancePending":false,"rules":{"insurance":true,"surrender":true}"#, with: ""), legal: ["hit"])
        let oldRound = try XCTUnwrap(old.blackjackRound)
        XCTAssertFalse(oldRound.insurancePending); XCTAssertEqual(oldRound.rules, .standard)
        XCTAssertEqual(BlackjackControls(game: old, round: oldRound, me: "ece", busy: false).insurance, .none)
    }

    func testBetPanelAndRebuyBetweenHands() throws {
        let finished = playingView.replacingOccurrences(of: #""finished":false"#, with: #""finished":true"#).replacingOccurrences(of: #""turn":0"#, with: #""turn":null"#)
        let seats = #"""
        [{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1,"connected":true,"pendingNextHand":false},
         {"seat":2,"userId":"can","name":"Can","bot":false,"chips":980,"connected":true,"pendingNextHand":false}]
        """#
        let game = try state(status: "finished", turn: "null", seats: seats, view: finished, legal: ["start"])
        let ece = BlackjackControls(game: game, round: game.blackjackRound, me: "ece", busy: false)
        XCTAssertTrue(ece.rebuy); XCTAssertFalse(ece.betting); XCTAssertFalse(ece.showPlay)
        let can = BlackjackControls(game: game, round: game.blackjackRound, me: "can", busy: false)
        XCTAssertTrue(can.betting); XCTAssertFalse(can.rebuy)
        let watcher = BlackjackControls(game: game, round: game.blackjackRound, me: "zeynep", busy: false)
        XCTAssertFalse(watcher.betting || watcher.rebuy)
        // No rebuy or bet change while a hand runs (CHIP_CHANGE_DURING_HAND / INVALID_VIRTUAL_BET).
        let live = try state(seats: seats, view: playingView, legal: ["hit"])
        let during = BlackjackControls(game: live, round: live.blackjackRound, me: "ece", busy: false)
        XCTAssertFalse(during.rebuy || during.betting)
        XCTAssertEqual(GameCommand.sit(seat: 0, buyIn: BlackjackControls.rebuyAmount).json,
                       .object(["type": .string("game.sit"), "seat": .number(0), "buyIn": .number(1000)]))
    }

    // MARK: Round

    func testSplitHandsActiveHighlightBadgesAndNet() throws {
        let split = player("ece", credits: 960, bet: 10, hands: [
            hand([cardJSON(8), cardJSON(3)], bet: 20, state: "stood", split: true),
            hand([cardJSON(8, "hearts"), cardJSON(13)], bet: 10, state: "playing", split: true),
        ], active: 1, extra: #","insurance":0,"insuranceDecided":true"#)
        let view = #""revision":7,"dealer":[\#(cardJSON(9, "clubs"))],"dealerHiddenCount":1,"players":[\#(split)],"turn":0,"insurancePending":false,"rules":{"insurance":true,"surrender":false},"finished":false,"results":[]"#
        let round = try XCTUnwrap(try state(view: view, legal: ["hit", "stand"]).blackjackRound)
        XCTAssertTrue(round.isActive("ece", hand: 1)); XCTAssertFalse(round.isActive("ece", hand: 0))
        XCTAssertEqual(round.player("ece")?.staked, 30)
        XCTAssertNil(round.net("ece"), "no net before the round ends")

        let settled = BlackjackRound(dealer: [card(9, .clubs), card(10, .clubs)], players: [
            BlackjackRoundPlayer(userId: "ece", credits: 960, bet: 10, hands: [
                BlackjackRoundHand(cards: [card(8), card(3), card(10)], bet: 20, state: "stood", split: true),
                BlackjackRoundHand(cards: [card(8, .hearts), card(13), card(5)], bet: 10, state: "bust", split: true),
            ], insurance: 0, insuranceDecided: true),
            BlackjackRoundPlayer(userId: "can", credits: 970, bet: 20, hands: [BlackjackRoundHand(cards: [card(14), card(13)], bet: 20, state: "stood")],
                                 insurance: 10, insuranceDecided: true, insuranceReturned: 0),
        ], finished: true, results: [
            BlackjackResult(userId: "ece", hand: 0, outcome: "win", returned: 40),
            BlackjackResult(userId: "ece", hand: 1, outcome: "lose", returned: 0),
            BlackjackResult(userId: "can", hand: 0, outcome: "blackjack", returned: 50),
        ])
        XCTAssertEqual(settled.badge("ece", hand: 0), .win)
        XCTAssertEqual(settled.badge("ece", hand: 1), .bust)
        XCTAssertEqual(settled.badge("can", hand: 0), .blackjack)
        XCTAssertEqual(settled.net("ece"), 10)
        XCTAssertEqual(settled.net("can"), 20)
        XCTAssertNil(settled.actingUserId)
        XCTAssertEqual(settled.dealerTotalLabel, "19")

        let game = try state(status: "finished", turn: "null", view: view, legal: ["start"])
        let lines = BlackjackSummaryLine.lines(game, round: settled, me: "ece")
        XCTAssertEqual(lines.map(\.userId), ["ece", "can"], "seat order (Ece sits at 0)")
        XCTAssertEqual(lines.map(\.name), ["Sen", "Can"])
        XCTAssertEqual(lines.map(\.netText), ["+10", "+20"])
        XCTAssertEqual(BlackjackSummaryLine(userId: "x", name: "X", net: -10, badges: []).netText, "−10")
    }

    func testLayoutOrderAndSittingOut() throws {
        let seats = #"""
        [{"seat":4,"userId":"bot-1","name":"Tayfa Bot","bot":true,"chips":1000,"connected":true,"pendingNextHand":false},
         {"seat":2,"userId":"can","name":"Can","bot":false,"chips":980,"connected":true,"pendingNextHand":false},
         {"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":990,"connected":true,"pendingNextHand":false}]
        """#
        let game = try state(seats: seats, view: playingView, legal: [])
        XCTAssertEqual(BlackjackLayout.others(game, me: "ece").map(\.userId), ["can", "bot-1"])
        XCTAssertEqual(BlackjackLayout.others(game, me: "zeynep").map(\.userId), ["ece", "can", "bot-1"])
        XCTAssertTrue(BlackjackLayout.sittingOut(game, round: game.blackjackRound, userID: "bot-1"))
        XCTAssertFalse(BlackjackLayout.sittingOut(game, round: game.blackjackRound, userID: "can"))
    }

    /// The dealer row keeps its identity from the deal through the reveal (the hole card turns over) even though the
    /// history entry arrives in the same update that finishes the round, and even once the history list is capped.
    func testHandNumberHoldsFromDealThroughReveal() throws {
        let entry = { (hand: Int) in #"{"hand":\#(hand),"endedAt":1,"result":{}}"# }
        let playing = try state(view: playingView, legal: ["hit"], history: "[\(entry(6)), \(entry(7))]")
        let finished = try state(status: "finished", turn: "null", view: playingView, legal: ["start"], history: "[\(entry(7)), \(entry(8))]")
        let next = try state(view: playingView, legal: ["hit"], history: "[\(entry(7)), \(entry(8))]")
        XCTAssertEqual(BlackjackLayout.handNumber(playing), 8)
        XCTAssertEqual(BlackjackLayout.handNumber(finished), 8)
        XCTAssertEqual(BlackjackLayout.handNumber(next), 9)
        XCTAssertEqual(BlackjackLayout.handNumber(try state(status: "waiting", turn: "null", view: playingView)), 0)
    }

    func testLastMoveFromTwoViews() {
        let before = BlackjackRound(dealer: [card(10)], players: [
            BlackjackRoundPlayer(userId: "can", credits: 980, bet: 20, hands: [BlackjackRoundHand(cards: [card(5), card(6)], bet: 20)]),
            BlackjackRoundPlayer(userId: "ece", credits: 990, bet: 10, hands: [BlackjackRoundHand(cards: [card(8), card(8, .hearts)], bet: 10)]),
        ], turn: 0)
        let after = BlackjackRound(dealer: [card(10)], players: [
            BlackjackRoundPlayer(userId: "can", credits: 960, bet: 20, hands: [BlackjackRoundHand(cards: [card(5), card(6), card(9)], bet: 40, state: "stood")]),
            BlackjackRoundPlayer(userId: "ece", credits: 980, bet: 10, hands: [
                BlackjackRoundHand(cards: [card(8), card(2)], bet: 10, split: true), BlackjackRoundHand(cards: [card(8, .hearts)], bet: 10, split: true),
            ]),
        ], turn: 1)
        XCTAssertEqual(BlackjackMove.moves(from: before, to: after), [.double("can"), .split("ece")])
        XCTAssertEqual(BlackjackMove.double("can").text("Can"), "Can ikiye katladı")
        XCTAssertEqual(BlackjackMove.moves(from: nil, to: after), [])
    }
}

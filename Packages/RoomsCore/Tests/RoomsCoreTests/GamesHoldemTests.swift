import XCTest
@testable import RoomsCore

/// Hold'em table logic for the iPhone view. Fixtures follow `holdemView` in `packages/games/src/holdem.ts`
/// (log, mucked, runoutFrom, settlementReason) and the desktop `games/holdem/model.ts` behaviour.
final class GamesHoldemTests: XCTestCase {
    private func game(_ json: String) throws -> GameState {
        let body = #"""
        {"protocolVersion":1,"serverTimeMs":2000,"events":[],"replayRequired":false,"room":{"roomId":"room","revision":9,
         "participants":[{"userId":"ece","displayName":"Ece","joinedAt":1,"lastSeenAt":1,"canControl":true,"canCreate":true}],
         "primary":{"activity":"holdem","title":"Cuma masası","hostUserId":"ece","startedAt":1700000000000,"state":"live"},
         "timeline":{"playing":false,"positionSec":0,"rate":1,"effectiveServerTimeMs":0,"epoch":0,"itemId":null},
         "queue":[],"polls":[],"whiteboard":[],"cinema":null,"game":\#(json)}}
        """#
        return try XCTUnwrap(try JSONDecoder().decode(ActivityResponse.self, from: Data(body.utf8)).room.game)
    }
    private let rules = #"{"name":"Cuma masası","capacity":6,"smallBlind":10,"bigBlind":20,"minBuyIn":500,"maxBuyIn":2000,"initialChips":1000,"spectatorsAllowed":true}"#
    private let seats = #"""
    [{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":0,"connected":true,"pendingNextHand":false},
     {"seat":2,"userId":"can","name":"Can","bot":false,"chips":0,"connected":true,"pendingNextHand":false},
     {"seat":4,"userId":"bot-1","name":"Tayfa Bot","bot":true,"chips":0,"connected":true,"pendingNextHand":false}]
    """#

    /// River showdown: Ece all-in short (main pot), Can and the bot fight for the side pot; the bot mucks.
    private var showdown: String { #"""
    {"kind":"holdem","ownerId":"ece","status":"finished","seats":\#(seats),"turn":null,
     "view":{"revision":9,"button":0,"turn":null,"stage":"ended","maximumBet":0,"minimumRaise":20,
       "board":[{"id":"b1","suit":"hearts","rank":14},{"id":"b2","suit":"hearts","rank":13},{"id":"b3","suit":"clubs","rank":2},
                {"id":"b4","suit":"spades","rank":7},{"id":"b5","suit":"hearts","rank":9}],
       "payouts":{"ece":300,"can":400,"bot-1":0},"winners":["ece","can"],
       "seats":[{"userId":"ece","chips":300,"folded":false,"streetBet":0,"contribution":100,
                 "cards":[{"id":"e1","suit":"hearts","rank":4},{"id":"e2","suit":"hearts","rank":5}],"hiddenCardCount":0},
                {"userId":"can","chips":400,"folded":false,"streetBet":0,"contribution":300,
                 "cards":[{"id":"c1","suit":"clubs","rank":14},{"id":"c2","suit":"diamonds","rank":14}],"hiddenCardCount":0},
                {"userId":"bot-1","chips":0,"folded":false,"streetBet":0,"contribution":300,"cards":[],"hiddenCardCount":2}],
       "pots":[{"kind":"main","amount":300,"eligible":["ece","can","bot-1"],"winners":["ece"],"awards":{"ece":300},"split":false},
               {"kind":"side","amount":400,"eligible":["can","bot-1"],"winners":["can"],"awards":{"can":400},"split":false},
               {"kind":"side","amount":40,"eligible":["can","ece"],"winners":["can","ece"],"awards":{"can":20,"ece":20},"split":true}],
       "ownHand":null,"settlementReason":"showdown",
       "showdown":{"ece":{"category":"flush","score":[6],"bestFiveCardIds":["e1","e2","b1","b2","b5"]},
                   "can":{"category":"three-of-a-kind","score":[4],"bestFiveCardIds":["c1","c2","b1","b2","b4"]}},
       "mucked":["bot-1"],"runoutFrom":"turn",
       "log":[{"street":"preflop","userId":"ece","action":"smallBlind","amount":10,"to":10,"allIn":false},
              {"street":"preflop","userId":"can","action":"bigBlind","amount":20,"to":20,"allIn":false},
              {"street":"preflop","userId":"bot-1","action":"call","amount":20,"to":20,"allIn":false},
              {"street":"turn","userId":"ece","action":"raise","amount":80,"to":80,"allIn":true},
              {"street":"turn","userId":"can","action":"raise","amount":280,"to":280,"allIn":false},
              {"street":"turn","userId":"bot-1","action":"call","amount":280,"to":280,"allIn":true},
              {"street":"turn","userId":"junk"}],
       "tableName":"Cuma masası","rules":\#(rules),"spectators":[],"watching":false,"spectatorAccess":true,
       "legalActions":["start"],"turnDeadline":0,"capacity":6},
     "history":[]}
    """# }

    /// Flop, Ece to act facing a 40 bet with 260 behind; pot 120 before this street's bets are counted.
    private func flop(chips: Int = 260, streetBet: Int = 0, legal: String = #"["fold","call","raise"]"#) -> String { #"""
    {"kind":"holdem","ownerId":"ece","status":"playing","seats":\#(seats),"turn":0,
     "view":{"revision":4,"button":1,"turn":0,"stage":"flop","maximumBet":40,"minimumRaise":40,
       "board":[{"id":"b1","suit":"hearts","rank":14},{"id":"b2","suit":"hearts","rank":13},{"id":"b3","suit":"clubs","rank":2}],
       "payouts":{},"winners":[],
       "seats":[{"userId":"ece","chips":\#(chips),"folded":false,"streetBet":\#(streetBet),"contribution":\#(40 + streetBet),"cards":[],"hiddenCardCount":0},
                {"userId":"can","chips":500,"folded":false,"streetBet":40,"contribution":80,"cards":[],"hiddenCardCount":2},
                {"userId":"bot-1","chips":500,"folded":true,"streetBet":0,"contribution":40,"cards":[],"hiddenCardCount":0}],
       "pots":[{"kind":"main","amount":\#(160 + streetBet),"eligible":["ece","can"],"winners":[],"awards":{},"split":false}],
       "ownHand":null,"showdown":null,"settlementReason":null,"mucked":[],"runoutFrom":null,
       "log":[{"street":"preflop","userId":"ece","action":"bigBlind","amount":20,"to":20,"allIn":false},
              {"street":"preflop","userId":"can","action":"smallBlind","amount":10,"to":10,"allIn":false},
              {"street":"flop","userId":"can","action":"raise","amount":40,"to":40,"allIn":false}],
       "tableName":"Cuma masası","rules":\#(rules),"spectators":[],"watching":false,"spectatorAccess":true,
       "legalActions":\#(legal),"turnDeadline":47000,"capacity":6},
     "history":[]}
    """# }

    // MARK: Raise presets

    func testPresetsAreClampedToTheServerRange() throws {
        let state = try game(flop())
        let hand = try XCTUnwrap(state.holdem)
        let raise = try XCTUnwrap(hand.raise(for: "ece"))
        XCTAssertEqual(raise.range, 80...260)
        XCTAssertEqual(raise.pot, 160)
        // Call 40, pot after the call 200: ½ pot = 40 + 100, pot = 40 + 200.
        XCTAssertEqual(raise.presets.map(\.amount), [80, 140, 240, 260])
        XCTAssertEqual(raise.presets.map(\.title), ["Min", "½ Pot", "Pot", "All-in"])
        XCTAssertEqual(raise.clamp(10), 80); XCTAssertEqual(raise.clamp(9999), 260); XCTAssertEqual(raise.clamp(150), 150)
        XCTAssertEqual(raise.confirmTitle(150), "150 fişe artır")
        XCTAssertEqual(raise.confirmTitle(999), "All-in 260")
        XCTAssertFalse(raise.allInOnly)
    }

    func testHalfPotRoundsUpLikeTheDesktop() {
        let raise = HoldemRaise(pot: 121, maximumBet: 40, streetBet: 0, range: 80...2000)
        // Call 40, after the call 161 → half 80.5 → 81.
        XCTAssertEqual(raise.presets.first { $0.kind == .halfPot }?.amount, 121)
        XCTAssertEqual(raise.presets.first { $0.kind == .pot }?.amount, 201)
    }

    func testShortStackCanOnlyGoAllIn() throws {
        // 60 behind: all-in total 60 beats the 40 bet but not the 80 minimum raise.
        let hand = try XCTUnwrap(try game(flop(chips: 60)).holdem)
        let raise = try XCTUnwrap(hand.raise(for: "ece"))
        XCTAssertEqual(raise.range, 60...60)
        XCTAssertTrue(raise.allInOnly)
        XCTAssertEqual(Set(raise.presets.map(\.amount)), [60])
        // 30 behind cannot exceed the bet at all: no raise, and the call is all-in for less.
        let shorter = try XCTUnwrap(try game(flop(chips: 30)).holdem)
        XCTAssertNil(shorter.raise(for: "ece"))
        XCTAssertNil(shorter.raise(for: "zey"), "spectators never get a raise")
    }

    // MARK: Action bar

    func testCallLabel() throws {
        let hand = try XCTUnwrap(try game(flop()).holdem)
        XCTAssertEqual(hand.toCall("ece"), 40); XCTAssertEqual(hand.callAmount("ece"), 40)
        let bar = HoldemActionBar(legalActions: ["fold", "call", "raise"], busy: false, callAmount: 40, stack: 260, canRaise: true)
        XCTAssertEqual(bar.middleTitle, "Gör 40"); XCTAssertEqual(bar.middle, .call(40))
        // A stack of 30 calls all-in for less.
        let short = try XCTUnwrap(try game(flop(chips: 30)).holdem)
        XCTAssertEqual(short.callAmount("ece"), 30)
        XCTAssertEqual(HoldemActionBar(legalActions: ["fold", "call"], busy: false, callAmount: 30, stack: 30, canRaise: false).middleTitle, "All-in 30")
        // Already matched the bet: check.
        let matched = try XCTUnwrap(try game(flop(streetBet: 40)).holdem)
        XCTAssertEqual(matched.toCall("ece"), 0)
        XCTAssertEqual(HoldemActionBar(legalActions: ["fold", "check", "raise"], busy: false, callAmount: 0, stack: 260, canRaise: true).middleTitle, "Kontrol et")
    }

    func testButtonsFollowLegalActions() {
        let checkRaise = HoldemActionBar(legalActions: ["fold", "check", "raise"], busy: false, callAmount: 0, stack: 500, canRaise: true)
        XCTAssertTrue(checkRaise.fold); XCTAssertEqual(checkRaise.middle, .check); XCTAssertTrue(checkRaise.middleEnabled); XCTAssertTrue(checkRaise.raise)

        let foldCall = HoldemActionBar(legalActions: ["fold", "call"], busy: false, callAmount: 40, stack: 500, canRaise: true)
        XCTAssertTrue(foldCall.fold); XCTAssertTrue(foldCall.middleEnabled); XCTAssertFalse(foldCall.raise, "raise not offered by the server")

        let noRange = HoldemActionBar(legalActions: ["fold", "call", "raise"], busy: false, callAmount: 40, stack: 30, canRaise: false)
        XCTAssertFalse(noRange.raise, "no legal raise total")

        let busy = HoldemActionBar(legalActions: ["fold", "check", "raise"], busy: true, callAmount: 0, stack: 500, canRaise: true)
        XCTAssertFalse(busy.fold || busy.middleEnabled || busy.raise); XCTAssertFalse(busy.anyEnabled)

        let notMyTurn = HoldemActionBar(legalActions: ["start"], busy: false, callAmount: 0, stack: 500, canRaise: true)
        XCTAssertFalse(notMyTurn.anyEnabled); XCTAssertEqual(notMyTurn.middle, .none)
    }

    // MARK: Showdown, pots, log

    func testSidePotLabelsFromTheView() throws {
        let state = try game(showdown)
        let hand = try XCTUnwrap(state.holdem)
        let name = { (id: String) in state.seat(of: id)?.name ?? "Oyuncu" }
        XCTAssertEqual(hand.pots.enumerated().map { $0.element.label(index: $0.offset, name: name) }, [
            "Ana pot · 300 · Ece +300",
            "Yan pot 1 · 400 · Can +400",
            "Yan pot 2 · 40 · Paylaşıldı · Can +20, Ece +20",
        ])
        XCTAssertEqual(hand.potTotal, 740)
        XCTAssertTrue(hand.splitPot)
        XCTAssertEqual(hand.paidPlayers.map(\.userId), ["can", "ece"])
    }

    func testShowdownHighlightsWinnersAndMuckedHands() throws {
        let state = try game(showdown)
        let hand = try XCTUnwrap(state.holdem)
        let extras = try XCTUnwrap(state.view(as: HoldemViewExtras.self))
        XCTAssertEqual(hand.winningCardIDs, ["e1", "e2", "b1", "b2", "b5", "c1", "c2", "b4"])
        XCTAssertEqual(extras.mucked, ["bot-1"]); XCTAssertEqual(extras.runoutFrom, "turn")
        XCTAssertEqual(hand.settlementReason, "showdown")
        let seat = { (id: String) in try XCTUnwrap(state.seat(of: id)) }
        XCTAssertEqual(HoldemSeatStatus.text(seat: try seat("bot-1"), player: hand.player("bot-1"), hand: hand, mucked: extras.mucked, me: "ece", turn: nil), "Kartını açmadı")
        XCTAssertEqual(HoldemSeatStatus.text(seat: try seat("ece"), player: hand.player("ece"), hand: hand, mucked: extras.mucked, me: "ece", turn: nil), "Ortak kazanan · Renk")
    }

    func testLogBubblesAndBlinds() throws {
        let state = try game(showdown)
        let extras = try XCTUnwrap(state.view(as: HoldemViewExtras.self))
        XCTAssertEqual(extras.log.count, 6, "a malformed entry is dropped, the rest stay")
        // Ended: bubbles from the last logged street (turn).
        let bubbles = extras.lastActions(stage: "ended")
        XCTAssertEqual(bubbles["ece"]?.label, "All-in 80")
        XCTAssertEqual(bubbles["can"]?.label, "Artır 280")
        XCTAssertEqual(bubbles["bot-1"]?.label, "All-in 280")
        XCTAssertTrue(extras.lastActions(stage: "river").isEmpty, "a new street starts without bubbles")
        XCTAssertEqual(extras.blinds.small, "ece"); XCTAssertEqual(extras.blinds.big, "can")
        XCTAssertEqual(extras.log[0].line(name: "Ece"), "Ece · Küçük kör 10")
        XCTAssertEqual(HoldemLogEntry(street: "flop", userId: "a", action: "call", amount: 40, to: 40, allIn: false).label, "Gör 40")
        XCTAssertEqual(HoldemLogEntry(street: "flop", userId: "a", action: "check", amount: 0, to: 0, allIn: true).label, "Kontrol")
        XCTAssertEqual(HoldemLogEntry(street: "flop", userId: "a", action: "fold", amount: 0, to: 0, allIn: false).label, "Bırak")
    }

    func testOlderServiceWithoutExtras() throws {
        let old = flop().replacingOccurrences(of: #""mucked":[],"runoutFrom":null,"#, with: "")
            .replacingOccurrences(of: #""log":[{"street":"preflop","userId":"ece","action":"bigBlind","amount":20,"to":20,"allIn":false},"#, with: #""x":[{},"#)
        let extras = try XCTUnwrap(try game(old).view(as: HoldemViewExtras.self))
        XCTAssertEqual(extras, .empty)
    }

    // MARK: Layout and buy-in

    func testSeatLayoutPutsTheViewerAtTheBottomThenClockwise() {
        XCTAssertEqual(HoldemSeatLayout.order(capacity: 6, ownSeat: 2), [2, 3, 4, 5, 0, 1])
        XCTAssertEqual(HoldemSeatLayout.order(capacity: 9, ownSeat: nil), Array(0..<9))
        let own = HoldemSeatLayout.point(capacity: 6, seat: 2, ownSeat: 2)
        XCTAssertEqual(own.x, 0, accuracy: 0.001); XCTAssertEqual(own.y, 1, accuracy: 0.001)
        // Next seat to act sits to the viewer's left (clockwise on screen), the opposite seat at the top.
        XCTAssertLessThan(HoldemSeatLayout.point(capacity: 6, seat: 3, ownSeat: 2).x, 0)
        XCTAssertEqual(HoldemSeatLayout.point(capacity: 6, seat: 5, ownSeat: 2).y, -1, accuracy: 0.001)
        XCTAssertGreaterThan(HoldemSeatLayout.point(capacity: 6, seat: 1, ownSeat: 2).x, 0)
        // Spectators: seat 0 at the bottom.
        XCTAssertEqual(HoldemSeatLayout.point(capacity: 2, seat: 0, ownSeat: nil).y, 1, accuracy: 0.001)
        XCTAssertEqual(HoldemSeatLayout.point(capacity: 2, seat: 1, ownSeat: nil).y, -1, accuracy: 0.001)
    }

    func testBuyInAndRebuyFollowTheService() throws {
        let state = try game(showdown)
        let rules = try XCTUnwrap(state.table.rules)
        XCTAssertEqual(HoldemBuyIn.range(rules), 500...2000)
        XCTAssertEqual(HoldemBuyIn.initial(rules), 1000)
        XCTAssertEqual(HoldemBuyIn.initial(.standard), 1000)
        XCTAssertEqual(HoldemBuyIn.range(.standard), 1000...1000)
        XCTAssertTrue(HoldemBuyIn.canRebuy(chips: 0, rules: rules, status: .finished))
        XCTAssertTrue(HoldemBuyIn.canRebuy(chips: 499, rules: rules, status: .waiting))
        XCTAssertFalse(HoldemBuyIn.canRebuy(chips: 500, rules: rules, status: .finished), "not below the minimum")
        XCTAssertFalse(HoldemBuyIn.canRebuy(chips: 0, rules: rules, status: .playing), "never during a hand")
        XCTAssertFalse(HoldemBuyIn.canRebuy(chips: 0, rules: nil, status: .finished))
        XCTAssertEqual(HoldemBuyIn.stackAfterRebuy(chips: 300, amount: 2000, rules: rules), 2000)
        XCTAssertEqual(GameCommand.sit(seat: 1, buyIn: 1500).json, .object(["type": .string("game.sit"), "seat": .number(1), "buyIn": .number(1500)]))
    }
}

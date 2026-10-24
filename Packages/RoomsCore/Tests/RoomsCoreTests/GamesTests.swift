import XCTest
@testable import RoomsCore

/// Fixtures written by hand from `GamePublicState` and the `*View` functions in the desktop repository
/// (`packages/activity-protocol`, `packages/games/src`, `apps/services/activities/games.ts`).
final class GamesTests: XCTestCase {
    private func room(game: String?, polls: String = "[]") throws -> ActivityRoom {
        let gamePart = game.map { #","game":\#($0)"# } ?? ""
        let json = #"""
        {"protocolVersion":1,"serverTimeMs":2000,"events":[],"replayRequired":false,"room":{"roomId":"room","revision":9,
         "participants":[{"userId":"ece","displayName":"Ece","joinedAt":1,"lastSeenAt":1,"canControl":true,"canCreate":true}],
         "primary":{"activity":"holdem","title":"Cuma masası","hostUserId":"ece","startedAt":1700000000000,"state":"live"},
         "timeline":{"playing":false,"positionSec":0,"rate":1,"effectiveServerTimeMs":0,"epoch":0,"itemId":null},
         "queue":[],"polls":\#(polls),"whiteboard":[],"cinema":null\#(gamePart)}}
        """#
        return try JSONDecoder().decode(ActivityResponse.self, from: Data(json.utf8)).room
    }
    private func game(_ json: String) throws -> GameState { try XCTUnwrap(try room(game: json).game) }
    private let recovery = #"{"disconnectedAt":null,"takeoverAt":null,"pendingReturn":false,"takeover":false,"events":[]}"#
    private let holdemRules = #"{"name":"Cuma masası","capacity":6,"smallBlind":10,"bigBlind":20,"minBuyIn":1000,"maxBuyIn":1000,"initialChips":1000,"spectatorsAllowed":true}"#

    // MARK: Hold'em

    private var holdemPlaying: String { #"""
    {"kind":"holdem","ownerId":"ece","status":"playing",
     "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
              {"seat":3,"userId":"can","name":"Can","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
              {"seat":1,"userId":"bot-1","name":"Tayfa Bot 2","bot":true,"chips":1000,"connected":true,"pendingNextHand":true}],
     "turn":0,
     "view":{"ownHand":null,"showdown":null,"settlementReason":null,
       "pots":[{"kind":"main","amount":30,"eligible":["ece","can"],"winners":[],"awards":{},"split":false}],
       "revision":1,"button":0,"turn":0,"stage":"preflop","board":[],"maximumBet":20,"minimumRaise":20,"payouts":{},"winners":[],
       "seats":[{"userId":"ece","chips":990,"folded":false,"streetBet":10,"contribution":10,
                 "cards":[{"id":"0-hearts-14","suit":"hearts","rank":14},{"id":"0-spades-13","suit":"spades","rank":13}],"hiddenCardCount":0},
                {"userId":"can","chips":980,"folded":false,"streetBet":20,"contribution":20,"cards":[],"hiddenCardCount":2}],
       "ownRecovery":\#(recovery),"tableName":"Cuma masası","rules":\#(holdemRules),"spectators":[{"userId":"zey","name":"Zeynep"}],
       "watching":false,"spectatorAccess":true,"legalActions":["fold","call","raise"],"turnDeadline":47000,"capacity":6,
       "statistics":{"ece":{"hands":3,"wins":2,"score":0}}},
     "history":[]}
    """# }

    func testDecodesAHoldemHandWithOnlyTheViewersCards() throws {
        let state = try game(holdemPlaying)
        XCTAssertEqual(state.kind, .holdem); XCTAssertEqual(state.status, .playing)
        XCTAssertTrue(state.isMyTurn("ece")); XCTAssertFalse(state.isMyTurn("can")); XCTAssertTrue(state.isOwner("ece"))
        XCTAssertEqual(state.legalActions, [.fold, .call, .raise]); XCTAssertTrue(state.can(.raise)); XCTAssertFalse(state.can(.check))
        XCTAssertEqual(state.table.rules?.capacity, 6); XCTAssertEqual(state.table.spectators.first?.name, "Zeynep")
        XCTAssertEqual(state.table.statistics["ece"]?.wins, 2); XCTAssertEqual(state.freeSeats, [2, 4, 5])
        XCTAssertEqual(state.seat(of: "bot-1")?.pendingNextHand, true)
        XCTAssertEqual(state.turnSecondsLeft(nowMs: 2000, serverOffsetMs: 0) ?? -1, 45, accuracy: 0.001)
        let hand = try XCTUnwrap(state.holdem)
        XCTAssertEqual(hand.player("ece")?.cards.map(\.rankLabel), ["A", "K"])
        XCTAssertEqual(hand.player("can")?.cards, []); XCTAssertEqual(hand.player("can")?.hiddenCardCount, 2)
        XCTAssertNil(hand.player("bot-1"), "late sitter is not in the hand")
        XCTAssertEqual(hand.turnPlayer?.userId, "ece"); XCTAssertEqual(hand.toCall("ece"), 10); XCTAssertEqual(hand.potTotal, 30)
        XCTAssertEqual(hand.raiseRange("ece"), 40...1000)
    }
    func testDecodesAHoldemShowdown() throws {
        let finished = #"""
        {"kind":"holdem","ownerId":"ece","status":"finished",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1040,"connected":true,"pendingNextHand":false},
                  {"seat":1,"userId":"can","name":"Can","bot":false,"chips":960,"connected":true,"pendingNextHand":false}],
         "turn":null,
         "view":{"ownHand":{"category":"one-pair","score":[1,14,13,9,5],"bestFiveCardIds":["0-hearts-14","0-clubs-14","0-spades-13","0-clubs-9","0-diamonds-5"]},
           "showdown":{"ece":{"category":"one-pair","score":[1,14,13,9,5],"bestFiveCardIds":["a","b","c","d","e"]},
                       "can":{"category":"high-card","score":[0,13,12,9,5,3],"bestFiveCardIds":["f","g","h","i","j"]}},
           "settlementReason":"showdown",
           "pots":[{"kind":"main","amount":80,"eligible":["ece","can"],"winners":["ece"],"awards":{"ece":80},"split":false}],
           "revision":7,"button":1,"turn":null,"stage":"ended",
           "board":[{"id":"0-clubs-14","suit":"clubs","rank":14},{"id":"0-clubs-9","suit":"clubs","rank":9},{"id":"0-diamonds-5","suit":"diamonds","rank":5},
                    {"id":"0-hearts-3","suit":"hearts","rank":3},{"id":"0-spades-2","suit":"spades","rank":2}],
           "maximumBet":0,"minimumRaise":20,"payouts":{"ece":80},"winners":["ece"],
           "seats":[{"userId":"ece","chips":1040,"folded":false,"streetBet":0,"contribution":40,"cards":[{"id":"0-hearts-14","suit":"hearts","rank":14},{"id":"0-spades-13","suit":"spades","rank":13}],"hiddenCardCount":0},
                    {"userId":"can","chips":960,"folded":false,"streetBet":0,"contribution":40,"cards":[{"id":"0-diamonds-13","suit":"diamonds","rank":13},{"id":"0-hearts-12","suit":"hearts","rank":12}],"hiddenCardCount":0}],
           "ownRecovery":\#(recovery),"tableName":"Hold’em","rules":\#(holdemRules),"spectators":[],"watching":false,"spectatorAccess":true,
           "legalActions":["start"],"turnDeadline":47000,"capacity":6,"statistics":{}},
         "history":[{"hand":1,"endedAt":9000,"tableName":"Hold’em","result":{"payouts":{"ece":80},"settlementReason":"showdown"},
                     "seats":[{"seat":0,"position":0,"userId":"ece","name":"Ece","bot":false,"startingChips":1000}]}]}
        """#
        let state = try game(finished)
        XCTAssertNil(state.turn); XCTAssertEqual(state.legalActions, [.start]); XCTAssertNil(state.turnSecondsLeft(nowMs: 0, serverOffsetMs: 0))
        let hand = try XCTUnwrap(state.holdem)
        XCTAssertTrue(hand.ended); XCTAssertEqual(hand.settlementReason, "showdown"); XCTAssertEqual(hand.showdown?["can"]?.title, "Yüksek kart")
        XCTAssertEqual(hand.ownHand?.title, "Bir çift"); XCTAssertEqual(hand.pots.first?.awards, ["ece": 80])
        XCTAssertEqual(hand.player("can")?.cards.count, 2); XCTAssertNil(hand.raiseRange("ece"))
        XCTAssertEqual(state.history.first?.result["settlementReason"], .string("showdown"))
        XCTAssertEqual(state.history.first?.seats?.first?.startingChips, 1000)
    }

    // MARK: Blackjack

    func testDecodesABlackjackRoundWithTheDealerHoleCardHidden() throws {
        let state = try game(#"""
        {"kind":"blackjack","ownerId":"ece","status":"playing",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":2,"userId":"can","name":"Can","bot":false,"chips":1000,"connected":false,"pendingNextHand":false}],
         "turn":2,
         "view":{"revision":3,"dealer":[{"id":"2-clubs-10","suit":"clubs","rank":10}],"dealerHiddenCount":1,
           "players":[{"userId":"ece","credits":990,"bet":10,"activeHand":1,"hands":[{"cards":[{"id":"1-hearts-10","suit":"hearts","rank":10},{"id":"1-hearts-9","suit":"hearts","rank":9}],"bet":10,"state":"stood","split":false}]},
                      {"userId":"can","credits":980,"bet":20,"activeHand":0,"hands":[{"cards":[{"id":"3-spades-8","suit":"spades","rank":8},{"id":"4-diamonds-8","suit":"diamonds","rank":8}],"bet":20,"state":"playing","split":false}]}],
           "turn":1,"finished":false,"results":[],
           "ownRecovery":\#(recovery),"tableName":"blackjack","spectators":[],"watching":false,"spectatorAccess":true,
           "legalActions":[],"turnDeadline":47000,"capacity":7,"statistics":{}},
         "history":[]}
        """#)
        XCTAssertEqual(state.kind, .blackjack); XCTAssertEqual(state.turnSeat?.userId, "can"); XCTAssertFalse(state.isMyTurn("ece"))
        XCTAssertNil(state.table.rules); XCTAssertTrue(state.legalActions.isEmpty)
        let round = try XCTUnwrap(state.blackjack)
        XCTAssertEqual(round.dealer.count, 1); XCTAssertEqual(round.dealerHiddenCount, 1); XCTAssertEqual(round.dealerTotal, 10)
        XCTAssertEqual(round.turnPlayer?.userId, "can"); XCTAssertEqual(round.player("ece")?.hands.first?.total, 19)
        XCTAssertEqual(Blackjack.total([PlayingCard(id: "a", suit: .clubs, rank: 14), PlayingCard(id: "b", suit: .clubs, rank: 14), PlayingCard(id: "c", suit: .clubs, rank: 9)]), 21)
        XCTAssertTrue(Blackjack.validBet(10, chips: 1000)); XCTAssertFalse(Blackjack.validBet(11, chips: 1000)); XCTAssertFalse(Blackjack.validBet(2000, chips: 1000))
    }

    // MARK: Batak

    func testDecodesBatakPositionsAndMirrorsTheFollowRule() throws {
        let state = try game(#"""
        {"kind":"batak","ownerId":"ece","status":"playing",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":3,"userId":"bot-3","name":"Tayfa Bot 4","bot":true,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":1,"userId":"can","name":"Can","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":2,"userId":"zey","name":"Zeynep","bot":false,"chips":1000,"connected":true,"pendingNextHand":false}],
         "turn":1,
         "view":{"variant":"ihaleli","stage":"playing","turn":1,"bid":7,"bids":[0,0,0,0],"bidder":3,"trump":"spades","tricks":[1,0,0,2],
           "trick":[{"seat":0,"card":{"id":"0-hearts-10","suit":"hearts","rank":10}}],"scores":[],
           "completedTricks":[{"plays":[{"seat":3,"card":{"id":"0-clubs-14","suit":"clubs","rank":14}}],"winner":3}],
           "hands":[{"seat":0,"cards":[],"count":10},
                    {"seat":1,"cards":[{"id":"0-hearts-5","suit":"hearts","rank":5},{"id":"0-hearts-12","suit":"hearts","rank":12},{"id":"0-spades-3","suit":"spades","rank":3}],"count":3},
                    {"seat":2,"cards":[],"count":10},{"seat":3,"cards":[],"count":10}],
           "buriedCount":0,
           "ownRecovery":\#(recovery),"tableName":"batak","spectators":[],"watching":false,"spectatorAccess":true,
           "legalActions":["play"],"turnDeadline":47000,"capacity":4,"statistics":{}},
         "history":[]}
        """#)
        XCTAssertEqual(state.orderedSeats.map(\.userId), ["ece", "can", "zey", "bot-3"])
        XCTAssertEqual(state.position(of: "can"), 1); XCTAssertEqual(state.seat(atPosition: 3)?.userId, "bot-3")
        XCTAssertTrue(state.isMyTurn("can")); XCTAssertEqual(state.legalActions, [.play])
        let hand = try XCTUnwrap(state.batak)
        XCTAssertEqual(hand.variant, .ihaleli); XCTAssertEqual(state.seat(atPosition: hand.bidder)?.name, "Tayfa Bot 4")
        XCTAssertTrue(hand.trumpKnown); XCTAssertNil(hand.partner(of: 0))
        let mine = state.myBatakCards("can")
        XCTAssertEqual(mine.count, 3); XCTAssertEqual(state.myBatakCards("ece"), [], "other hands are counts only")
        XCTAssertEqual(hand.legalCards(mine).map(\.id), ["0-hearts-12"], "follow suit and head the trick")
        XCTAssertEqual(state.seat(atPosition: hand.completedTricks.first?.winner)?.userId, "bot-3")
        XCTAssertEqual(BatakVariant.gommeli.minimumBid, 8); XCTAssertEqual(BatakVariant.gommeli.maximumBid, 16); XCTAssertEqual(BatakVariant.kozMaca.minimumBid, 1)
    }
    func testBatakTrumpIsUnknownWhileBidding() throws {
        let state = try game(#"""
        {"kind":"batak","ownerId":"ece","status":"playing","seats":[],"turn":0,
         "view":{"variant":"esli","stage":"bidding","turn":0,"bid":0,"bids":[0,0,0,0],"bidder":0,"trump":"spades","tricks":[0,0,0,0],
           "trick":[],"scores":[],"completedTricks":[],"hands":[],"buriedCount":0,"legalActions":["bid","pass"]},"history":[]}
        """#)
        let hand = try XCTUnwrap(state.batak)
        XCTAssertFalse(hand.trumpKnown); XCTAssertEqual(hand.partner(of: 1), 3)
        XCTAssertEqual(state.legalActions, [.bid, .pass]); XCTAssertEqual(state.table, GameTableView(from: [], legal: ["bid", "pass"]))
    }

    // MARK: 101 Okey

    func testDecodesOkeyWithOwnTilesMeldsAndAPickedDiscard() throws {
        let state = try game(#"""
        {"kind":"101","ownerId":"ece","status":"playing",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":1,"userId":"can","name":"Can","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":2,"userId":"zey","name":"Zeynep","bot":false,"chips":1000,"connected":true,"pendingNextHand":false},
                  {"seat":3,"userId":"bot-3","name":"Tayfa Bot 4","bot":true,"chips":1000,"connected":true,"pendingNextHand":false}],
         "turn":1,
         "view":{"rules":{"id":"rooms-101-v1","folding":true,"teams":false,"openingMinimum":101,"pairsMinimum":5},
           "indicator":{"id":"blue-13-0","color":"blue","value":13},"remainingStock":40,"turn":1,"stage":"discard","highestOpening":104,
           "melds":[{"owner":0,"pairs":false,"tiles":[{"id":"red-11-0","color":"red","value":11},{"id":"blue-1-1","color":"red","value":12,"joker":true},{"id":"red-13-1","color":"red","value":13}]}],
           "opened":["runs",null,null,null],
           "discards":[[{"id":"black-4-0","color":"black","value":4}],[],[],[]],
           "scores":[],"winner":null,
           "hands":[{"seat":0,"tiles":[],"count":11},
                    {"seat":1,"tiles":[{"id":"black-4-0","color":"black","value":4},{"id":"false-joker-0","color":"blue","value":1},{"id":"yellow-7-1","color":"yellow","value":7}],"count":3},
                    {"seat":2,"tiles":[],"count":21},{"seat":3,"tiles":[],"count":21}],
           "ownRecovery":\#(recovery),"tableName":"101","spectators":[],"watching":false,"spectatorAccess":true,
           "legalActions":["discard","open","open-pairs","draw"],"turnDeadline":47000,"capacity":4,"statistics":{}},
         "history":[]}
        """#)
        XCTAssertEqual(state.kind, .okey101); XCTAssertEqual(state.kind.rawValue, "101"); XCTAssertTrue(state.isMyTurn("can"))
        XCTAssertTrue(state.holdsPickedDiscard); XCTAssertTrue(state.can(.openPairs))
        let hand = try XCTUnwrap(state.okey101)
        XCTAssertEqual(hand.jokerValue, 1); XCTAssertTrue(hand.rules.folding); XCTAssertEqual(hand.highestOpening, 104)
        XCTAssertEqual(hand.melds.first?.tiles[1].isJoker, true); XCTAssertEqual(hand.openedMode(atPosition: 0), "runs"); XCTAssertNil(hand.openedMode(atPosition: 1))
        let mine = state.myOkeyTiles("can")
        XCTAssertEqual(mine.count, 3); XCTAssertTrue(mine[1].isFalseJoker); XCTAssertFalse(mine[1].isJoker)
        XCTAssertEqual(state.myOkeyTiles("zey"), [])
        XCTAssertEqual(hand.takeableDiscard(forPosition: 1)?.id, "black-4-0"); XCTAssertNil(hand.takeableDiscard(forPosition: 2))
    }

    // MARK: Lobby, access, forward compatibility

    func testLobbyViewHasOnlyTheTableKeys() throws {
        let state = try game(#"""
        {"kind":"holdem","ownerId":"ece","status":"waiting",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":1000,"connected":true,"pendingNextHand":false}],
         "turn":null,
         "view":{"ownRecovery":\#(recovery),"tableName":"Cuma masası","rules":\#(holdemRules),"spectators":[],"watching":false,
           "spectatorAccess":true,"legalActions":["start"],"turnDeadline":0,"capacity":6,"statistics":{}},
         "history":[]}
        """#)
        XCTAssertNil(state.hand); XCTAssertNil(state.holdem); XCTAssertEqual(state.status, .waiting)
        XCTAssertEqual(state.legalActions, [.start]); XCTAssertEqual(state.freeSeats, [1, 2, 3, 4, 5])
        XCTAssertEqual(state.table.tableName, "Cuma masası"); XCTAssertEqual(state.table.ownRecovery?.canRequestReturn, false)
    }
    func testViewerWithoutAccessSeesTheTableButNoHand() throws {
        let state = try game(#"""
        {"kind":"holdem","ownerId":"ece","status":"playing",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":990,"connected":true,"pendingNextHand":false},
                  {"seat":1,"userId":"can","name":"Can","bot":true,"chips":980,"connected":false,"pendingNextHand":false}],
         "turn":1,
         "view":{"ownRecovery":null,"tableName":"Gizli masa","rules":\#(holdemRules.replacingOccurrences(of: #""spectatorsAllowed":true"#, with: #""spectatorsAllowed":false"#)),
           "spectators":[],"watching":false,"spectatorAccess":false,"legalActions":[],"turnDeadline":47000,"capacity":6,"statistics":{}},
         "history":[]}
        """#)
        XCTAssertNil(state.hand); XCTAssertFalse(state.table.spectatorAccess); XCTAssertEqual(state.table.rules?.spectatorsAllowed, false)
        XCTAssertEqual(state.history, []); XCTAssertNil(state.seat(of: "zey")); XCTAssertFalse(state.isMyTurn("zey"))
    }
    func testSeatTakeoverOffersTheReturn() throws {
        let takenOver = holdemPlaying.replacingOccurrences(of: recovery, with: #"{"disconnectedAt":1000,"takeoverAt":31000,"pendingReturn":false,"takeover":true,"events":[{"id":"e1","at":31000,"hand":1,"type":"takeover-started"},{"id":"e2","at":76000,"hand":1,"type":"turn-timeout","action":"fold","toCall":10}]}"#)
        let recovery = try XCTUnwrap(try game(takenOver).table.ownRecovery)
        XCTAssertTrue(recovery.canRequestReturn); XCTAssertEqual(recovery.events?.last?.toCall, 10)
    }
    func testUnknownGameKindDecodesWithoutAHand() throws {
        let state = try game(#"""
        {"kind":"tavla","ownerId":"ece","status":"rolling","seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":0,"connected":true}],
         "turn":0,"view":{"board":[[2,0],[0,5]],"dice":[6,6],"legalActions":["roll"],"capacity":2,"newField":{"x":1}},"history":[]}
        """#)
        XCTAssertEqual(state.kind, .unknown("tavla")); XCTAssertFalse(state.kind.known); XCTAssertEqual(state.kind.title, "Oyun masası")
        XCTAssertEqual(state.status, .unknown("rolling")); XCTAssertNil(state.hand)
        XCTAssertEqual(state.table.legalActions, ["roll"]); XCTAssertEqual(state.legalActions, []); XCTAssertEqual(state.freeSeats, [1])
        XCTAssertEqual(state.view["dice"], .array([.number(6), .number(6)]))
    }
    func testNewFieldsAndAMalformedHandKeepTheTable() throws {
        // An extra key is ignored; a hand that does not match its kind leaves only the table part.
        let state = try game(#"""
        {"kind":"blackjack","ownerId":"ece","status":"playing","seats":[],"turn":null,"extra":true,
         "view":{"dealer":"broken","legalActions":["hit"],"capacity":7,"spectators":"broken"},"history":"broken"}
        """#)
        XCTAssertNil(state.blackjack); XCTAssertEqual(state.legalActions, [.hit]); XCTAssertEqual(state.table.spectators, []); XCTAssertEqual(state.history, [])
    }
    func testAMalformedGameNeverHidesTheRoom() throws {
        let polls = #"[{"id":"p1","question":"Kim kazanır?","options":[{"id":"o1","label":"Ece"},{"id":"o2","label":"Can"}],"votes":{},"createdBy":"ece","closed":false}]"#
        let broken = try room(game: #"{"kind":"holdem","status":"playing"}"#, polls: polls)
        XCTAssertNil(broken.game); XCTAssertEqual(broken.polls?.first?.id, "p1"); XCTAssertTrue(broken.primary?.isGame == true)
        XCTAssertNil(try room(game: nil).game); XCTAssertNil(try room(game: "null").game)
    }
    func testRoomWithAGameRoundTrips() throws {
        let original = try room(game: holdemPlaying)
        let again = try JSONDecoder().decode(ActivityRoom.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(again, original)
    }

    // MARK: Commands

    private func command(_ game: GameCommand) -> JSONValue { ActivityCommand.game(game).json }
    private func object(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    func testTableCommandsMatchTheStrictSchema() {
        XCTAssertEqual(command(.create(.blackjack)), object(["type": .string("game.create"), "game": .string("blackjack")]))
        XCTAssertEqual(command(.create(.batak(.kozMaca))), object(["type": .string("game.create"), "game": .string("batak"), "variant": .string("koz-maca")]))
        XCTAssertEqual(command(.create(.okey101(folding: true, teams: false))),
                       object(["type": .string("game.create"), "game": .string("101"), "folding": .bool(true), "teams": .bool(false)]))
        XCTAssertEqual(command(.create(.holdem(nil))), object(["type": .string("game.create"), "game": .string("holdem")]))
        var rules = HoldemTableRules.standard; rules.name = "  Cuma masası  "; rules.capacity = 6
        XCTAssertTrue(rules.valid)
        let rulesJSON = object(["name": .string("Cuma masası"), "capacity": .number(6), "smallBlind": .number(10), "bigBlind": .number(20),
                                "minBuyIn": .number(1000), "maxBuyIn": .number(1000), "initialChips": .number(1000), "spectatorsAllowed": .bool(true)])
        let primary = ActivityPrimary(activity: "hall", title: "Sinema salonu", hostUserId: "ece", startedAt: 1_700_000_000_000, controlMode: nil, controllers: nil)
        XCTAssertEqual(command(.create(.holdem(rules), replacing: GameReplacement(primary))),
                       object(["type": .string("game.create"), "game": .string("holdem"), "holdem": rulesJSON,
                               "replacePrimary": object(["activity": .string("hall"), "startedAt": .number(1_700_000_000_000)])]))
        XCTAssertEqual(command(.configure(rules)), object(["type": .string("game.configure"), "holdem": rulesJSON]))
        XCTAssertEqual(command(.watch(true)), object(["type": .string("game.watch"), "watching": .bool(true)]))
        XCTAssertEqual(command(.sit(seat: 3)), object(["type": .string("game.sit"), "seat": .number(3)]))
        XCTAssertEqual(command(.sit(seat: 12, buyIn: 500)), object(["type": .string("game.sit"), "seat": .number(8), "buyIn": .number(500)]))
        XCTAssertEqual(command(.addBot(seat: 2)), object(["type": .string("game.bot.add"), "seat": .number(2)]))
        XCTAssertEqual(command(.leave), object(["type": .string("game.leave")]))
        var bad = rules; bad.minBuyIn = 10
        XCTAssertFalse(bad.valid); XCTAssertNil(GameReplacement(nil))
    }
    func testGameActionsMatchTheStrictSchema() {
        func action(_ value: GameAction) -> JSONValue { ActivityCommand.game(.action(value)).json }
        func expect(_ name: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            .object(extra.merging(["type": .string("game.action"), "action": .string(name)]) { $1 })
        }
        for (value, name) in [(GameAction.start, "start"), (.fold, "fold"), (.check, "check"), (.call, "call"), (.hit, "hit"), (.stand, "stand"),
                              (.double, "double"), (.split, "split"), (.pass, "pass"), (.draw, "draw")] {
            XCTAssertEqual(action(value), expect(name))
        }
        XCTAssertEqual(action(.raise(to: 60)), expect("raise", ["amount": .number(60)]))
        XCTAssertEqual(action(.raise(to: 5_000_000)), expect("raise", ["amount": .number(1_000_000)]))
        XCTAssertEqual(action(.bet(10)), expect("bet", ["amount": .number(10)]))
        XCTAssertEqual(action(.bid(8)), expect("bid", ["amount": .number(8)]))
        XCTAssertEqual(action(.trump(.hearts)), expect("trump", ["trump": .string("hearts")]))
        XCTAssertEqual(action(.bury(cardIDs: ["a", "b", "c", "d"])), expect("bury", ["tileIds": .array(["a", "b", "c", "d"].map(JSONValue.string))]))
        XCTAssertEqual(action(.play(cardID: "0-hearts-12")), expect("play", ["cardId": .string("0-hearts-12")]))
        XCTAssertEqual(action(.takeDiscard), expect("draw", ["cardId": .string("discard")]))
        XCTAssertEqual(action(.discard(tileID: "red-3-0")), expect("discard", ["cardId": .string("red-3-0")]))
        XCTAssertEqual(action(.open(melds: [["r1", "r2", "r3"], ["b5", "y5", "k5"]])),
                       expect("open", ["melds": .array([.array(["r1", "r2", "r3"].map(JSONValue.string)), .array(["b5", "y5", "k5"].map(JSONValue.string))])]))
        XCTAssertEqual(action(.openPairs([["a", "b"]])), expect("open-pairs", ["melds": .array([.array([.string("a"), .string("b")])])]))
        XCTAssertEqual(action(.process(meld: 2, tileIDs: ["r4"])), expect("process", ["amount": .number(2), "tileIds": .array([.string("r4")])]))
        XCTAssertEqual(action(.process(meld: 0, tileIDs: ["red-12-1"], replacingJoker: "blue-1-1")),
                       expect("process", ["amount": .number(0), "tileIds": .array([.string("red-12-1")]), "cardId": .string("blue-1-1")]))
        let many = (0..<40).map { "t\($0)" }
        XCTAssertEqual(action(.process(meld: 0, tileIDs: many))["tileIds"].array.count, 30)
        XCTAssertEqual(GameAction.takeDiscard.kind, .draw); XCTAssertEqual(GameActionKind.allCases.count, 20)
    }
    func testGameCommandsTravelInTheActivityEnvelope() {
        let envelope = ActivityCommand.envelope(.game(.action(.call)), commandID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, expectedRevision: 9)
        XCTAssertEqual(envelope, .object(["protocolVersion": .number(1), "commandId": .string("00000000-0000-0000-0000-000000000002"), "expectedRevision": .number(9),
                                          "command": .object(["type": .string("game.action"), "action": .string("call")])]))
    }
    func testGameErrorsUseDesktopText() {
        XCTAssertEqual(ActivityError(code: "NOT_YOUR_TURN").errorDescription, "Şu anda sıra sende değil. Masa güncellendiğinde yeniden dene.")
        XCTAssertEqual(ActivityError(code: "TAKE_A_SEAT_FIRST").errorDescription, "Önce masada boş bir koltuğa otur.")
        XCTAssertNotEqual(ActivityError(code: "ILLEGAL_CARD").errorDescription, ActivityError(code: "SOMETHING_NEW").errorDescription)
    }
}

private extension GameTableView {
    /// A view with only `legalActions` set (the rest at their defaults).
    init(from _: [Never], legal: [String]) {
        self.init(ownRecovery: nil, tableName: nil, rules: nil, spectators: [], watching: false, spectatorAccess: false,
                  legalActions: legal, turnDeadline: nil, capacity: nil, statistics: [:])
    }
}

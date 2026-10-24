import XCTest
@testable import RoomsCore

/// Wave 2 protocol: the registry games (Pişti, Okey, Tavla), `game.create.options`, `game.action.payload`,
/// `game.seat.remove`, `legalActions` names and match `view.series`. Fixtures are hand-written from
/// `packages/games/src/{pisti,okey-classic,tavla,match}.ts` and `packages/activity-protocol/src/index.ts`.
final class GamesRegistryTests: XCTestCase {
    private func state(_ json: String) throws -> GameState { try JSONDecoder().decode(GameState.self, from: Data(json.utf8)) }
    private func seat(_ number: Int, _ id: String, bot: Bool = false, connected: Bool = true) -> String {
        #"{"seat":\#(number),"userId":"\#(id)","name":"\#(id.capitalized)","bot":\#(bot),"chips":0,"connected":\#(connected)}"#
    }
    private func command(_ game: GameCommand) -> JSONValue { ActivityCommand.game(game).json }

    // MARK: Kinds

    func testRegistryKindsAreFirstClass() {
        XCTAssertEqual(GameKind(rawValue: "rooms-pisti-v1"), .pisti)
        XCTAssertEqual(GameKind(rawValue: "rooms-okey-v1"), .okey)
        XCTAssertEqual(GameKind(rawValue: "rooms-tavla-v1"), .tavla)
        XCTAssertEqual(GameKind.allCases.map(\.rawValue), ["holdem", "blackjack", "batak", "101", "rooms-pisti-v1", "rooms-okey-v1", "rooms-tavla-v1"])
        XCTAssertEqual(GameKind.allCases.map(\.title), ["Texas Hold’em", "Blackjack", "Batak", "101 Okey", "Pişti", "Okey", "Tavla"])
        XCTAssertTrue(GameKind.allCases.allSatisfy { $0.known && !$0.playersLine.isEmpty && !$0.seatCounts.isEmpty && $0.fallbackCapacity > 0 })
        XCTAssertEqual(GameKind.pisti.seatCounts, [2, 4]); XCTAssertEqual(GameKind.tavla.fallbackCapacity, 2)
        XCTAssertTrue(GameKind.tavla.prefersLandscape); XCTAssertTrue(GameKind.okey.prefersLandscape); XCTAssertFalse(GameKind.pisti.prefersLandscape)
        // A later registry game still decodes as a table this build cannot play.
        XCTAssertEqual(GameKind(rawValue: "rooms-domino-v1"), .unknown("rooms-domino-v1"))
        XCTAssertFalse(GameKind(rawValue: "rooms-domino-v1").known)
        for kind in GameKind.allCases { XCTAssertEqual(GameKind(rawValue: kind.rawValue), kind) }
    }
    func testPrimaryRecognisesEveryKnownGame() {
        func primary(_ activity: String) -> ActivityPrimary {
            ActivityPrimary(activity: activity, title: "Masa", hostUserId: "ece", startedAt: 1, controlMode: nil, controllers: nil)
        }
        XCTAssertTrue(primary("rooms-tavla-v1").isGame); XCTAssertTrue(primary("rooms-pisti-v1").isGame); XCTAssertTrue(primary("101").isGame)
        XCTAssertFalse(primary("hall").isGame); XCTAssertFalse(primary("youtube").isGame)
    }

    // MARK: Views

    private var pisti: String { #"""
    {"kind":"rooms-pisti-v1","ownerId":"ece","status":"playing","seats":[\#(seat(1, "can")),\#(seat(0, "ece"))],"turn":0,
     "view":{"seats":2,"teams":false,"target":151,"viewerSeat":0,"turn":0,
       "hand":[{"id":"0-clubs-11","suit":"clubs","rank":11},{"id":"0-hearts-7","suit":"hearts","rank":7}],
       "handCounts":[2,3],"tableCount":5,"tableTop":{"id":"0-spades-7","suit":"spades","rank":7},"deckCount":30,
       "capturedCounts":[4,0],"pisti":[1,0],"jackPisti":[0,0],"lastPlay":null,"lastCapture":null,"result":null,
       "series":{"totals":[34,12],"rounds":[{"points":[34,12],"winners":[0]}],"winners":null,
                 "previous":{"seats":2,"result":{"points":[34,12],"winners":[0]}}},
       "legalActions":["play"],"turnDeadline":91000,"capacity":2,"spectators":[],"watching":false,"spectatorAccess":true,
       "rules":{"target":151,"reshuffleJackTop":true},"statistics":{}},
     "history":[]}
    """# }

    /// What a per-game file would declare for its own view.
    private struct PistiViewProbe: Decodable {
        let target: Int
        let hand: [PlayingCard]?
        let tableTop: PlayingCard?
        let handCounts: [Int]
        let deckCount: Int
    }
    func testPistiDecodesWithSeriesAndItsOwnView() throws {
        let game = try state(pisti)
        XCTAssertEqual(game.kind, .pisti); XCTAssertNil(game.hand); XCTAssertNil(game.table.rules)
        XCTAssertEqual(game.legalActions, [.play]); XCTAssertTrue(game.can("play")); XCTAssertTrue(game.isMyTurn("ece"))
        XCTAssertEqual(game.capacity, 2); XCTAssertEqual(game.freeSeats, [])
        let series = try XCTUnwrap(game.table.series)
        XCTAssertEqual(series.totals, [34, 12]); XCTAssertEqual(series.rounds.first?.winners, [0]); XCTAssertFalse(series.finished)
        XCTAssertEqual(series.previous?["seats"], .number(2))
        let view = try XCTUnwrap(game.view(as: PistiViewProbe.self))
        XCTAssertEqual(view.target, 151); XCTAssertEqual(view.hand?.first?.rankLabel, "J"); XCTAssertEqual(view.tableTop?.suit, .spades)
        XCTAssertEqual(view.handCounts, [2, 3]); XCTAssertEqual(view.deckCount, 30)
        // A view that does not match the type is nil, never a thrown error.
        struct Wrong: Decodable { let board: [Int] }
        XCTAssertNil(game.view(as: Wrong.self))
    }
    func testOkeyDecodesWithRegistryActionNames() throws {
        let game = try state(#"""
        {"kind":"rooms-okey-v1","ownerId":"ece","status":"playing",
         "seats":[\#(seat(0, "ece")),\#(seat(1, "bot-1", bot: true)),\#(seat(2, "can", connected: false)),\#(seat(3, "bot-2", bot: true))],"turn":0,
         "view":{"kind":"rooms-okey-v1","options":{"scoring":"countdown","startingPoints":20},"indicator":{"id":"red-5-0","color":"red","value":5},
           "okey":{"color":"red","value":6},"stockCount":48,"first":0,"turn":0,"stage":"discard","viewerSeat":0,
           "hand":[{"id":"blue-1-0","color":"blue","value":1}],"seats":[],"canShowIndicator":true,"indicatorShown":null,
           "lastAction":null,"outcome":null,"finish":null,"result":null,
           "legalActions":["discard","finish","show-indicator"],"capacity":4},
         "history":[]}
        """#)
        XCTAssertEqual(game.kind, .okey); XCTAssertNil(game.hand); XCTAssertNil(game.table.series)
        XCTAssertEqual(game.legalActions, [.discard, .finish, .showIndicator])
        XCTAssertEqual(game.position(of: "can"), 2)
        struct Probe: Decodable { let indicator: OkeyTile; let hand: [OkeyTile]?; let stockCount: Int }
        let view = try XCTUnwrap(game.view(as: Probe.self))
        XCTAssertEqual(view.indicator.value, 5); XCTAssertEqual(view.hand?.first?.color, .blue); XCTAssertEqual(view.stockCount, 48)
        // Seat removal: owner or room host, bot or away seats, never their own.
        let bot = try XCTUnwrap(game.seat(of: "bot-1")), away = try XCTUnwrap(game.seat(of: "can")), own = try XCTUnwrap(game.seat(of: "ece"))
        XCTAssertTrue(game.canRemove(bot, viewer: "ece", roomHost: false)); XCTAssertTrue(game.canRemove(away, viewer: "ece", roomHost: false))
        XCTAssertFalse(game.canRemove(own, viewer: "ece", roomHost: true))
        XCTAssertFalse(game.canRemove(bot, viewer: "zey", roomHost: false)); XCTAssertTrue(game.canRemove(bot, viewer: "zey", roomHost: true))
        XCTAssertFalse(game.canRemove(bot, viewer: nil, roomHost: true))
    }
    func testTavlaMatchEndOffersTheRematch() throws {
        let game = try state(#"""
        {"kind":"rooms-tavla-v1","ownerId":"ece","status":"finished","seats":[\#(seat(0, "ece")),\#(seat(1, "can"))],"turn":null,
         "view":{"kind":"rooms-tavla-v1","phase":"ended","you":0,"turn":null,"points":[{"seat":null,"count":0}],"bar":[0,0],"off":[15,3],
           "pips":[0,120],"opening":[5,3],"openingTie":null,"dice":null,"remaining":[],"moves":[],"legalMoves":[],"canUndo":false,
           "canConfirm":false,"lastTurn":null,"result":null,"match":{"matchTo":5,"scores":[5,2],"starterRerolls":false},
           "series":{"totals":[5,2],"rounds":[{"points":[2,0],"winners":[0]},{"points":[0,2],"winners":[1]}],"winners":[0],"previous":null},
           "legalActions":["start"],"capacity":2},
         "history":[]}
        """#)
        XCTAssertEqual(game.kind, .tavla); XCTAssertTrue(game.canDeal); XCTAssertEqual(game.legalActions, [.start])
        let series = try XCTUnwrap(game.table.series)
        XCTAssertTrue(series.finished); XCTAssertEqual(series.winners, [0]); XCTAssertNil(series.previous); XCTAssertEqual(series.rounds.count, 2)
        XCTAssertNil(game.turnSecondsLeft(nowMs: 0, serverOffsetMs: 0))
    }
    func testABrokenSeriesKeepsTheTable() throws {
        let game = try state(#"""
        {"kind":"rooms-pisti-v1","ownerId":"ece","status":"waiting","seats":[],"turn":null,
         "view":{"series":"broken","legalActions":["start"],"capacity":4},"history":[]}
        """#)
        XCTAssertNil(game.table.series); XCTAssertEqual(game.freeSeats, [0, 1, 2, 3]); XCTAssertTrue(game.canDeal)
    }
    func testNewActionKindsComeThroughLegalActions() throws {
        let game = try state(#"""
        {"kind":"blackjack","ownerId":"ece","status":"playing","seats":[],"turn":0,
         "view":{"legalActions":["insurance","decline-insurance","surrender","later-thing"],"capacity":7},"history":[]}
        """#)
        XCTAssertEqual(game.legalActions, [.insurance, .declineInsurance, .surrender]); XCTAssertTrue(game.can("later-thing"))
    }

    // MARK: Commands

    func testCreateOptionsPerGame() {
        XCTAssertEqual(command(.create(.pisti(PistiTableOptions(target: 251, reshuffleJackTop: false)))),
                       .object(["type": .string("game.create"), "game": .string("rooms-pisti-v1"),
                                "options": .object(["target": .number(251), "reshuffleJackTop": .bool(false)])]))
        // An unsupported target falls back to the service default instead of being rejected.
        XCTAssertEqual(command(.create(.pisti(PistiTableOptions(target: 99))))["options"]["target"], .number(151))
        XCTAssertEqual(command(.create(.okey(OkeyTableOptions(scoring: .winner)))),
                       .object(["type": .string("game.create"), "game": .string("rooms-okey-v1"), "options": .object(["scoring": .string("winner")])]))
        XCTAssertEqual(command(.create(.tavla())),
                       .object(["type": .string("game.create"), "game": .string("rooms-tavla-v1"),
                                "options": .object(["matchTo": .number(5), "starterRerolls": .bool(false)])]))
        XCTAssertEqual(command(.create(.blackjack(BlackjackTableOptions(insurance: false, surrender: true))))["options"],
                       .object(["insurance": .bool(false), "surrender": .bool(true)]))
        XCTAssertEqual(command(.create(.batak(.ihaleli, rules: BatakHouseRules(noTrumpLeadUntilBroken: false, writeContract: true))))["options"],
                       .object(["noTrumpLeadUntilBroken": .bool(false), "defenderBatakPenalty": .bool(false), "writeContract": .bool(true)]))
        XCTAssertEqual(command(.create(.holdem(nil, muckLosers: true))),
                       .object(["type": .string("game.create"), "game": .string("holdem"), "options": .object(["muckLosers": .bool(true)])]))
        // 101 keeps its flat fields and sends no options.
        XCTAssertEqual(command(.create(.okey101(folding: false, teams: true)))["options"], .null)
    }
    func testCustomOptionsFollowTheProtocolShape() {
        var options: GameOptions = ["bad key": .bool(true), "1st": .bool(true), "label": .string(String(repeating: "x", count: 80)),
                                    "nan": .number(.nan), "level": .number(3)]
        for index in 0..<20 { options["k\(index)"] = .bool(true) }
        let encoded = command(.create(.custom(kind: .unknown("rooms-domino-v1"), options: options)))
        XCTAssertEqual(encoded["game"], .string("rooms-domino-v1"))
        let sent = try? XCTUnwrap(encoded["options"].object)
        XCTAssertNil(sent?["bad key"]); XCTAssertNil(sent?["1st"]); XCTAssertNil(sent?["nan"])
        XCTAssertLessThanOrEqual(sent?.count ?? 99, 16)
        XCTAssertEqual(command(.create(.custom(kind: .tavla, options: ["label": .string(String(repeating: "x", count: 80))])))["options"]["label"].string?.count, 64)
        XCTAssertEqual(command(.create(.custom(kind: .tavla, options: [:])))["options"], .null)
    }
    func testRegistryMovesUsePayload() {
        func expect(_ name: String, _ payload: JSONValue?) -> JSONValue {
            var value: [String: JSONValue] = ["type": .string("game.action"), "action": .string(name)]
            if let payload { value["payload"] = payload }
            return .object(value)
        }
        XCTAssertEqual(command(GameMove.pistiPlay(cardID: "0-clubs-11")), expect("play", .object(["cardId": .string("0-clubs-11")])))
        XCTAssertEqual(command(GameMove.okeyDraw(fromDiscard: true)), expect("draw", .object(["from": .string("discard")])))
        XCTAssertEqual(command(GameMove.okeyDraw(fromDiscard: false)), expect("draw", .object(["from": .string("stock")])))
        XCTAssertEqual(command(GameMove.okeyDiscard(tileID: "red-5-1")), expect("discard", .object(["tileId": .string("red-5-1")])))
        XCTAssertEqual(command(GameMove.okeyFinish(tileID: "red-5-1")), expect("finish", .object(["tileId": .string("red-5-1")])))
        XCTAssertEqual(command(GameMove.okeyShowIndicator), expect("show-indicator", nil))
        XCTAssertEqual(command(GameMove.tavlaRoll), expect("roll", nil))
        XCTAssertEqual(command(GameMove.tavlaMove(from: .bar, to: .point(20), die: 5)),
                       expect("move", .object(["from": .string("bar"), "to": .number(20), "die": .number(5)])))
        XCTAssertEqual(command(GameMove.tavlaMove(from: .point(30), to: .off)), expect("move", .object(["from": .number(23), "to": .string("off")])))
        XCTAssertEqual(command(GameMove.tavlaUndo), expect("undo", nil)); XCTAssertEqual(command(GameMove.tavlaConfirm), expect("confirm", nil))
    }
    func testActShapeCheck() {
        XCTAssertTrue(GameCommand.act(name: "show-indicator").valid)
        XCTAssertFalse(GameCommand.act(name: "Bad").valid); XCTAssertFalse(GameCommand.act(name: "").valid)
        XCTAssertFalse(GameCommand.act(name: "start", payload: .object([:])).valid)
        XCTAssertFalse(GameCommand.act(name: "play", payload: .string(String(repeating: "x", count: 9000))).valid)
        XCTAssertTrue(GameCommand.removeSeat(seat: 2).valid)
    }
    func testBuiltInTableRuleActionsAndSeatRemoval() {
        func action(_ value: GameAction) -> JSONValue { ActivityCommand.game(.action(value)).json }
        for (value, name) in [(GameAction.surrender, "surrender"), (.insurance, "insurance"), (.declineInsurance, "decline-insurance"), (.gosterge, "gosterge")] {
            XCTAssertEqual(action(value), .object(["type": .string("game.action"), "action": .string(name)]))
        }
        XCTAssertEqual(action(.open(melds: [["a", "b", "c"], ["d", "e", "f"]], kinds: [.run, nil]))["meldKinds"], .array([.string("run"), .null]))
        XCTAssertEqual(action(.open(melds: [["a", "b", "c"]]))["meldKinds"], .null)
        XCTAssertEqual(command(.removeSeat(seat: 3)), .object(["type": .string("game.seat.remove"), "seat": .number(3)]))
        XCTAssertEqual(command(.removeSeat(seat: 40))["seat"], .number(11))
        XCTAssertEqual(command(.addBot(seat: 10))["seat"], .number(10))
    }
    func testNewGameErrorsUseDesktopText() {
        XCTAssertEqual(ActivityError(code: "SEAT_REMOVE_NOT_ALLOWED").errorDescription, "Yalnızca bir botun ya da masada olmayan bir oyuncunun koltuğu boşaltılabilir.")
        XCTAssertEqual(ActivityError(code: "ROLL_REQUIRED").errorDescription, "Önce zar at.")
        XCTAssertEqual(ActivityError(code: "ROUND_FINISHED").errorDescription, ActivityError(code: "HAND_FINISHED").errorDescription)
        XCTAssertEqual(ActivityError(code: "CANNOT_SHOW_INDICATOR").errorDescription, ActivityError(code: "GOSTERGE_NOT_ALLOWED").errorDescription)
        let fallback = ActivityError(code: "SOMETHING_NEW").errorDescription
        for code in ["UNKNOWN_GAME", "INVALID_OPTIONS", "INSURANCE_DECISION_REQUIRED", "STOCK_EMPTY", "ILLEGAL_MOVE", "NOTHING_TO_UNDO", "ROUND_OVER", "SEAT_EMPTY"] {
            XCTAssertNotEqual(ActivityError(code: code).errorDescription, fallback, code)
        }
    }
}

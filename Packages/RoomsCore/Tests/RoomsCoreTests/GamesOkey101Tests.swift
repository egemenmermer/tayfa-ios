import XCTest
@testable import RoomsCore

/// 101 Okey iPhone table logic. Expectations mirror the desktop tests (games-okey101-view, okey101 arrange) and the
/// engine rules in `packages/games/src/okey101*.ts`.
final class GamesOkey101Tests: XCTestCase {
    private func tile(_ color: OkeyColor, _ value: Int, copy: Int = 0) -> OkeyTile { OkeyTile(id: "\(color.rawValue)-\(value)-\(copy)", color: color, value: value) }
    /// A real okey; its own face does not matter for readings.
    private func okey(_ n: Int = 0) -> OkeyTile { OkeyTile(id: "okey-\(n)", color: .blue, value: 4, joker: true) }

    private func state(stage: String = "discard", turn: Int = 0, legal: [String], options: String = #","options":{"wrapAround":false,"pickupPenalty":true,"pickupUndo":false}"#,
                       hand: String = #"[{"id":"red-7-0","color":"red","value":7},{"id":"red-8-0","color":"red","value":8}]"#,
                       discards: String = #"[[],[],[],[{"id":"black-4-0","color":"black","value":4}]]"#, myCount: Int = 2, extra: String = "") throws -> GameState {
        let json = #"""
        {"kind":"101","ownerId":"ece","status":"playing",
         "seats":[{"seat":0,"userId":"ece","name":"Ece","bot":false,"chips":0,"connected":true},
                  {"seat":1,"userId":"bot-1","name":"Bot 2","bot":true,"chips":0,"connected":true},
                  {"seat":2,"userId":"zey","name":"Zeynep","bot":false,"chips":0,"connected":true},
                  {"seat":3,"userId":"can","name":"Can","bot":false,"chips":0,"connected":true}],
         "turn":\#(turn),
         "view":{"rules":{"id":"rooms-101-v2","folding":false,"teams":false,"openingMinimum":101,"pairsMinimum":5\#(options)},
           "indicator":{"id":"blue-3-0","color":"blue","value":3},"remainingStock":40,"turn":\#(turn),"stage":"\#(stage)","highestOpening":100,
           "highestPairs":0,"requiredPairs":5,"melds":[],"opened":[null,null,null,null],"discards":\#(discards),"scores":[],"winner":null,
           "penalties":[0,0,0,0],"penaltyLog":[],"gostergeShown":[false,false,false,false],"ending":null,
           "hands":[{"seat":0,"tiles":\#(hand),"count":\#(myCount)},{"seat":1,"tiles":[],"count":21},{"seat":2,"tiles":[],"count":21},{"seat":3,"tiles":[],"count":21}],
           "spectators":[],"watching":false,"spectatorAccess":true,"legalActions":\#(legal),"capacity":4,"statistics":{}\#(extra)},
         "history":[]}
        """#
        return try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
    }

    // MARK: Preview readings

    func testTwelveWithTwoOkeysReadsAsAGroupWithoutWrapAndIsAmbiguousWithIt() throws {
        let meld = [tile(.red, 12), okey(0), okey(1)]
        XCTAssertEqual(Okey101Preview.readings(meld, wrapAround: false), [.group])
        XCTAssertFalse(Okey101Preview.isAmbiguous(meld, wrapAround: false))
        let group = try Okey101Preview.resolve(meld, pairs: false, wrapAround: false)
        XCTAssertEqual(group.map(\.value), [12, 12, 12])
        XCTAssertEqual(Set(group.map(\.color)), [.red, .yellow, .blue])
        XCTAssertEqual(try Okey101Preview.meldPoints(group, wrapAround: false), 36)
        // 12-13-1 is allowed on this table: both readings are legal, the run is the default, the hint picks.
        XCTAssertEqual(Okey101Preview.readings(meld, wrapAround: true), [.run, .group])
        XCTAssertTrue(Okey101Preview.isAmbiguous(meld, wrapAround: true))
        let run = try Okey101Preview.resolve(meld, pairs: false, wrapAround: true)
        XCTAssertEqual(run.map(\.value), [12, 13, 1]); XCTAssertTrue(run.allSatisfy { $0.color == .red })
        XCTAssertEqual(try Okey101Preview.meldPoints(run, wrapAround: true), 36) // high 1 counts 11
        XCTAssertEqual(try Okey101Preview.resolve(meld, pairs: false, kind: .group, wrapAround: true).map(\.value), [12, 12, 12])
    }

    func testRunsAndTheTwelveThirteenOneWrapOnlyWhenAllowed() throws {
        XCTAssertEqual(try Okey101Preview.meldPoints([tile(.blue, 7), tile(.blue, 8), tile(.blue, 9)], wrapAround: false), 24)
        let natural = [tile(.black, 12), tile(.black, 13), tile(.black, 1)]
        XCTAssertThrowsError(try Okey101Preview.meldPoints(natural, wrapAround: false))
        XCTAssertEqual(try Okey101Preview.meldPoints(natural, wrapAround: true), 36)
        // 13-1-2 is never legal.
        XCTAssertThrowsError(try Okey101Preview.meldPoints([tile(.black, 13), tile(.black, 1), tile(.black, 2)], wrapAround: true))
        // [12, 13, okey]: no reading without wrap, 12-13-1 with it.
        let open = [tile(.red, 12), tile(.red, 13), okey()]
        XCTAssertEqual(Okey101Preview.readings(open, wrapAround: false), [])
        XCTAssertThrowsError(try Okey101Preview.meldPoints(Okey101Preview.resolve(open, pairs: false, wrapAround: false), wrapAround: false))
        XCTAssertEqual(try Okey101Preview.meldPoints(Okey101Preview.resolve(open, pairs: false, wrapAround: true), wrapAround: true), 36)
    }

    func testSevenWithTwoOkeysIsARunByDefaultAndAGroupOnRequest() throws {
        let meld = [tile(.yellow, 7), okey(0), okey(1)]
        XCTAssertTrue(Okey101Preview.isAmbiguous(meld, wrapAround: false))
        XCTAssertEqual(try Okey101Preview.resolve(meld, pairs: false, wrapAround: false).map(\.value), [7, 8, 9])
        XCTAssertEqual(try Okey101Preview.resolve(meld, pairs: false, kind: .group, wrapAround: false).map(\.value), [7, 7, 7])
        // An okey in the middle of a natural run takes the gap; no choice to make.
        let gap = [tile(.red, 3), okey(), tile(.red, 5)]
        XCTAssertFalse(Okey101Preview.isAmbiguous(gap, wrapAround: false))
        XCTAssertEqual(try Okey101Preview.resolve(gap, pairs: false, wrapAround: false)[1].value, 4)
        // A pair okey copies its partner; two okeys alone may only pair.
        XCTAssertEqual(try Okey101Preview.resolve([tile(.red, 9), okey()], pairs: true, wrapAround: false).map(\.value), [9, 9])
        XCTAssertThrowsError(try Okey101Preview.resolve([okey(0), okey(1), okey(2)], pairs: false, wrapAround: false))
    }

    // MARK: Opening builder

    private func hand(_ tiles: [OkeyTile]) -> [OkeyTile] { tiles + [tile(.black, 2, copy: 1)] }
    private func info(folding: Bool = false, highest: Int = 100, wrap: Bool = false, requiredPairs: Int = 5) -> Okey101TableInfo {
        var info = Okey101TableInfo()
        info.folding = folding; info.highestOpening = highest; info.house.wrapAround = wrap; info.requiredPairs = requiredPairs
        return info
    }

    func testOpeningTotalAgainstOneHundredOne() {
        let high = [tile(.red, 11), tile(.red, 12), tile(.red, 13)] // 36
        let groups13 = [tile(.red, 13, copy: 1), tile(.yellow, 13), tile(.blue, 13)] // 39
        let groups10 = [tile(.red, 10), tile(.yellow, 10), tile(.blue, 10)] // 30
        let rack = hand(high + groups13 + groups10)
        let drafts = [high, groups13, groups10].map { Okey101Draft(ids: $0.map(\.id)) }
        let low = Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: false, opened: nil, info: info())
        XCTAssertEqual(low.total, 105); XCTAssertEqual(low.required, 101); XCTAssertTrue(low.ready)
        XCTAssertEqual(low.line, "105 / 101 puan · Hazır")
        let short = Okey101Opening.evaluate(drafts: Array(drafts.prefix(2)), hand: rack, pairs: false, opened: nil, info: info())
        XCTAssertEqual(short.total, 75); XCTAssertFalse(short.ready)
        XCTAssertEqual(short.problem, "Açılış için en az 101 puan gerekir · 75 hazır")
        // Katlamalı: more than the highest opening.
        XCTAssertFalse(Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: false, opened: nil, info: info(folding: true, highest: 105)).ready)
        XCTAssertEqual(Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: false, opened: nil, info: info(folding: true, highest: 104)).required, 105)
        XCTAssertTrue(Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: false, opened: nil, info: info(folding: true, highest: 104)).ready)
        // Opened already: any valid meld goes, no minimum.
        let later = Okey101Opening.evaluate(drafts: [drafts[2]], hand: rack, pairs: false, opened: "runs", info: info())
        XCTAssertTrue(later.ready); XCTAssertEqual(later.line, "30 puan · Hazır")
        // A tile must stay for the discard; an invalid draft blocks.
        XCTAssertEqual(Okey101Opening.evaluate(drafts: drafts, hand: Array(rack.dropLast()), pairs: false, opened: nil, info: info()).problem, "Atmak için bir taş bırak")
        let broken = [Okey101Draft(ids: [high[0].id, groups10[0].id, groups13[1].id])]
        XCTAssertEqual(Okey101Opening.evaluate(drafts: broken, hand: rack, pairs: false, opened: "runs", info: info()).problem, "Hazır gruplardan biri geçersiz")
        XCTAssertEqual(Okey101Opening.evaluate(drafts: [], hand: rack, pairs: false, opened: nil, info: info()).problem, "Açmak için seri veya çift hazırla")
    }

    func testOpeningPreviewUsesTheChosenOkeyReading() {
        // [12, J, J] with wrap: as a run 12-13-1 = 36, as a group 12-12-12 = 36; [7, J, J] 24 run vs 21 group.
        let seven = [tile(.yellow, 7), okey(0), okey(1)]
        let rack = hand(seven)
        let run = Okey101Opening.evaluate(drafts: [Okey101Draft(ids: seven.map(\.id), kind: .run)], hand: rack, pairs: false, opened: "runs", info: info())
        let group = Okey101Opening.evaluate(drafts: [Okey101Draft(ids: seven.map(\.id), kind: .group)], hand: rack, pairs: false, opened: "runs", info: info())
        XCTAssertEqual(run.total, 24); XCTAssertEqual(group.total, 21)
        XCTAssertEqual(group.resolved.first??.map(\.value), [7, 7, 7])
        // A new ambiguous draft starts as Sıralı and sends kinds; plain drafts send none.
        let layout = Okey101Rack.reconcile(nil, ids: rack.map(\.id))
        let draft = Okey101Opening.draft([seven[2].id, seven[0].id, seven[1].id], hand: rack, layout: layout, pairs: false, wrapAround: false)
        XCTAssertEqual(draft.ids, seven.map(\.id)); XCTAssertEqual(draft.kind, .run)
        XCTAssertEqual(Okey101Opening.kinds([draft, Okey101Draft(ids: ["x"])], pairs: false), [.run, nil])
        XCTAssertNil(Okey101Opening.kinds([Okey101Draft(ids: ["x"])], pairs: false))
        XCTAssertNil(Okey101Opening.kinds([draft], pairs: true))
    }

    func testPairsOpeningCountsAgainstTheRequiredPairs() {
        let pairs = (1...5).map { [tile(.red, $0), tile(.red, $0, copy: 1)] }
        let rack = hand(pairs.flatMap { $0 })
        let drafts = pairs.map { Okey101Draft(ids: $0.map(\.id)) }
        let five = Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: true, opened: nil, info: info())
        XCTAssertTrue(five.ready); XCTAssertEqual(five.line, "5 / 5 çift · Hazır")
        let four = Okey101Opening.evaluate(drafts: Array(drafts.prefix(4)), hand: rack, pairs: true, opened: nil, info: info())
        XCTAssertEqual(four.problem, "En az 5 geçerli çift gerekir · 4 hazır")
        XCTAssertFalse(Okey101Opening.evaluate(drafts: drafts, hand: rack, pairs: true, opened: nil, info: info(requiredPairs: 6)).ready)
        let mixed = [Okey101Draft(ids: [tile(.red, 1).id, tile(.red, 2).id])]
        XCTAssertEqual(Okey101Opening.evaluate(drafts: mixed, hand: rack, pairs: true, opened: "pairs", info: info()).problem, "Geçerli çift hazırla")
    }

    // MARK: Rack

    func testSeriDizPutsRunsAndGroupsFirstWithGapsAndLeftoversLast() {
        let tiles = [tile(.black, 9), tile(.red, 7), tile(.red, 5), tile(.yellow, 1), tile(.red, 6), tile(.blue, 9), tile(.red, 9), okey()]
        let layout = Okey101Rack.arrangeRuns(tiles)
        XCTAssertEqual(layout.count, 30)
        let blocks = Okey101Rack.blocks(layout)
        // Best cover: red 5-6-7 and the 9 group with the okey as its fourth tile; yellow 1 is left over.
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], ["red-5-0", "red-6-0", "red-7-0"])
        XCTAssertEqual(Set(blocks[1]), ["red-9-0", "blue-9-0", "black-9-0", "okey-0"])
        XCTAssertEqual(blocks[2], ["yellow-1-0"])
        XCTAssertNil(layout[3]) // one gap between blocks
        // 12-13-1 only on tables that allow it.
        let wrap = [tile(.blue, 12), tile(.blue, 13), tile(.blue, 1), tile(.red, 2)]
        XCTAssertEqual(Okey101Rack.blocks(Okey101Rack.arrangeRuns(wrap, wrapAround: false)), [["red-2-0", "blue-1-0", "blue-12-0", "blue-13-0"]])
        XCTAssertEqual(Okey101Rack.blocks(Okey101Rack.arrangeRuns(wrap, wrapAround: true)).first, ["blue-12-0", "blue-13-0", "blue-1-0"])
    }

    func testCiftDizPairsSameTilesAndGivesAnOkeyToTheHighestSingle() {
        let tiles = [tile(.red, 3), tile(.blue, 11), tile(.red, 3, copy: 1), tile(.black, 5), okey()]
        let blocks = Okey101Rack.blocks(Okey101Rack.arrangePairs(tiles))
        XCTAssertEqual(blocks, [["red-3-0", "red-3-1"], ["blue-11-0", "okey-0"], ["black-5-0"]])
    }

    func testRackMovesReconcileAndValidBlocks() {
        var layout = Okey101Rack.reconcile(nil, ids: ["a", "b", "c"])
        XCTAssertEqual(Array(layout.prefix(4)), ["a", "b", "c", nil])
        layout = Okey101Rack.move(layout, id: "c", to: 0) // pushes a, b right
        XCTAssertEqual(Array(layout.prefix(4)), ["c", "a", "b", nil])
        layout = Okey101Rack.move(layout, id: "a", to: 20)
        XCTAssertEqual(layout[20], "a"); XCTAssertNil(layout[1])
        XCTAssertEqual(Okey101Rack.blocks(layout), [["c"], ["b"], ["a"]])
        // A drawn tile goes to the first free cell; a discarded one leaves.
        let next = Okey101Rack.reconcile(layout, ids: ["a", "c", "d"])
        XCTAssertEqual(next[1], "d"); XCTAssertNil(next[2]); XCTAssertEqual(next[20], "a")
        // Order by rack position, not by tap order.
        XCTAssertEqual(Okey101Opening.rackOrder(["a", "d", "c"], layout: next), ["c", "d", "a"])
        let hand = [tile(.red, 4), tile(.red, 5), tile(.red, 6), tile(.blue, 1)]
        let rack = Okey101Rack.fromBlocks([hand.prefix(3).map(\.id)], rest: ["blue-1-0"])
        XCTAssertEqual(Okey101Rack.validBlocks(rack, hand: hand, excluding: [], pairs: false, wrapAround: false), [["red-4-0", "red-5-0", "red-6-0"]])
        XCTAssertEqual(Okey101Rack.validBlocks(rack, hand: hand, excluding: ["red-5-0"], pairs: false, wrapAround: false), [])
    }

    func testRackStoreKeepsOneEntryPerRound() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "okey101-rack-test"))
        defaults.removePersistentDomain(forName: "okey101-rack-test")
        let store = Okey101RackStore(defaults: defaults)
        let key = Okey101RackStore.key(ownerID: "ece", round: 2, userID: "can", indicatorID: "blue-3-0")
        var layout = Okey101Rack.empty; layout[4] = "red-1-0"
        store.save(key, layout: layout)
        XCTAssertEqual(store.load(key), layout)
        XCTAssertNil(store.load(Okey101RackStore.key(ownerID: "ece", round: 3, userID: "can", indicatorID: "blue-3-0")))
    }

    // MARK: Controls from legalActions

    func testControlsFollowLegalActions() throws {
        let draw = try state(stage: "draw", legal: ["draw"])
        let drawControls = Okey101Controls(game: draw, me: "ece")
        XCTAssertTrue(drawControls.drawStock); XCTAssertTrue(drawControls.takeSide)
        XCTAssertFalse(drawControls.discard); XCTAssertFalse(drawControls.openRuns); XCTAssertFalse(drawControls.undoPick)
        // Nothing to take from the left: only the stock.
        XCTAssertFalse(Okey101Controls(game: try state(stage: "draw", legal: ["draw"], discards: "[[],[],[],[]]"), me: "ece").takeSide)
        // Busy, out of turn, or a spectator: nothing.
        XCTAssertEqual(Okey101Controls(game: draw, me: "ece", busy: true), Okey101Controls())
        XCTAssertEqual(Okey101Controls(game: draw, me: "zey"), Okey101Controls())
        XCTAssertEqual(Okey101Controls(game: draw, me: "nobody"), Okey101Controls())

        let discard = Okey101Controls(game: try state(legal: ["discard", "open", "open-pairs", "gosterge"]), me: "ece")
        XCTAssertTrue(discard.discard); XCTAssertTrue(discard.openRuns); XCTAssertTrue(discard.openPairs); XCTAssertTrue(discard.gosterge)
        XCTAssertFalse(discard.process); XCTAssertFalse(discard.undoPick); XCTAssertFalse(discard.drawStock)
        // Çek undo only when the server lists draw in the discard stage.
        let undo = Okey101Controls(game: try state(legal: ["discard", "open", "process", "draw"], options: #","options":{"pickupPenalty":true,"pickupUndo":true}"#), me: "ece")
        XCTAssertTrue(undo.undoPick); XCTAssertTrue(undo.undoCostsPenalty); XCTAssertTrue(undo.process); XCTAssertFalse(undo.openPairs)
        // v1 profile (no options): undo is free.
        XCTAssertFalse(Okey101Controls(game: try state(legal: ["discard", "draw"], options: ""), me: "ece").undoCostsPenalty)
    }

    func testPickupWarningOnlyWhileTheSideTileIsUnused() throws {
        let game = try state(legal: ["discard", "open"])
        XCTAssertTrue(Okey101Controls.pickupWarning(picked: "red-7-0", game: game, me: "ece"))
        XCTAssertFalse(Okey101Controls.pickupWarning(picked: "black-4-0", game: game, me: "ece"))
        XCTAssertFalse(Okey101Controls.pickupWarning(picked: nil, game: game, me: "ece"))
        XCTAssertFalse(Okey101Controls.pickupWarning(picked: "red-7-0", game: try state(legal: ["discard"], options: ""), me: "ece"))
    }

    // MARK: View extras, places, summary

    func testDecodesHouseRulesAndPlacesSeatsCounterClockwise() throws {
        let game = try state(legal: [], options: #","options":{"wrapAround":true,"islekPenalty":true}"#)
        let info = try XCTUnwrap(game.okey101Info)
        XCTAssertTrue(info.house.wrapAround); XCTAssertTrue(info.house.islekPenalty)
        XCTAssertFalse(info.house.pickupPenalty) // missing key keeps v1
        XCTAssertEqual(info.requiredPairs, 5); XCTAssertEqual(info.openingThreshold, 101)
        XCTAssertEqual(game.okey101TurnPosition, 0)
        // Can at position 3: the next player (0) on the right, the previous (2) on the left — whose pile Can takes.
        XCTAssertEqual(Okey101Place.right.position(base: 3), 0)
        XCTAssertEqual(Okey101Place.left.position(base: 3), 2)
        XCTAssertEqual(Okey101Place.of(position: 2, base: 3), .left)
        XCTAssertEqual(Okey101Place.of(position: 1, base: nil), .right)
    }

    func testRoundSummaryWithPenaltiesAndMultiplier() throws {
        let summary = #"{"scores":[-101,404,202,-101],"winner":0,"rules":{"id":"rooms-101-v2","folding":false,"teams":false},"opened":["runs","runs",null,"pairs"],"penaltyLog":[{"seat":3,"reason":"gosterge","amount":-101},{"seat":1,"reason":"islek","amount":101}],"ending":{"okey":true,"pairs":false,"elden":true,"multiplier":4}}"#
        let info = try JSONDecoder().decode(Okey101TableInfo.self, from: Data(summary.utf8))
        let names = ["Ece", "Bot", "Zeynep", "Can"]
        XCTAssertEqual(Okey101Summary.endingLine(info) { names[$0] }, "Ece elden okey atarak bitirdi")
        XCTAssertEqual(Okey101Summary.multiplierLine(info), "Cezalar ×4")
        let rows = Okey101Summary.rows(info)
        XCTAssertEqual(rows.map(\.status), ["Bitirdi", "Açtı", "Açmadı", "Çift açtı"])
        XCTAssertEqual(rows.map(\.penalty), [0, 101, 0, -101]) // summed from the log (history has no penalties array)
        XCTAssertEqual(rows.map(\.score), [-101, 404, 202, -101])
        XCTAssertEqual(info.penaltyLog.map(\.reasonTitle), ["Göstergeyi gösterdi", "İşlek taş attı"])
        XCTAssertEqual(Okey101Summary.signed(101), "+101"); XCTAssertEqual(Okey101Summary.signed(-101), "-101")
        var none = Okey101TableInfo(); none.winner = nil
        XCTAssertEqual(Okey101Summary.endingLine(none) { names[$0] }, "Taşlar bitti, kimse bitiremedi")
        XCTAssertNil(Okey101Summary.multiplierLine(none))
    }

    func testMoveLogNamesSidePicksDiscardsAndPenalties() throws {
        let names = ["Ece", "Bot", "Zeynep", "Can"]
        let before = try XCTUnwrap(try state(stage: "draw", legal: ["draw"]).okey101)
        let picked = try XCTUnwrap(try state(stage: "discard", legal: [], discards: "[[],[],[],[]]", myCount: 3).okey101)
        let lines = Okey101MoveLog.describe(before: before, beforeLog: [], after: picked, afterLog: [Okey101PenaltyEntry(seat: 0, reason: "pickup", amount: 101)]) { names[$0] }
        XCTAssertEqual(lines, ["Ece yandan Siyah 4 aldı", "Ece · Yandan aldığı taşı kullanmadı · +101"])
        let drew = try XCTUnwrap(try state(stage: "discard", legal: [], myCount: 3).okey101)
        XCTAssertEqual(Okey101MoveLog.describe(before: before, beforeLog: [], after: drew, afterLog: []) { names[$0] }, ["Ece ortadan çekti"])
        let threw = try XCTUnwrap(try state(stage: "draw", turn: 1, legal: [], discards: #"[[{"id":"red-8-0","color":"red","value":8}],[],[],[{"id":"black-4-0","color":"black","value":4}]]"#, myCount: 1).okey101)
        XCTAssertEqual(Okey101MoveLog.describe(before: before, beforeLog: [], after: threw, afterLog: []) { names[$0] }, ["Ece Kırmızı 8 attı"])
        XCTAssertEqual(OkeyTile(id: "false-joker-0", color: .blue, value: 4).okey101Label, "Sahte okey")
        XCTAssertTrue(OkeyTile(id: "false-joker-0", color: .blue, value: 4).okey101IsFake)
        XCTAssertEqual(OkeyTile(id: "x", color: .red, value: 4, joker: true).okey101Label, "Okey · Kırmızı 4")
    }
}

import XCTest
@testable import RoomsCore

/// Classic Okey (`rooms-okey-v1`). Fixtures mirror `tests/okey-classic.test.ts` (engine finish search) and
/// `tests/games-okey-arrange.test.ts` (desktop Seri/Çift diz and the 2x15 rack) in the desktop repository.
final class GamesOkeyTests: XCTestCase {
    private var serial = 0
    private func tile(_ color: OkeyColor, _ value: Int) -> OkeyTile {
        serial += 1
        return OkeyTile(id: "\(color.rawValue)-\(value)-t\(serial)", color: color, value: value)
    }
    private func r(_ v: Int) -> OkeyTile { tile(.red, v) }
    private func y(_ v: Int) -> OkeyTile { tile(.yellow, v) }
    private func b(_ v: Int) -> OkeyTile { tile(.blue, v) }
    private func k(_ v: Int) -> OkeyTile { tile(.black, v) }
    // Engine fixtures: gösterge yellow 6, so the okey is yellow 7.
    private let face = OkeyClassicFace(color: .yellow, value: 7)
    private func okey() -> OkeyTile { serial += 1; return OkeyTile(id: "yellow-7-t\(serial)", color: .yellow, value: 7, joker: true) }
    private func sahte(_ color: OkeyColor = .yellow, _ value: Int = 7) -> OkeyTile { serial += 1; return OkeyTile(id: "false-joker-\(serial)", color: color, value: value) }
    private func valid(_ tiles: [OkeyTile]) -> OkeyClassicArrangement? { OkeyClassicRules.arrangement(tiles, okey: face) }

    /// Natural filler sets adding up to `count` tiles (engine test helper).
    private func filler(_ count: Int) -> [OkeyTile] {
        let sets: [() -> [OkeyTile]] = [
            { [self.b(1), self.b(2), self.b(3)] }, { [self.k(9), self.k(10), self.k(11)] }, { [self.r(4), self.b(4), self.k(4)] },
            { [self.b(9), self.b(10), self.b(11), self.b(12)] }, { [self.k(1), self.k(2), self.k(3), self.k(4), self.k(5)] },
        ]
        let sizes = [3, 3, 3, 4, 5]
        for pick in 1..<(1 << sets.count) where sizes.indices.filter({ pick & (1 << $0) != 0 }).map({ sizes[$0] }).reduce(0, +) == count {
            return sets.indices.filter { pick & (1 << $0) != 0 }.flatMap { sets[$0]() }
        }
        XCTFail("filler cannot make \(count)"); return []
    }

    // MARK: Finish detection (engine port)

    func testRunsIncludingOneAfterThirteen() {
        XCTAssertNotNil(valid([r(12), r(13), r(1)] + filler(11)))
        XCTAssertNotNil(valid([r(11), r(12), r(13), r(1)] + filler(10)))
        XCTAssertNotNil(valid([r(1), r(2), r(3), r(4), r(5), r(6), r(7), b(1), b(2), b(3), k(9), k(10), k(11), k(12)]))
        XCTAssertEqual(valid([r(12), r(13), r(1)] + filler(11))?.pairs, false)
    }
    func testRejectsWrappingPastOneAndBrokenRuns() {
        XCTAssertNil(valid([r(13), r(1), r(2)] + filler(11)))
        XCTAssertNil(valid([r(12), r(13), r(1), r(2)] + filler(10)))
        XCTAssertNil(valid([r(3), r(4), b(5)] + filler(11)))
        XCTAssertNil(valid([r(3), r(5), r(6)] + filler(11)))
    }
    func testGroupsNeedDifferentColors() {
        XCTAssertNotNil(valid([r(8), b(8), k(8), y(8)] + filler(10)))
        XCTAssertNotNil(valid([r(8), b(8), k(8)] + filler(11)))
        XCTAssertNil(valid([r(8), r(8), k(8)] + filler(11)))
        XCTAssertNil(valid([r(8), b(8), k(8), y(8), r(8)] + filler(9)))
    }
    func testOkeyIsWild() {
        XCTAssertNotNil(valid([r(12), r(13), okey()] + filler(11))) // okey = red 1 after 13
        XCTAssertNotNil(valid([r(5), okey(), r(7)] + filler(11)))
        XCTAssertNotNil(valid([r(8), b(8), okey()] + filler(11)))
        XCTAssertNotNil(valid([r(8), okey(), okey()] + filler(11)))
        XCTAssertNil(valid([r(8), b(9), okey()] + filler(11)))
        XCTAssertNotNil(valid([r(13), r(1), okey()] + filler(11))) // okey = red 12
    }
    func testSahteOkeyStandsForTheOkeyFace() {
        XCTAssertNotNil(valid([y(5), y(6), sahte()] + filler(11)))
        XCTAssertNotNil(valid([r(7), b(7), sahte()] + filler(11)))
        XCTAssertNil(valid([r(5), r(6), sahte()] + filler(11)))
        XCTAssertNil(valid([r(9), b(9), sahte()] + filler(11)))
        // Whatever face the tile itself carries, the okey's face decides.
        XCTAssertNotNil(valid([y(5), y(6), sahte(.black, 1)] + filler(11)))
        XCTAssertNil(valid([k(2), k(3), sahte(.black, 1)] + filler(11)))
        XCTAssertFalse(OkeyClassicPiece(sahte(), okey: face).wild)
    }
    func testSevenPairsWithOkeyWild() {
        let pairs = [r(1), r(1), b(5), b(5), k(9), k(9), y(13), y(13), r(4), r(4), b(11), b(11)]
        XCTAssertEqual(valid(pairs + [k(3), k(3)])?.pairs, true)
        XCTAssertEqual(valid(pairs + [k(3), okey()])?.pairs, true)
        XCTAssertEqual(valid(pairs + [sahte(), sahte()])?.pairs, true)
        XCTAssertEqual(valid(Array(pairs.prefix(10)) + [k(3), b(6), okey(), okey()])?.pairs, true)
        XCTAssertEqual(valid(pairs + [okey(), okey()])?.pairs, true)
        XCTAssertNil(valid(pairs + [k(3), k(4)]))
        XCTAssertNil(valid(pairs + [k(3), b(3)]))
        XCTAssertEqual(valid(pairs + [k(3), okey()])?.melds.count, 7)
    }
    func testNeedsFourteenDistinctTiles() {
        XCTAssertNil(valid(Array(filler(14).prefix(13))))
        let set = filler(14)
        XCTAssertNil(valid(Array(set.prefix(13)) + [set[0]]))
        let arrangement = valid([r(12), r(13), okey()] + filler(11))
        XCTAssertEqual(arrangement?.melds.flatMap { $0 }.count, 14)
    }

    // MARK: Desktop rack fixtures (okey red 6)

    private let deskFace = OkeyClassicFace(color: .red, value: 6)
    private func dt(_ color: OkeyColor, _ value: Int, _ copy: Int = 0) -> OkeyTile { OkeyTile(id: "\(color.rawValue)-\(value)-\(copy)", color: color, value: value) }
    private var deskOkey: OkeyTile { OkeyTile(id: "red-6-1", color: .red, value: 6, joker: true) }
    private var deskFake: OkeyTile { OkeyTile(id: "false-joker-0", color: .red, value: 6) }
    private var drawHand: [OkeyTile] {
        [dt(.red, 1), dt(.blue, 7), dt(.black, 10), dt(.red, 3), dt(.yellow, 4), deskOkey, dt(.black, 9), dt(.blue, 7, 1), dt(.red, 2),
         dt(.black, 4), deskFake, dt(.blue, 4), dt(.black, 11), dt(.yellow, 12)]
    }
    private var finishingHand: [OkeyTile] {
        [dt(.red, 1), dt(.blue, 8), dt(.black, 10), dt(.yellow, 13), dt(.red, 3), dt(.yellow, 4), dt(.black, 9), dt(.blue, 7), deskOkey,
         dt(.red, 2), dt(.black, 4), dt(.blue, 9), dt(.blue, 4), dt(.black, 11), dt(.red, 4)]
    }
    /// Consecutive non-empty cells (a row break also ends a block).
    private func blocks(_ layout: OkeyClassicRack.Layout) -> [[String]] {
        var result: [[String]] = [], current: [String] = []
        for (cell, id) in layout.enumerated() {
            if cell % 15 == 0 && !current.isEmpty { result.append(current); current = [] }
            if let id { current.append(id) } else if !current.isEmpty { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func testFinishHelpers() {
        XCTAssertEqual(OkeyClassicRules.finishingTile(finishingHand, okey: deskFace)?.id, "yellow-13-0")
        XCTAssertTrue(OkeyClassicRules.canFinish(finishingHand, with: "yellow-13-0", okey: deskFace))
        XCTAssertFalse(OkeyClassicRules.canFinish(finishingHand, with: "red-1-0", okey: deskFace))
        XCTAssertFalse(OkeyClassicRules.canFinish(finishingHand, with: "missing", okey: deskFace))
        XCTAssertNil(OkeyClassicRules.finishingTile(drawHand, okey: deskFace))
        // An okey that can be thrown is preferred (it doubles the score).
        let rack = [r(12), r(13), r(1)] + filler(11) + [okey()]
        XCTAssertEqual(OkeyClassicRules.finishingTile(rack, okey: face)?.isJoker, true)
    }

    func testSeriDizLaysAFinishingRackWithTheTileToThrowLast() {
        let layout = OkeyClassicRack.arrangeRuns(finishingHand, okey: deskFace)
        XCTAssertEqual(layout.count, OkeyClassicRack.cells)
        let found = blocks(layout)
        XCTAssertEqual(found.last, ["yellow-13-0"])
        XCTAssertEqual(found.dropLast().flatMap { $0 }.count, 14)
        XCTAssertEqual(Set(layout.compactMap { $0 }).count, 15)
    }
    func testSeriDizPutsSetsInBlocksAndLeftoversOnTheRight() {
        let layout = OkeyClassicRack.arrangeRuns(drawHand, okey: deskFace)
        let found = blocks(layout)
        let red = found.first { $0.contains("red-1-0") }!
        XCTAssertEqual(Array(red.prefix(3)), ["red-1-0", "red-2-0", "red-3-0"])
        XCTAssertTrue(found.contains(["black-9-0", "black-10-0", "black-11-0"]))
        let fours = found.first { $0.contains("yellow-4-0") }!
        XCTAssertTrue(Set(fours).isSuperset(of: ["yellow-4-0", "blue-4-0", "black-4-0"]))
        XCTAssertTrue((red + fours).contains("red-6-1"))
        XCTAssertEqual(layout.compactMap { $0 }.sorted(), drawHand.map(\.id).sorted())
        let leftovers = ["blue-7-0", "blue-7-1", "yellow-12-0", "false-joker-0"]
        let lastSet = layout.enumerated().map { cell, id in id.map { leftovers.contains($0) ? -1 : cell } ?? -1 }.max()!
        XCTAssertTrue(leftovers.allSatisfy { layout.firstIndex(of: $0)! > lastSet })
    }
    func testCiftDizPairsSideBySideAndOkeyWithTheHighestSingle() {
        let found = blocks(OkeyClassicRack.arrangePairs(drawHand, okey: deskFace))
        XCTAssertEqual(found[0], ["blue-7-0", "blue-7-1"])
        XCTAssertTrue(found.contains(["yellow-12-0", "red-6-1"]))
        XCTAssertTrue(found.prefix(2).allSatisfy { $0.count == 2 })
        XCTAssertEqual(found.flatMap { $0 }.count, 14)
    }
    func testCiftDizPairsTwoSahteOkeys() {
        let fake2 = OkeyTile(id: "false-joker-1", color: .red, value: 6)
        let found = blocks(OkeyClassicRack.arrangePairs([deskFake, dt(.blue, 2), fake2], okey: deskFace))
        XCTAssertEqual(found[0], ["false-joker-0", "false-joker-1"])
    }

    // MARK: Rack layout

    private func row(_ ids: [String?]) -> OkeyClassicRack.Layout { ids + Array(repeating: nil, count: OkeyClassicRack.cells - ids.count) }

    func testReconcileKeepsPositionsDropsGoneAndFillsFirstGap() {
        XCTAssertEqual(Array(OkeyClassicRack.reconcile(row([nil, "a", nil, "b", "gone"]), ids: ["a", "b", "c"]).prefix(5)), ["c", "a", nil, "b", nil])
        XCTAssertEqual(OkeyClassicRack.reconcile(nil, ids: ["x"]).first!, "x")
    }
    func testMoveToEmptySlideAndSwap() {
        let moved = OkeyClassicRack.move(row(["a", "b"]), id: "a", to: 20)
        XCTAssertNil(moved[0]); XCTAssertEqual(moved[20], "a")
        XCTAssertEqual(Array(OkeyClassicRack.move(row(["a", "b", "c", nil, "d"]), id: "d", to: 1).prefix(5)), ["a", "d", "b", "c", nil])
        let full = (0..<15).map { "t\($0)" }
        let swapped = OkeyClassicRack.move(row(full + ["x"]), id: "x", to: 3)
        XCTAssertEqual(swapped[3], "x"); XCTAssertEqual(swapped[15], "t3")
        XCTAssertEqual(OkeyClassicRack.move(row(["a"]), id: "zz", to: 3), row(["a"]))
    }
    func testBlocksNeverSplitAcrossRows() {
        let layout = OkeyClassicRack.fromBlocks([["a1", "a2", "a3", "a4", "a5"], ["b1", "b2", "b3", "b4", "b5"], ["c1", "c2", "c3", "c4"]], rest: ["r"])
        XCTAssertEqual(Array(layout[12..<15]), [nil, nil, nil])
        XCTAssertEqual(Array(layout[15..<19]), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(layout[20], "r")
    }
    func testRackStoreKeepsRecentRoundsOnly() throws {
        let suite = "okey-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OkeyClassicRackStore(defaults: defaults)
        let layout = row(["a", nil, "b"])
        store.save(layout, for: "k0")
        XCTAssertEqual(store.load("k0"), layout)
        for n in 1...OkeyClassicRackStore.keep { store.save(row(["\(n)"]), for: "k\(n)") }
        XCTAssertNil(store.load("k0"))
        XCTAssertEqual(store.load("k\(OkeyClassicRackStore.keep)")?.first!, "\(OkeyClassicRackStore.keep)")
        XCTAssertNil(store.load("missing"))
    }

    // MARK: View, seats and controls

    private func seatJSON(_ number: Int, _ id: String) -> String {
        #"{"seat":\#(number),"userId":"\#(id)","name":"\#(id.capitalized)","bot":false,"chips":0,"connected":true}"#
    }
    /// A table whose seats are 1, 3, 5, 7 (round indices 0-3 = ali, me, cem, dan) with a classic Okey view.
    private func game(view: String, legal: [String] = [], status: String = "playing", turn: Int = 3, statistics: String = "{}") throws -> GameState {
        let seats = [seatJSON(1, "ali"), seatJSON(3, "me"), seatJSON(5, "cem"), seatJSON(7, "dan")].joined(separator: ",")
        let legalJSON = "[" + legal.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = #"{"kind":"rooms-okey-v1","ownerId":"ali","status":"\#(status)","seats":[\#(seats)],"turn":\#(turn),"history":[],"#
            + #""view":{"spectatorAccess":true,"legalActions":\#(legalJSON),"statistics":\#(statistics),\#(view)}}"#
        return try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
    }
    private let tileJSON = { (id: String, color: String, value: Int) in #"{"id":"\#(id)","color":"\#(color)","value":\#(value)}"# }
    private func viewJSON(stage: String = "draw", turn: String = "1", viewer: String = "1", hand: String = "[]", leftPile: String = "[]",
                          extra: String = "") -> String {
        #""kind":"rooms-okey-v1","options":{"scoring":"countdown","startingPoints":20},"indicator":\#(tileJSON("yellow-6-0", "yellow", 6)),"#
            + #""okey":{"color":"yellow","value":7},"stockCount":40,"first":0,"turn":\#(turn),"stage":"\#(stage)","viewerSeat":\#(viewer),"hand":\#(hand),"#
            + #""seats":[{"seat":0,"tileCount":14,"discards":\#(leftPile),"showedIndicator":false},{"seat":1,"tileCount":14,"discards":[],"showedIndicator":false},"#
            + #"{"seat":2,"tileCount":14,"discards":[],"showedIndicator":true},{"seat":3,"tileCount":14,"discards":[],"showedIndicator":false}],"#
            + #""canShowIndicator":false,"indicatorShown":null,"lastAction":{"seat":0,"type":"discard","tile":\#(tileJSON("red-3-0", "red", 3))},"#
            + #""outcome":null,"finish":null,"result":null\#(extra)"#
    }

    func testDecodesTheViewAndSeatsAroundTheFelt() throws {
        let state = try game(view: viewJSON(leftPile: "[" + tileJSON("red-3-0", "red", 3) + "]"), legal: ["draw"])
        let view = try XCTUnwrap(state.okeyClassic)
        XCTAssertEqual(view.okey, OkeyClassicFace(color: .yellow, value: 7))
        XCTAssertEqual(view.stage, .draw); XCTAssertEqual(view.viewerSeat, 1); XCTAssertTrue(view.myTurn)
        XCTAssertEqual(view.scoring, .countdown); XCTAssertEqual(view.startingPoints, 20)
        XCTAssertEqual(view.lastAction?.kind, .discard); XCTAssertEqual(view.lastAction?.tile?.id, "red-3-0")
        XCTAssertTrue(view.seat(2)?.showedIndicator == true)
        // Next player on the right, left neighbour (previous player) on the left with the takeable pile.
        XCTAssertEqual(view.place(of: 1), .bottom); XCTAssertEqual(view.place(of: 2), .right)
        XCTAssertEqual(view.place(of: 3), .top); XCTAssertEqual(view.place(of: 0), .left)
        XCTAssertEqual(view.leftSeat, 0); XCTAssertEqual(view.leftTop?.id, "red-3-0")
        XCTAssertEqual(OkeyClassicPlace.left.pileCorner, .bottomLeft); XCTAssertEqual(OkeyClassicPlace.bottom.pileCorner, .bottomRight)
        // Round index -> table seat (seats 1/3/5/7) and the viewer's name.
        XCTAssertEqual(state.okeySeat(round: 2)?.userId, "cem")
        XCTAssertEqual(state.okeyName(round: 1, me: "me"), "Sen"); XCTAssertEqual(state.okeyName(round: 3, me: "me"), "Dan")
        XCTAssertEqual(state.okeyRackKey(me: "me"), "rooms-okey-rack:ali:0:me")
        XCTAssertTrue(state.isMyTurn("me")) // game.turn is the table seat number 3
        // Another game's view is not read as Okey.
        XCTAssertNil(try game(view: #""kind":"rooms-pisti-v1","okey":{"color":"red","value":1},"stage":"draw""#).okeyClassic)
    }

    func testSpectatorSeesSeatZeroAtTheBottom() throws {
        let view = try XCTUnwrap(try game(view: viewJSON(viewer: "null", hand: "null")).okeyClassic)
        XCTAssertTrue(view.spectator); XCTAssertNil(view.hand); XCTAssertFalse(view.myTurn)
        XCTAssertEqual(view.place(of: 0), .bottom); XCTAssertEqual(view.place(of: 3), .left)
        let controls = OkeyClassicControls(view: view, legalActions: ["draw", "discard", "finish"], busy: false, selected: nil, finisher: nil)
        XCTAssertEqual(controls, OkeyClassicControls(view: view, legalActions: [], busy: false, selected: nil, finisher: nil))
        XCTAssertFalse(controls.drawStock || controls.takeLeft || controls.discard || controls.showIndicator); XCTAssertNil(controls.finishTileID)
    }

    private func handJSON(_ tiles: [OkeyTile]) -> String {
        "[" + tiles.map { t in t.isJoker ? #"{"id":"\#(t.id)","color":"\#(t.color.rawValue)","value":\#(t.value),"joker":true}"# : tileJSON(t.id, t.color.rawValue, t.value) }.joined(separator: ",") + "]"
    }

    func testControlsFollowLegalActions() throws {
        // Draw step: the middle always, the left tile only when the pile has one.
        let empty = try XCTUnwrap(try game(view: viewJSON()).okeyClassic)
        var controls = OkeyClassicControls(view: empty, legalActions: ["draw"], busy: false, selected: nil, finisher: nil)
        XCTAssertTrue(controls.drawStock); XCTAssertFalse(controls.takeLeft); XCTAssertFalse(controls.discard); XCTAssertNil(controls.finishTileID)
        let withPile = try XCTUnwrap(try game(view: viewJSON(leftPile: "[" + tileJSON("red-3-0", "red", 3) + "]")).okeyClassic)
        controls = OkeyClassicControls(view: withPile, legalActions: ["draw"], busy: false, selected: nil, finisher: nil)
        XCTAssertTrue(controls.takeLeft)
        // Busy (a command in flight) turns everything off.
        controls = OkeyClassicControls(view: withPile, legalActions: ["draw"], busy: true, selected: nil, finisher: nil)
        XCTAssertFalse(controls.drawStock || controls.takeLeft)
        // Not my turn: the server lists nothing.
        controls = OkeyClassicControls(view: withPile, legalActions: [], busy: false, selected: nil, finisher: nil)
        XCTAssertFalse(controls.drawStock || controls.takeLeft)
    }

    func testOpeningTurnDiscardFinishAndIndicator() throws {
        // First player: 15 tiles, starts on the discard step; the server lists discard + finish (+ show-indicator).
        let rack = [r(12), r(13), r(1)] + filler(11) + [b(6)]
        let view = try XCTUnwrap(try game(view: viewJSON(stage: "discard", hand: handJSON(rack))).okeyClassic)
        let finisher = OkeyClassicControls.finisher(view)
        XCTAssertEqual(finisher, rack.last?.id)
        let legal = ["discard", "finish", "show-indicator"]
        var controls = OkeyClassicControls(view: view, legalActions: legal, busy: false, selected: nil, finisher: finisher)
        XCTAssertFalse(controls.drawStock); XCTAssertFalse(controls.discard) // nothing selected yet
        XCTAssertEqual(controls.finishTileID, rack.last?.id); XCTAssertTrue(controls.showIndicator); XCTAssertTrue(controls.canThrow)
        // A selected tile that does not finish: "At" works, "Bitir" still throws the finishing tile.
        controls = OkeyClassicControls(view: view, legalActions: legal, busy: false, selected: rack[0].id, finisher: finisher)
        XCTAssertTrue(controls.discard); XCTAssertEqual(controls.finishTileID, rack.last?.id)
        // A selected tile that is not in the hand never enables "At".
        controls = OkeyClassicControls(view: view, legalActions: legal, busy: false, selected: "nope", finisher: finisher)
        XCTAssertFalse(controls.discard)
        // Without `finish` in legalActions there is no "Bitir" even for a finishing rack.
        controls = OkeyClassicControls(view: view, legalActions: ["discard"], busy: false, selected: nil, finisher: finisher)
        XCTAssertNil(controls.finishTileID); XCTAssertFalse(controls.showIndicator)
    }

    func testBitirStaysOffWhenTheRackDoesNotFinish() throws {
        let rack = [r(3), r(5), r(9)] + filler(11) + [b(6)]
        let view = try XCTUnwrap(try game(view: viewJSON(stage: "discard", hand: handJSON(rack))).okeyClassic)
        XCTAssertNil(OkeyClassicControls.finisher(view))
        let controls = OkeyClassicControls(view: view, legalActions: ["discard", "finish"], busy: false, selected: rack[0].id, finisher: nil)
        XCTAssertNil(controls.finishTileID); XCTAssertTrue(controls.discard)
        // Not the viewer's turn: no local finish search at all.
        let other = try XCTUnwrap(try game(view: viewJSON(stage: "discard", turn: "2", hand: handJSON([r(12), r(13), r(1)] + filler(11) + [b(6)]))).okeyClassic)
        XCTAssertNil(OkeyClassicControls.finisher(other))
    }

    func testEndedRoundSummaryAndTexts() throws {
        let meld = #"[\#(tileJSON("red-12-0", "red", 12)),\#(tileJSON("red-13-0", "red", 13)),\#(tileJSON("red-1-0", "red", 1))]"#
        let extra = #","finish":{"seat":2,"discard":{"id":"yellow-7-1","color":"yellow","value":7,"joker":true},"melds":[\#(meld)],"pairs":false,"okeyDiscard":true},"#
            + #""result":{"points":[-4,-4,0,-4],"winners":[2]}"#
        var json = viewJSON(stage: "ended", turn: "null", extra: extra)
        json = json.replacingOccurrences(of: #""finish":null,"result":null"#, with: #""outcome":"finished""#)
            .replacingOccurrences(of: #""outcome":null,"#, with: "")
        let state = try game(view: json, status: "finished", statistics: #"{"me":{"hands":1,"wins":0,"score":-4},"cem":{"hands":1,"wins":1,"score":0}}"#)
        let view = try XCTUnwrap(state.okeyClassic)
        XCTAssertTrue(view.ended); XCTAssertFalse(view.myTurn)
        XCTAssertEqual(view.finish?.okeyDiscard, true); XCTAssertEqual(view.finish?.melds.first?.count, 3)
        XCTAssertEqual(OkeyClassicText.endReason(view) { state.okeyName(round: $0, me: "me") }, "Cem okey atarak bitirdi")
        let rows = state.okeySummary(view, me: "me")
        XCTAssertEqual(rows.map(\.points), [-4, -4, 0, -4])
        XCTAssertEqual(rows.map(\.winner), [false, false, true, false])
        XCTAssertEqual(rows[1].name, "Sen"); XCTAssertEqual(rows[1].total, 16); XCTAssertEqual(rows[2].total, 20); XCTAssertNil(rows[0].total)
        XCTAssertEqual(OkeyClassicText.signed(2), "+2"); XCTAssertEqual(OkeyClassicText.signed(-4), "-4"); XCTAssertEqual(OkeyClassicText.signed(0), "0")
        // Controls are off once the round ends, whatever arrives.
        let controls = OkeyClassicControls(view: view, legalActions: ["draw", "discard"], busy: false, selected: nil, finisher: nil)
        XCTAssertFalse(controls.drawStock || controls.discard)
    }

    func testMoveLinesAndTileNames() {
        let okeyFace = face
        XCTAssertEqual(OkeyClassicText.tileName(sahte(), okey: okeyFace), "Sahte okey · Sarı 7")
        XCTAssertEqual(OkeyClassicText.tileName(okey(), okey: okeyFace), "Okey · Sarı 7")
        XCTAssertEqual(OkeyClassicText.tileName(OkeyTile(id: "x", color: .blue, value: 9), okey: okeyFace), "Mavi 9")
        let stock = OkeyClassicLastAction(seat: 0, kind: .draw)
        XCTAssertEqual(OkeyClassicText.describe(stock, name: "Ali", mine: false, okey: okeyFace), "Ali ortadan çekti")
        XCTAssertEqual(OkeyClassicText.describe(stock, name: "Sen", mine: true, okey: okeyFace), "Ortadan çektin")
        let taken = OkeyClassicLastAction(seat: 0, kind: .draw, fromDiscard: true, tile: OkeyTile(id: "x", color: .red, value: 3))
        XCTAssertEqual(OkeyClassicText.describe(taken, name: "Ali", mine: false, okey: okeyFace), "Ali Kırmızı 3 aldı")
        XCTAssertEqual(OkeyClassicText.describe(OkeyClassicLastAction(seat: 1, kind: .showIndicator), name: "Ali", mine: false, okey: okeyFace), "Ali göstergeyi gösterdi")
        XCTAssertNotEqual(stock.key, taken.key)
    }

    func testMovesEncodeTheEnginePayloads() {
        XCTAssertEqual(GameMove.okeyDraw(fromDiscard: true).json,
                       .object(["type": .string("game.action"), "action": .string("draw"), "payload": .object(["from": .string("discard")])]))
        XCTAssertEqual(GameMove.okeyFinish(tileID: "red-1-0").json,
                       .object(["type": .string("game.action"), "action": .string("finish"), "payload": .object(["tileId": .string("red-1-0")])]))
        XCTAssertEqual(GameMove.okeyShowIndicator.json, .object(["type": .string("game.action"), "action": .string("show-indicator")]))
    }
}

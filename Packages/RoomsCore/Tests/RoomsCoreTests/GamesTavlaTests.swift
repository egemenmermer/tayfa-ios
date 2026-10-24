import XCTest
@testable import RoomsCore

/// Tavla view model: board index mapping per viewer, legal targets, buttons from legalActions, pips, dice faces,
/// opponent trail, pass banner, match standing and the round summary. Fixtures are hand-written from
/// `packages/games/src/tavla.ts` (`tavlaView`) + `match.ts`.
final class GamesTavlaTests: XCTestCase {
    /// Start position as `tavlaView` sends it: seat 0 positive (2 on 23, 5 on 12, 3 on 7, 5 on 5), seat 1 mirrored.
    private static let startPoints: [(Int?, Int)] = {
        var points = Array(repeating: (Int?.none, 0), count: 24)
        points[23] = (0, 2); points[12] = (0, 5); points[7] = (0, 3); points[5] = (0, 5)
        points[0] = (1, 2); points[11] = (1, 5); points[16] = (1, 3); points[18] = (1, 5)
        return points
    }()
    private func pointsJSON(_ points: [(Int?, Int)]) -> String {
        "[" + points.map { #"{"seat":\#($0.0.map(String.init) ?? "null"),"count":\#($0.1)}"# }.joined(separator: ",") + "]"
    }
    private func place(_ value: Any) -> String { value is Int ? "\(value)" : "\"\(value)\"" }
    private func steps(_ list: [(Any, Any, Int, Bool)]) -> String {
        "[" + list.map { #"{"from":\#(place($0.0)),"to":\#(place($0.1)),"die":\#($0.2),"hit":\#($0.3)}"# }.joined(separator: ",") + "]"
    }
    /// White (seat 0) rolled 6-5 at the start: these are the engine's legal single steps (23→18 and 5→0 are blocked).
    private let openingLegal: [(Any, Any, Int, Bool)] = [(23, 17, 6, false), (12, 6, 6, false), (12, 7, 5, false), (7, 1, 6, false), (7, 2, 5, false)]

    private func viewJSON(phase: String = "moving", you: Int? = 0, turn: Int? = 0, points: [(Int?, Int)] = startPoints,
                          bar: [Int] = [0, 0], off: [Int] = [0, 0], pips: String = "[167,167]", dice: [Int]? = [6, 5], remaining: [Int]? = nil,
                          moves: String = "[]", legal: String? = nil, lastTurn: String = "null", result: String = "null",
                          opening: String = "[null,null]", openingTie: Int? = nil, scores: [Int] = [0, 0], matchTo: Int = 5) -> String {
        let remaining = remaining ?? dice ?? []
        return #"""
        {"kind":"rooms-tavla-v1","phase":"\#(phase)","you":\#(you.map(String.init) ?? "null"),"turn":\#(turn.map(String.init) ?? "null"),
         "points":\#(pointsJSON(points)),"bar":\#(bar),"off":\#(off),"pips":\#(pips),"opening":\#(opening),"openingTie":\#(openingTie.map(String.init) ?? "null"),
         "dice":\#(dice.map { "\($0)" } ?? "null"),"remaining":\#(remaining),"moves":\#(moves),"legalMoves":\#(legal ?? steps(openingLegal)),
         "canUndo":false,"canConfirm":false,"lastTurn":\#(lastTurn),"result":\#(result),
         "match":{"matchTo":\#(matchTo),"scores":\#(scores),"starterRerolls":false}}
        """#
    }
    private func read(_ json: String) throws -> TavlaView { try JSONDecoder().decode(TavlaView.self, from: Data(json.utf8)) }

    /// A Tavla table; `seats` lists (seat number, user) in JOIN order.
    private func game(seats: [(Int, String)] = [(1, "ali"), (0, "ece")], view: String, turn: Int? = 0, legal: [String] = ["move"], series: String? = nil) throws -> GameState {
        let seatsJSON = seats.map { #"{"seat":\#($0.0),"userId":"\#($0.1)","name":"\#($0.1.capitalized)","bot":false,"chips":0,"connected":true}"# }.joined(separator: ",")
        let legalJSON = legal.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"""
        {"kind":"rooms-tavla-v1","ownerId":"ece","status":"playing","seats":[\#(seatsJSON)],"turn":\#(turn.map(String.init) ?? "null"),
         "view":\#(view.dropLast()),"legalActions":[\#(legalJSON)],"turnDeadline":null,"capacity":2,"spectators":[],"watching":false,
         "spectatorAccess":true,"statistics":{}\#(series.map { ",\"series\":" + $0 } ?? "")},"history":[]}
        """#
        return try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
    }

    // MARK: Board mapping

    func testSeatZeroSeesHomeBoardBottomRight() {
        // Index 0 (seat 0's 1-point) is bottom right; index 11 bottom left; 12 top left; 23 top right.
        XCTAssertEqual(TavlaBoard.slot(0, you: 0), .init(row: .bottom, col: 11))
        XCTAssertEqual(TavlaBoard.slot(5, you: 0), .init(row: .bottom, col: 6))
        XCTAssertEqual(TavlaBoard.slot(6, you: 0), .init(row: .bottom, col: 5))
        XCTAssertEqual(TavlaBoard.slot(11, you: 0), .init(row: .bottom, col: 0))
        XCTAssertEqual(TavlaBoard.slot(12, you: 0), .init(row: .top, col: 0))
        XCTAssertEqual(TavlaBoard.slot(23, you: 0), .init(row: .top, col: 11))
        XCTAssertEqual(TavlaBoard.bottomSeat(you: 0), 0)
    }
    func testSeatOneSeesTheBoardMirrored() {
        // Seat 1's home (18…23) is bottom right for them.
        XCTAssertEqual(TavlaBoard.slot(23, you: 1), .init(row: .bottom, col: 11))
        XCTAssertEqual(TavlaBoard.slot(18, you: 1), .init(row: .bottom, col: 6))
        XCTAssertEqual(TavlaBoard.slot(12, you: 1), .init(row: .bottom, col: 0))
        XCTAssertEqual(TavlaBoard.slot(11, you: 1), .init(row: .top, col: 0))
        XCTAssertEqual(TavlaBoard.slot(0, you: 1), .init(row: .top, col: 11))
        XCTAssertEqual(TavlaBoard.bottomSeat(you: 1), 1)
    }
    func testSpectatorSeesSeatZeroSideAndSlotsRoundTrip() {
        XCTAssertEqual(TavlaBoard.bottomSeat(you: nil), 0)
        for you in [0, 1, nil] as [Int?] {
            var seen = Set<String>()
            for index in 0..<24 {
                let slot = TavlaBoard.slot(index, you: you)
                XCTAssertTrue((0...11).contains(slot.col))
                XCTAssertEqual(TavlaBoard.index(row: slot.row, col: slot.col, you: you), index)
                seen.insert("\(slot.row)-\(slot.col)")
            }
            XCTAssertEqual(seen.count, 24)
        }
        XCTAssertEqual(TavlaBoard.slot(7, you: nil), TavlaBoard.slot(7, you: 0))
    }
    func testPointNumbersFromEachSide() {
        XCTAssertEqual(TavlaBoard.pointNumber(0, seat: 0), 1); XCTAssertEqual(TavlaBoard.pointNumber(23, seat: 0), 24)
        XCTAssertEqual(TavlaBoard.pointNumber(23, seat: 1), 1); XCTAssertEqual(TavlaBoard.pointNumber(18, seat: 1), 6)
        XCTAssertEqual(TavlaStep(from: .point(12), to: .point(6), die: 6, hit: true).text(seat: 0), "13/7*")
        XCTAssertEqual(TavlaStep(from: .bar, to: .point(2), die: 3).text(seat: 1), "Bar/22")
        XCTAssertEqual(TavlaStep(from: .point(20), to: .off, die: 4).text(seat: 1), "4/Topla")
    }

    // MARK: Legal targets

    func testLegalTargetsForASelectedPoint() throws {
        let view = try read(viewJSON())
        XCTAssertEqual(view.sources, [.point(23), .point(12), .point(7)])
        XCTAssertEqual(view.targets(from: .point(12)), [.point(6), .point(7)])
        XCTAssertEqual(view.targets(from: .point(23)), [.point(17)])
        XCTAssertEqual(view.targets(from: .point(5)), [], "5→0 is blocked by two dark checkers")
        XCTAssertNil(view.selection(picked: nil), "several sources: nothing auto-selected")
        XCTAssertNil(view.selection(picked: .point(5)), "a point without a legal step cannot be picked")
        XCTAssertEqual(view.selection(picked: .point(12)), .point(12))
    }
    func testTapPrefersMoveOntoOwnPointOverNewPick() throws {
        let view = try read(viewJSON())
        // 12→7 lands on the own point 7, which is also a source: with 12 selected it is a move.
        XCTAssertEqual(view.tap(.point(7), selected: .point(12)), .move(from: .point(12), to: .point(7)))
        XCTAssertEqual(view.tap(.point(7), selected: nil), .select(.point(7)))
        XCTAssertEqual(view.tap(.point(7), selected: .point(7)), .deselect)
        XCTAssertEqual(view.tap(.point(3), selected: .point(12)), .deselect)
    }
    func testBarEntryIsTheOnlySourceAndAutoSelects() throws {
        var points = Self.startPoints
        points[23] = (0, 1)
        let legal = steps([("bar", 21, 3, false), ("bar", 19, 5, true)])
        let view = try read(viewJSON(points: points, bar: [1, 0], dice: [3, 5], legal: legal))
        XCTAssertEqual(view.sources, [.bar])
        XCTAssertEqual(view.selection(picked: nil), .bar)
        XCTAssertEqual(view.targets(from: .bar), [.point(21), .point(19)])
        XCTAssertTrue(view.hits(from: .bar, to: .point(19))); XCTAssertFalse(view.hits(from: .bar, to: .point(21)))
    }
    func testBearOffTargetDecodes() throws {
        let legal = steps([(3, "off", 4, false), (3, 0, 3, false)])
        let view = try read(viewJSON(legal: legal))
        XCTAssertEqual(view.targets(from: .point(3)), [.off, .point(0)])
        XCTAssertEqual(TavlaPlace.off.move, .off); XCTAssertEqual(TavlaPlace.point(3).move, .point(3))
    }
    func testViewerMovingNeedsOwnTurnAndMoveAction() throws {
        let view = try read(viewJSON())
        XCTAssertTrue(view.viewerMoving(legalActions: ["move"]))
        XCTAssertFalse(view.viewerMoving(legalActions: ["confirm"]))
        XCTAssertFalse(try read(viewJSON(you: 1)).viewerMoving(legalActions: ["move"]), "not the viewer's turn")
        XCTAssertFalse(try read(viewJSON(you: nil)).viewerMoving(legalActions: ["move"]), "spectator")
    }

    // MARK: Buttons

    func testButtonsFollowLegalActions() {
        let opening = TavlaControls(legalActions: ["roll"], busy: false, phase: .opening)
        XCTAssertTrue(opening.roll); XCTAssertFalse(opening.undo); XCTAssertFalse(opening.confirm)
        XCTAssertEqual(opening.rollTitle, "Açılış zarını at")
        XCTAssertEqual(TavlaControls(legalActions: ["roll"], busy: false, phase: .roll).rollTitle, "Zar at")
        let moving = TavlaControls(legalActions: ["move", "undo"], busy: false, phase: .moving)
        XCTAssertFalse(moving.roll); XCTAssertTrue(moving.undo); XCTAssertFalse(moving.confirm); XCTAssertTrue(moving.move)
        let done = TavlaControls(legalActions: ["undo", "confirm"], busy: false, phase: .moving)
        XCTAssertTrue(done.undo); XCTAssertTrue(done.confirm); XCTAssertFalse(done.move)
        let busy = TavlaControls(legalActions: ["undo", "confirm"], busy: true, phase: .moving)
        XCTAssertFalse(busy.undo); XCTAssertFalse(busy.confirm)
        XCTAssertEqual(TavlaControls(legalActions: [], busy: false, phase: .moving), TavlaControls(legalActions: ["leave"], busy: false, phase: .moving))
    }

    // MARK: Pips and dice

    func testPipCountsAtTheStartAndAfterAHit() throws {
        let start = try read(viewJSON())
        XCTAssertEqual(start.computedPips(0), 167); XCTAssertEqual(start.computedPips(1), 167)
        XCTAssertEqual(start.pipCount(0), 167)
        // White moved 23→16 hitting a dark blot (on the bar now); the dark checkers sit on 0, 11, 17 and 18.
        var points = Self.startPoints
        points[23] = (0, 1); points[16] = (0, 1); points[18] = (1, 5); points[11] = (1, 5); points[0] = (1, 2)
        points[17] = (1, 2)
        let hit = try read(viewJSON(points: points, bar: [0, 1], pips: "[]"))
        XCTAssertEqual(hit.computedPips(0), 167 - 7)
        // Seat 1 counts 24 - index: 5×13 (11) + 2×7 (17) + 5×6 (18) + 2×24 (0) + 25 for the bar checker.
        XCTAssertEqual(hit.computedPips(1), 5 * 13 + 2 * 7 + 5 * 6 + 2 * 24 + 25)
        XCTAssertEqual(hit.pipCount(1), hit.computedPips(1), "no server pips: local count")
    }
    func testDoublesShowFourDiceWithUsedOnesDimmed() throws {
        let view = try read(viewJSON(dice: [4, 4], remaining: [4, 4]))
        XCTAssertEqual(view.diceFaces.map(\.value), [4, 4, 4, 4])
        XCTAssertEqual(view.diceFaces.map(\.used), [false, false, true, true])
        let mixed = try read(viewJSON(dice: [6, 2], remaining: [2]))
        XCTAssertEqual(mixed.diceFaces, [TavlaDie(value: 6, used: true), TavlaDie(value: 2, used: false)])
    }

    // MARK: Opponent's last move and pass

    func testOpponentTrailStaysUntilTheViewerRolls() throws {
        let last = #"{"seat":1,"dice":[3,1],"moves":\#(steps([(16, 19, 3, false), (18, 19, 1, false)])),"passed":false}"#
        let waiting = try read(viewJSON(phase: "roll", you: 0, turn: 0, dice: nil, legal: "[]", lastTurn: last))
        XCTAssertEqual(waiting.opponentTrail.count, 2); XCTAssertEqual(waiting.trailSeat, 1)
        let rolled = try read(viewJSON(phase: "moving", you: 0, turn: 0, lastTurn: last))
        XCTAssertEqual(rolled.opponentTrail, [], "gone once the viewer is moving")
        let live = try read(viewJSON(phase: "moving", you: 0, turn: 1, moves: steps([(0, 3, 3, false)]), legal: "[]", lastTurn: "null"))
        XCTAssertEqual(live.opponentTrail.map(\.to), [.point(3)]); XCTAssertEqual(live.trailSeat, 1)
        let ownLast = try read(viewJSON(phase: "roll", you: 1, turn: 0, dice: nil, legal: "[]", lastTurn: last))
        XCTAssertEqual(ownLast.opponentTrail, [], "the viewer's own last turn is not an opponent trail")
    }
    func testPassedTurnBanner() throws {
        let passed = #"{"seat":1,"dice":[6,6],"moves":[],"passed":true}"#
        let view = try read(viewJSON(phase: "roll", turn: 0, dice: nil, legal: "[]", lastTurn: passed))
        XCTAssertEqual(view.passedTurn?.diceText, "6-6"); XCTAssertEqual(view.opponentTrail, [])
        XCTAssertNil(try read(viewJSON(lastTurn: passed)).passedTurn, "hidden once the next player is moving")
    }

    // MARK: Match and summary

    func testMatchStandingAndScoreLine() throws {
        let view = try read(viewJSON(scores: [1, 3]))
        let series = #"{"totals":[1,3],"rounds":[{"points":[0,1],"winners":[1]},{"points":[1,0],"winners":[0]},{"points":[0,2],"winners":[1]}],"winners":null,"previous":null}"#
        let table = try game(view: viewJSON(scores: [1, 3]), series: series)
        let standing = TavlaMatchStanding(view: view, series: table.table.series)
        XCTAssertEqual(standing.round, 4); XCTAssertNil(standing.winner)
        XCTAssertEqual(standing.scoreLine(bottom: 1), "3 – 1 · 5'e")
        XCTAssertEqual(standing.scoreLine(bottom: 0), "1 – 3 · 5'e")
        XCTAssertEqual(TavlaMatchStanding.targetLabel(7), "7'ye"); XCTAssertEqual(TavlaMatchStanding.targetLabel(3), "3'e")
        // No series yet: the round's own match scores.
        XCTAssertEqual(TavlaMatchStanding(view: view, series: nil).totals, [1, 3])
    }
    func testRoundSummaryWithMarsFromSeriesPrevious() throws {
        let over = viewJSON(phase: "over", turn: nil, off: [15, 0], dice: nil, legal: "[]", result: #"{"winner":0,"points":2,"mars":true}"#)
        let series = #"{"totals":[2,0],"rounds":[{"points":[2,0],"winners":[0]}],"winners":null,"previous":\#(over)}"#
        // The next round's opening has not been rolled yet: the summary still shows the previous round.
        let fresh = try game(view: viewJSON(phase: "opening", turn: 0, dice: nil, legal: "[]", scores: [2, 0]), legal: ["roll"], series: series)
        let current = try XCTUnwrap(fresh.tavlaView)
        let finished = try XCTUnwrap(fresh.tavlaFinishedRound(current))
        XCTAssertEqual(finished.result, TavlaRoundResult(winner: 0, points: 2, mars: true))
        XCTAssertEqual(TavlaMatchStanding(view: current, series: fresh.table.series).round, 2)
        // Once someone rolls the opening die the summary goes away.
        let rolled = try game(view: viewJSON(phase: "opening", turn: 1, dice: nil, legal: "[]", opening: "[4,null]"), series: series)
        XCTAssertNil(rolled.tavlaFinishedRound(try XCTUnwrap(rolled.tavlaView)))
    }
    func testMatchWinnerAndRoundSeatMapping() throws {
        let over = viewJSON(phase: "over", you: 1, turn: nil, off: [3, 15], dice: nil, legal: "[]", result: #"{"winner":1,"points":1,"mars":false}"#)
        let series = #"{"totals":[2,5],"rounds":[],"winners":[1],"previous":null}"#
        // Seats joined as (1, ali), (0, ece): round index follows seat number order, so round 1 is ali.
        let table = try game(view: over, turn: nil, legal: ["start"], series: series)
        let view = try XCTUnwrap(table.tavlaView)
        XCTAssertEqual(table.tavlaFinishedRound(view)?.result?.winner, 1)
        let standing = TavlaMatchStanding(view: view, series: table.table.series)
        XCTAssertEqual(standing.winner, 1); XCTAssertEqual(standing.round, 0)
        XCTAssertEqual(table.tavlaSeat(round: 1)?.userId, "ali"); XCTAssertEqual(table.tavlaSeat(round: 0)?.userId, "ece")
        XCTAssertEqual(view.bottomSeat, 1); XCTAssertEqual(view.topSeat, 0)
    }
    func testMissingOrBrokenViewIsNil() throws {
        let empty = try game(view: #"{"kind":"rooms-tavla-v1"}"#)
        XCTAssertNil(empty.tavlaView)
        let short = viewJSON().replacingOccurrences(of: pointsJSON(Self.startPoints), with: "[]")
        XCTAssertNil(try game(view: short).tavlaView)
        let unknownPhase = try read(viewJSON(phase: "later"))
        XCTAssertEqual(unknownPhase.phase, .unknown)
    }
    func testMoveCommandPayload() {
        let command = GameMove.tavlaMove(from: TavlaPlace.bar.move, to: TavlaPlace.point(20).move)
        XCTAssertEqual(command, .act(name: "move", payload: .object(["from": .string("bar"), "to": .number(20)])))
        XCTAssertTrue(command.valid)
    }
}

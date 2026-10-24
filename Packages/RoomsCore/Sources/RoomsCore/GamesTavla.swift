import Foundation

// Tavla (`rooms-tavla-v1`) view model for the iPhone table. Source of truth: `packages/games/src/tavla.ts` and the
// match wrapper `match.ts` in the desktop repository; the desktop reading lives in `apps/desktop/src/games/tavla/model.ts`.
//
// Index semantics (easy to get wrong):
// - Board points are indices 0…23. Seat 0 moves toward index 0 (home 0…5, enters from the bar at 24 - die); seat 1
//   moves toward index 23 (home 18…23, enters at die - 1).
// - `you`, `turn`, `lastTurn.seat`, `result.winner`, `bar`, `off`, `pips`, `series.totals` and `series.winners` are
//   ROUND indices (0/1): the position in the seats sorted by seat number (`GameState.orderedSeats`), not
//   `GameSeat.seat`. `GameState.turn` is a seat number.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

// MARK: - Wire types

/// Where a checker moves from or to: a point index, the bar (from) or off the board (to).
public enum TavlaPlace: Hashable, Sendable, Decodable {
    case point(Int), bar, off
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let index = try? c.decode(Int.self) { self = .point(index); return }
        switch try c.decode(String.self) {
        case "bar": self = .bar
        case "off": self = .off
        default: throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown tavla place")
        }
    }
    public var index: Int? { if case .point(let index) = self { return index }; return nil }
    /// The payload form `GameMove.tavlaMove` sends.
    public var move: GameMove.TavlaPoint {
        switch self {
        case .point(let index): .point(index)
        case .bar: .bar
        case .off: .off
        }
    }
}

public struct TavlaStep: Decodable, Hashable, Sendable {
    public let from: TavlaPlace
    public let to: TavlaPlace
    public let die: Int
    public let hit: Bool
    public init(from: TavlaPlace, to: TavlaPlace, die: Int, hit: Bool = false) { self.from = from; self.to = to; self.die = die; self.hit = hit }
    enum CodingKeys: String, CodingKey { case from, to, die, hit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(TavlaPlace.self, forKey: .from)
        to = try c.decode(TavlaPlace.self, forKey: .to)
        die = c.soft(Int.self, .die) ?? 0
        hit = c.soft(Bool.self, .hit) ?? false
    }
    /// "13/7*" from the mover's side: point numbers, "Bar", and "Topla" for bearing off.
    public func text(seat: Int) -> String {
        let from = self.from.index.map { String(TavlaBoard.pointNumber($0, seat: seat)) } ?? "Bar"
        let to = self.to.index.map { String(TavlaBoard.pointNumber($0, seat: seat)) } ?? "Topla"
        return "\(from)/\(to)\(hit ? "*" : "")"
    }
}

public enum TavlaPhase: String, Sendable, Decodable {
    case opening, roll, moving, over, unknown
    public init(from decoder: Decoder) throws {
        self = TavlaPhase(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

/// One point: whose checkers (round index) and how many.
public struct TavlaPointState: Decodable, Equatable, Sendable {
    public let seat: Int?
    public let count: Int
    public init(seat: Int?, count: Int) { self.seat = seat; self.count = count }
    enum CodingKeys: String, CodingKey { case seat, count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(0, c.soft(Int.self, .count) ?? 0)
        seat = count > 0 ? c.soft(Int.self, .seat) : nil
    }
}

public struct TavlaTurnRecord: Decodable, Equatable, Sendable {
    public let seat: Int
    public let dice: [Int]
    public let moves: [TavlaStep]
    /// No legal move existed for the roll; the server passed the turn.
    public let passed: Bool
    enum CodingKeys: String, CodingKey { case seat, dice, moves, passed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = c.soft(Int.self, .seat) ?? 0
        dice = c.soft([Int].self, .dice) ?? []
        moves = c.soft([TavlaStep].self, .moves) ?? []
        passed = c.soft(Bool.self, .passed) ?? false
    }
    public var diceText: String { dice.map(String.init).joined(separator: "-") }
}

public struct TavlaRoundResult: Decodable, Equatable, Sendable {
    public let winner: Int
    /// 1, or 2 for mars.
    public let points: Int
    public let mars: Bool
}

public struct TavlaMatchInfo: Decodable, Equatable, Sendable {
    public let matchTo: Int
    /// Match score before this round.
    public let scores: [Int]
    public let starterRerolls: Bool
    enum CodingKeys: String, CodingKey { case matchTo, scores, starterRerolls }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchTo = c.soft(Int.self, .matchTo) ?? 5
        scores = c.soft([Int].self, .scores) ?? [0, 0]
        starterRerolls = c.soft(Bool.self, .starterRerolls) ?? false
    }
}

/// One Tavla round as the viewer sees it: `view` itself, or `view.series.previous`.
public struct TavlaView: Decodable, Equatable, Sendable {
    public let phase: TavlaPhase
    /// The viewer's round index; nil when watching.
    public let you: Int?
    /// Round index that must act; nil once the round is over.
    public let turn: Int?
    /// 24 points by index.
    public let points: [TavlaPointState]
    public let bar: [Int]
    public let off: [Int]
    public let pips: [Int]
    /// Opening roll-off dice per round index.
    public let opening: [Int?]
    /// Value of the last tied opening roll (re-roll), if any.
    public let openingTie: Int?
    public let dice: [Int]?
    public let remaining: [Int]
    /// Steps already played this turn (undoable by the mover).
    public let moves: [TavlaStep]
    /// Legal single steps for the seat to act.
    public let legalMoves: [TavlaStep]
    public let canUndo: Bool
    public let canConfirm: Bool
    public let lastTurn: TavlaTurnRecord?
    public let result: TavlaRoundResult?
    public let match: TavlaMatchInfo

    enum CodingKeys: String, CodingKey { case phase, you, turn, points, bar, off, pips, opening, openingTie, dice, remaining, moves, legalMoves, canUndo, canConfirm, lastTurn, result, match }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([TavlaPointState].self, forKey: .points)
        guard points.count == 24 else { throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "Tavla board needs 24 points") }
        match = try c.decode(TavlaMatchInfo.self, forKey: .match)
        phase = c.soft(TavlaPhase.self, .phase) ?? .unknown
        you = c.soft(Int.self, .you).flatMap { $0 == 0 || $0 == 1 ? $0 : nil }
        turn = c.soft(Int.self, .turn)
        bar = Self.pair(c.soft([Int].self, .bar))
        off = Self.pair(c.soft([Int].self, .off))
        opening = c.soft([Int?].self, .opening).map { $0.count == 2 ? $0 : [nil, nil] } ?? [nil, nil]
        openingTie = c.soft(Int.self, .openingTie)
        dice = c.soft([Int].self, .dice)
        remaining = c.soft([Int].self, .remaining) ?? []
        moves = c.soft([TavlaStep].self, .moves) ?? []
        legalMoves = c.soft([TavlaStep].self, .legalMoves) ?? []
        canUndo = c.soft(Bool.self, .canUndo) ?? false
        canConfirm = c.soft(Bool.self, .canConfirm) ?? false
        lastTurn = c.soft(TavlaTurnRecord.self, .lastTurn)
        result = c.soft(TavlaRoundResult.self, .result)
        let sent = c.soft([Int].self, .pips)
        pips = sent?.count == 2 ? sent! : []
    }
    private static func pair(_ value: [Int]?) -> [Int] { value?.count == 2 ? value! : [0, 0] }

    // MARK: Checkers and pips

    /// Checkers of `seat` on point `index`.
    public func count(of seat: Int, at index: Int) -> Int {
        guard points.indices.contains(index), points[index].seat == seat else { return 0 }
        return points[index].count
    }
    /// Pips `seat` still has to travel: bar checkers count 25, a checker on `index` its distance to bearing off.
    public func computedPips(_ seat: Int) -> Int {
        var total = (bar.indices.contains(seat) ? bar[seat] : 0) * 25
        for index in 0..<24 { total += count(of: seat, at: index) * TavlaBoard.pointNumber(index, seat: seat) }
        return total
    }
    /// The server's pip count, or the local one for older views.
    public func pipCount(_ seat: Int) -> Int { pips.indices.contains(seat) ? pips[seat] : computedPips(seat) }
    public func borneOff(_ seat: Int) -> Int { off.indices.contains(seat) ? off[seat] : 0 }
    public func onBar(_ seat: Int) -> Int { bar.indices.contains(seat) ? bar[seat] : 0 }

    // MARK: Moves

    /// The round index drawn at the bottom: the viewer, seat 0 for spectators.
    public var bottomSeat: Int { TavlaBoard.bottomSeat(you: you) }
    public var topSeat: Int { 1 - bottomSeat }
    /// The viewer may pick checkers now (its own turn, dice rolled, and the server lists `move`).
    public func viewerMoving(legalActions: [String]) -> Bool {
        you != nil && turn == you && phase == .moving && legalActions.contains("move")
    }
    /// Places with a legal step, in the server's order.
    public var sources: [TavlaPlace] {
        var seen: [TavlaPlace] = []
        for step in legalMoves where !seen.contains(step.from) { seen.append(step.from) }
        return seen
    }
    /// Legal targets for a checker on `from`.
    public func targets(from: TavlaPlace) -> [TavlaPlace] {
        var seen: [TavlaPlace] = []
        for step in legalMoves where step.from == from && !seen.contains(step.to) { seen.append(step.to) }
        return seen
    }
    /// The selection to show: the picked source when it is legal, else the only source when there is one (bar entry).
    public func selection(picked: TavlaPlace?) -> TavlaPlace? {
        let sources = sources
        if let picked, sources.contains(picked) { return picked }
        return sources.count == 1 ? sources[0] : nil
    }
    /// What a tap on `place` means with `selected` picked: a move first (a target may be your own point), then a new pick.
    public func tap(_ place: TavlaPlace, selected: TavlaPlace?) -> TavlaTap {
        if let selected, targets(from: selected).contains(place) { return .move(from: selected, to: place) }
        if sources.contains(place) { return place == selected ? .deselect : .select(place) }
        return .deselect
    }
    /// A step that hits a blot (for a haptic).
    public func hits(from: TavlaPlace, to: TavlaPlace) -> Bool { legalMoves.contains { $0.from == from && $0.to == to && $0.hit } }

    /// The dice of this roll (doubles as four), with the used ones marked.
    public var diceFaces: [TavlaDie] {
        let dice = dice ?? []
        let all = dice.count == 2 && dice[0] == dice[1] ? Array(repeating: dice[0], count: 4) : dice
        var left = remaining
        return all.map { value in
            if let at = left.firstIndex(of: value) { left.remove(at: at); return TavlaDie(value: value, used: false) }
            return TavlaDie(value: value, used: true)
        }
    }
    /// The opponent's moves to draw: their live steps while they move, else their last turn until the viewer rolls.
    public var opponentTrail: [TavlaStep] {
        if phase == .moving { return turn != you ? moves : [] }
        guard let last = lastTurn, !last.passed else { return [] }
        if let you, last.seat != 1 - you { return [] }
        return last.moves
    }
    /// Whose moves `opponentTrail` shows.
    public var trailSeat: Int? { phase == .moving && turn != you ? turn : lastTurn?.seat }
    /// The turn the server passed for lack of a legal move ("Oynayacak hamle yok").
    public var passedTurn: TavlaTurnRecord? { phase != .moving && lastTurn?.passed == true ? lastTurn : nil }
    /// The opening roll-off has not started yet (fresh round).
    public var freshRound: Bool { phase == .opening && opening.allSatisfy { $0 == nil } && openingTie == nil }
}

public struct TavlaDie: Equatable, Sendable { public let value: Int; public let used: Bool }

public enum TavlaTap: Equatable, Sendable { case select(TavlaPlace), deselect, move(from: TavlaPlace, to: TavlaPlace) }

// MARK: - Board geometry

/// Board layout for a viewer: own home board bottom right; seat 1 sees the board mirrored.
public enum TavlaBoard {
    public enum Row: Sendable { case top, bottom }
    public struct Slot: Equatable, Sendable {
        public let row: Row
        /// 0…11 from the left; the bar sits between columns 5 and 6.
        public let col: Int
    }
    public static func bottomSeat(you: Int?) -> Int { you == 1 ? 1 : 0 }
    /// Where point `index` sits on the drawn board for viewer `you` (nil = spectator, drawn like seat 0).
    public static func slot(_ index: Int, you: Int?) -> Slot {
        let local = you == 1 ? 23 - index : index
        return local < 12 ? Slot(row: .bottom, col: 11 - local) : Slot(row: .top, col: local - 12)
    }
    /// The point index drawn at a slot (inverse of `slot`).
    public static func index(row: Row, col: Int, you: Int?) -> Int {
        let local = row == .bottom ? 11 - col : col + 12
        return you == 1 ? 23 - local : local
    }
    /// A point's number (1…24) from `seat`'s side, as players call it ("6'lık hane").
    public static func pointNumber(_ index: Int, seat: Int) -> Int { seat == 0 ? index + 1 : 24 - index }
}

// MARK: - Controls

/// Which Tavla buttons are live, straight from the server's `legalActions`.
public struct TavlaControls: Equatable, Sendable {
    public let roll: Bool
    public let undo: Bool
    public let confirm: Bool
    public let move: Bool
    public let rollTitle: String
    public init(legalActions: [String], busy: Bool, phase: TavlaPhase) {
        roll = !busy && legalActions.contains("roll")
        undo = !busy && legalActions.contains("undo")
        confirm = !busy && legalActions.contains("confirm")
        move = !busy && legalActions.contains("move")
        rollTitle = phase == .opening ? "Açılış zarını at" : "Zar at"
    }
}

// MARK: - Match

/// Match score and the round summary, from `view.match` and `view.series`.
public struct TavlaMatchStanding: Equatable, Sendable {
    public let totals: [Int]
    public let matchTo: Int
    /// 1-based number of the round on the board.
    public let round: Int
    /// Round index that won the match, once it is over.
    public let winner: Int?
    public init(view: TavlaView, series: GameSeries?) {
        let totals = series?.totals ?? []
        self.totals = totals.count == 2 ? totals : (view.match.scores.count == 2 ? view.match.scores : [0, 0])
        matchTo = view.match.matchTo
        round = (series?.rounds.count ?? 0) + (view.phase == .over ? 0 : 1)
        winner = series?.winners?.first
    }
    /// "5'e" (Turkish vowel harmony: 3'e, 5'e, 7'ye).
    public static func targetLabel(_ matchTo: Int) -> String {
        switch matchTo {
        case 3: "3'e"
        case 5: "5'e"
        case 7: "7'ye"
        default: "\(matchTo)"
        }
    }
    /// "3 – 1 · 5'e" with `bottom` first.
    public func scoreLine(bottom: Int) -> String {
        "\(totals[bottom]) – \(totals[1 - bottom]) · \(Self.targetLabel(matchTo))"
    }
}

public extension GameState {
    /// The Tavla round view; nil before the first round, for viewers without access, or on an older server.
    var tavlaView: TavlaView? { kind == .tavla ? view(as: TavlaView.self) : nil }
    /// The finished round to summarise: this one when over, else the previous one until the next opening roll starts.
    func tavlaFinishedRound(_ current: TavlaView) -> TavlaView? {
        if current.result != nil { return current }
        guard current.freshRound, let previous = table.series?.previous, let data = try? JSONEncoder().encode(previous) else { return nil }
        return (try? JSONDecoder().decode(TavlaView.self, from: data)).flatMap { $0.result == nil ? nil : $0 }
    }
    /// The table seat playing round index `round` (0/1).
    func tavlaSeat(round: Int?) -> GameSeat? { seat(atPosition: round) }
}

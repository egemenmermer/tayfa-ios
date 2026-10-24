import Foundation

// Classic Okey (`rooms-okey-v1`) view model for the iPhone table. Sources of truth in the desktop repository:
// the engine `packages/games/src/okey-classic.ts` (view shape, finish search, legal actions) and the desktop table
// `apps/desktop/src/games/okey/{auto-arrange,rack-layout,OkeyClassicTable,OkeyRoundSummary}.ts(x)`.
//
// Index semantics: every seat-like number in the view (`turn`, `viewerSeat`, `seats[].seat`, `finish.seat`,
// `lastAction.seat`, `indicatorShown.seat`, `result.points[i]`) is a ROUND index: the position in the table seats
// sorted by seat number (`GameState.orderedSeats`). `GameState.turn` itself is a table seat number.
// Play passes to round index + 1 (the player on your right); the pile `seats[i].discards` lies between i and i + 1,
// so the viewer may take the top of the left neighbour's pile (`viewerSeat + 3`).

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

// MARK: - Wire types

/// The okey's face (gösterge + 1 in the same color, 13 wraps to 1).
public struct OkeyClassicFace: Codable, Equatable, Sendable {
    public let color: OkeyColor
    public let value: Int
    public init(color: OkeyColor, value: Int) { self.color = color; self.value = value }
    public var title: String { "\(color.title) \(value)" }
}

public enum OkeyClassicStage: String, Sendable { case draw, discard, ended }

public struct OkeyClassicSeatView: Decodable, Equatable, Sendable {
    public let seat: Int
    public let tileCount: Int
    /// This player's pile, oldest first; the next player may take the last one.
    public let discards: [OkeyTile]
    public let showedIndicator: Bool
    enum CodingKeys: String, CodingKey { case seat, tileCount, discards, showedIndicator }
    public init(seat: Int, tileCount: Int, discards: [OkeyTile] = [], showedIndicator: Bool = false) {
        self.seat = seat; self.tileCount = tileCount; self.discards = discards; self.showedIndicator = showedIndicator
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = try c.decode(Int.self, forKey: .seat)
        tileCount = c.soft(Int.self, .tileCount) ?? 0
        discards = c.soft([OkeyTile].self, .discards) ?? []
        showedIndicator = c.soft(Bool.self, .showedIndicator) ?? false
    }
}

public enum OkeyClassicMoveKind: String, Sendable { case draw, discard, finish, showIndicator = "show-indicator" }

/// `view.lastAction`. A stock draw never carries the tile.
public struct OkeyClassicLastAction: Decodable, Equatable, Sendable {
    public let seat: Int
    public let kind: OkeyClassicMoveKind
    /// A draw from the left neighbour's pile.
    public let fromDiscard: Bool
    public let tile: OkeyTile?
    enum CodingKeys: String, CodingKey { case seat, type, from, tile }
    public init(seat: Int, kind: OkeyClassicMoveKind, fromDiscard: Bool = false, tile: OkeyTile? = nil) {
        self.seat = seat; self.kind = kind; self.fromDiscard = fromDiscard; self.tile = tile
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = try c.decode(Int.self, forKey: .seat)
        guard let kind = c.soft(String.self, .type).flatMap(OkeyClassicMoveKind.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown okey move")
        }
        self.kind = kind
        fromDiscard = c.soft(String.self, .from) == "discard"
        tile = c.soft(OkeyTile.self, .tile)
    }
    /// Identity for "a new move happened" (consecutive views).
    public var key: String { "\(seat):\(kind.rawValue):\(fromDiscard):\(tile?.id ?? "")" }
}

public struct OkeyClassicIndicatorShow: Decodable, Equatable, Sendable {
    public let seat: Int
    public let tile: OkeyTile
}

/// The finished round: the open winning rack.
public struct OkeyClassicFinish: Decodable, Equatable, Sendable {
    public let seat: Int
    /// The 15th tile thrown to end the round.
    public let discard: OkeyTile
    public let melds: [[OkeyTile]]
    public let pairs: Bool
    public let okeyDiscard: Bool
    public init(seat: Int, discard: OkeyTile, melds: [[OkeyTile]], pairs: Bool, okeyDiscard: Bool) {
        self.seat = seat; self.discard = discard; self.melds = melds; self.pairs = pairs; self.okeyDiscard = okeyDiscard
    }
}

public struct OkeyClassicResult: Decodable, Equatable, Sendable {
    /// Per round index.
    public let points: [Int]
    public let winners: [Int]
}

/// One classic Okey round as the viewer may see it (`game.view`).
public struct OkeyClassicView: Decodable, Equatable, Sendable {
    public let scoring: OkeyScoring
    /// Countdown tables start everyone here; the table statistics hold the change.
    public let startingPoints: Int
    public let indicator: OkeyTile?
    public let okey: OkeyClassicFace
    public let stockCount: Int
    public let first: Int
    /// Round index whose turn it is; nil once the round is over.
    public let turn: Int?
    public let stage: OkeyClassicStage
    /// The viewer's round index; nil when watching.
    public let viewerSeat: Int?
    /// The viewer's own rack (unordered on the server); nil for spectators.
    public let hand: [OkeyTile]?
    public let seats: [OkeyClassicSeatView]
    public let canShowIndicator: Bool
    public let indicatorShown: OkeyClassicIndicatorShow?
    public let lastAction: OkeyClassicLastAction?
    /// `finished` or `stock-exhausted` once the round ends.
    public let outcome: String?
    public let finish: OkeyClassicFinish?
    public let result: OkeyClassicResult?

    enum CodingKeys: String, CodingKey {
        case kind, options, indicator, okey, stockCount, first, turn, stage, viewerSeat, hand, seats, canShowIndicator, indicatorShown, lastAction, outcome, finish, result
    }
    private struct Options: Decodable { let scoring: String?; let startingPoints: Int? }

    public init(okey: OkeyClassicFace, stage: OkeyClassicStage, turn: Int?, viewerSeat: Int?, hand: [OkeyTile]?, seats: [OkeyClassicSeatView],
                indicator: OkeyTile? = nil, stockCount: Int = 48, first: Int = 0, scoring: OkeyScoring = .countdown, startingPoints: Int = 20,
                canShowIndicator: Bool = false, indicatorShown: OkeyClassicIndicatorShow? = nil, lastAction: OkeyClassicLastAction? = nil,
                outcome: String? = nil, finish: OkeyClassicFinish? = nil, result: OkeyClassicResult? = nil) {
        self.okey = okey; self.stage = stage; self.turn = turn; self.viewerSeat = viewerSeat; self.hand = hand; self.seats = seats
        self.indicator = indicator; self.stockCount = stockCount; self.first = first; self.scoring = scoring; self.startingPoints = startingPoints
        self.canShowIndicator = canShowIndicator; self.indicatorShown = indicatorShown; self.lastAction = lastAction
        self.outcome = outcome; self.finish = finish; self.result = result
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The common table keys share this object; only a classic Okey round has `okey` + `stage`.
        if let kind = c.soft(String.self, .kind), kind != GameKind.okey.rawValue {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "not a classic Okey view")
        }
        okey = try c.decode(OkeyClassicFace.self, forKey: .okey)
        stage = OkeyClassicStage(rawValue: try c.decode(String.self, forKey: .stage)) ?? .ended
        let options = c.soft(Options.self, .options)
        scoring = options?.scoring.flatMap(OkeyScoring.init(rawValue:)) ?? .countdown
        startingPoints = options?.startingPoints ?? 20
        indicator = c.soft(OkeyTile.self, .indicator)
        stockCount = c.soft(Int.self, .stockCount) ?? 0
        first = c.soft(Int.self, .first) ?? 0
        turn = c.soft(Int.self, .turn)
        viewerSeat = c.soft(Int.self, .viewerSeat)
        hand = c.soft([OkeyTile].self, .hand)
        seats = c.soft([OkeyClassicSeatView].self, .seats) ?? []
        canShowIndicator = c.soft(Bool.self, .canShowIndicator) ?? false
        indicatorShown = c.soft(OkeyClassicIndicatorShow.self, .indicatorShown)
        lastAction = c.soft(OkeyClassicLastAction.self, .lastAction)
        outcome = c.soft(String.self, .outcome)
        finish = c.soft(OkeyClassicFinish.self, .finish)
        result = c.soft(OkeyClassicResult.self, .result)
    }

    public static let players = 4
    public var ended: Bool { stage == .ended }
    public var spectator: Bool { viewerSeat == nil }
    public var myTurn: Bool { viewerSeat != nil && turn == viewerSeat && !ended }
    /// The rack the viewer looks at: their own round index, or round index 0 for spectators.
    public var base: Int { viewerSeat ?? 0 }
    public func seat(_ round: Int) -> OkeyClassicSeatView? { seats.first { $0.seat == round } }
    /// The left neighbour (plays just before the viewer); the top of their pile is takeable on a draw.
    public var leftSeat: Int { (base + 3) % Self.players }
    public var leftTop: OkeyTile? { seat(leftSeat)?.discards.last }
    /// Where a round index sits around the felt, counted from the viewer (the next player sits on the right).
    public func place(of round: Int) -> OkeyClassicPlace { OkeyClassicPlace.allCases[((round - base) % 4 + 4) % 4] }
    public var exhausted: Bool { outcome == "stock-exhausted" }
}

/// Seat positions around the felt; each discard pile lies in the corner between its owner and the next player.
public enum OkeyClassicPlace: Int, CaseIterable, Sendable {
    case bottom, right, top, left
    public var pileCorner: OkeyClassicCorner { OkeyClassicCorner(rawValue: rawValue)! }
}
public enum OkeyClassicCorner: Int, Sendable { case bottomRight, topRight, topLeft, bottomLeft }

public extension GameState {
    /// The classic Okey round, or nil before the deal, for a viewer without access, or for another game.
    var okeyClassic: OkeyClassicView? { kind == .okey ? view(as: OkeyClassicView.self) : nil }
    /// The seat at a round index (`orderedSeats`).
    func okeySeat(round: Int) -> GameSeat? { seat(atPosition: round) }
    func okeyName(round: Int, me: String) -> String {
        guard let seat = okeySeat(round: round) else { return "Koltuk \(round + 1)" }
        return seat.userId == me ? "Sen" : seat.name
    }
    /// Rack storage key for this table and round (desktop `rooms-okey-rack:<owner>:<history>:<user>`).
    func okeyRackKey(me: String) -> String { "rooms-okey-rack:\(ownerId):\(history.count):\(me)" }
}

// MARK: - Faces

/// A tile as the rules read it: the sahte okey takes the okey's face and is not wild; the real okey is wild.
struct OkeyClassicPiece {
    let id: String
    let color: OkeyColor
    let value: Int
    let wild: Bool
    init(_ tile: OkeyTile, okey: OkeyClassicFace?) {
        id = tile.id
        wild = tile.isJoker
        if tile.isFalseJoker, let okey { color = okey.color; value = okey.value } else { color = tile.color; value = tile.value }
    }
    static let colors: [OkeyColor] = [.red, .yellow, .blue, .black]
    var colorRank: Int { Self.colors.firstIndex(of: color) ?? 4 }
    /// Desktop/engine sort: red, yellow, blue, black, then value, then id.
    static func byFace(_ a: OkeyClassicPiece, _ b: OkeyClassicPiece) -> Bool {
        if a.colorRank != b.colorRank { return a.colorRank < b.colorRank }
        if a.value != b.value { return a.value < b.value }
        return a.id < b.id
    }
}

// MARK: - Finish search (port of the engine's okeyClassicArrangement)

public struct OkeyClassicArrangement: Equatable, Sendable {
    public let melds: [[OkeyTile]]
    public let pairs: Bool
}

public enum OkeyClassicRules {
    private struct Candidate { let mask: Int; let jokers: Int; let slots: [Int] }

    /// Every run (3-5, 1 may follow 13) or group (3-4 colors) containing natural `i`, using naturals in `mask` and okeys.
    private static func setsContaining(_ naturals: [OkeyClassicPiece], mask: Int, jokers: Int, i: Int) -> [Candidate] {
        var out: [Candidate] = []
        let tile = naturals[i]
        func find(_ color: OkeyColor, _ value: Int, _ used: Int) -> Int {
            for k in naturals.indices where mask & (1 << k) != 0 && used & (1 << k) == 0 && naturals[k].color == color && naturals[k].value == value { return k }
            return -1
        }
        let others = OkeyClassicPiece.colors.filter { $0 != tile.color }.map { find($0, tile.value, 1 << i) }.filter { $0 >= 0 }
        for pick in 0..<(1 << others.count) {
            let chosen = others.enumerated().filter { pick & (1 << $0.offset) != 0 }.map(\.element)
            for j in 0...jokers {
                let size = 1 + chosen.count + j
                guard size >= 3, size <= 4 else { continue }
                out.append(Candidate(mask: chosen.reduce(1 << i) { $0 | (1 << $1) }, jokers: j, slots: [i] + chosen + Array(repeating: -1, count: j)))
            }
        }
        let positions = tile.value == 1 ? [1, 14] : [tile.value]
        for pos in positions {
            for length in 3...5 {
                var start = max(1, pos - length + 1)
                while start <= pos && start + length - 1 <= 14 {
                    let end = start + length - 1
                    func fill(_ q: Int, _ used: Int, _ j: Int, _ slots: [Int]) {
                        if q > end { out.append(Candidate(mask: used, jokers: j, slots: slots)); return }
                        if q == pos { fill(q + 1, used, j, slots + [i]); return }
                        let k = find(tile.color, q == 14 ? 1 : q, used)
                        if k >= 0 { fill(q + 1, used | (1 << k), j, slots + [k]) }
                        if j < jokers { fill(q + 1, used, j + 1, slots + [-1]) }
                    }
                    fill(start, 1 << i, 0, [])
                    start += 1
                }
            }
        }
        return out
    }

    /// Most tiles placeable into runs and groups, with one arrangement (natural index or -1 per slot).
    private static func searchSets(_ naturals: [OkeyClassicPiece], jokers: Int) -> (best: Int, sets: [[Int]]) {
        var memo: [Int: (best: Int, sets: [[Int]])] = [:]
        func solve(_ mask: Int, _ j: Int) -> (best: Int, sets: [[Int]]) {
            if mask == 0 { return (0, []) }
            let key = mask * 4 + j
            if let known = memo[key] { return known }
            var i = 0
            while mask & (1 << i) == 0 { i += 1 }
            var result = solve(mask & ~(1 << i), j)
            for set in setsContaining(naturals, mask: mask, jokers: j, i: i) {
                let rest = solve(mask & ~set.mask, j - set.jokers)
                let total = rest.best + set.slots.count
                if total > result.best { result = (total, [set.slots] + rest.sets) }
            }
            memo[key] = result
            return result
        }
        return solve((1 << naturals.count) - 1, jokers)
    }

    /// Engine çift reading: same color and number; an okey pairs with any single, then with another okey.
    private static func pairCount(_ pieces: [OkeyClassicPiece]) -> (pairs: [[Int]], singles: Int) {
        let naturals = pieces.indices.filter { !pieces[$0].wild }.sorted { OkeyClassicPiece.byFace(pieces[$0], pieces[$1]) }
        var jokers = pieces.indices.filter { pieces[$0].wild }
        var pairs: [[Int]] = [], singles: [Int] = []
        var k = 0
        while k < naturals.count {
            if k + 1 < naturals.count, pieces[naturals[k]].color == pieces[naturals[k + 1]].color, pieces[naturals[k]].value == pieces[naturals[k + 1]].value {
                pairs.append([naturals[k], naturals[k + 1]]); k += 2
            } else { singles.append(naturals[k]); k += 1 }
        }
        while !jokers.isEmpty, !singles.isEmpty { pairs.append([singles.removeFirst(), jokers.removeFirst()]) }
        while jokers.count >= 2 { pairs.append([jokers.removeFirst(), jokers.removeFirst()]) }
        return (pairs, singles.count + jokers.count)
    }

    /// Split 14 tiles into a finishing arrangement (seven pairs win over sets), or nil.
    /// `okey` maps a sahte okey to the okey's face (the server already sends it that way).
    public static func arrangement(_ tiles: [OkeyTile], okey: OkeyClassicFace?) -> OkeyClassicArrangement? {
        guard tiles.count == 14, Set(tiles.map(\.id)).count == 14 else { return nil }
        let pieces = tiles.map { OkeyClassicPiece($0, okey: okey) }
        let pairs = pairCount(pieces)
        if pairs.pairs.count == 7 { return OkeyClassicArrangement(melds: pairs.pairs.map { $0.map { tiles[$0] } }, pairs: true) }
        let order = pieces.indices.filter { !pieces[$0].wild }.sorted { OkeyClassicPiece.byFace(pieces[$0], pieces[$1]) }
        var jokers = pieces.indices.filter { pieces[$0].wild }
        let search = searchSets(order.map { pieces[$0] }, jokers: jokers.count)
        guard search.best == 14 else { return nil }
        let melds = search.sets.map { slots in slots.map { k in k >= 0 ? tiles[order[k]] : tiles[jokers.removeFirst()] } }
        return OkeyClassicArrangement(melds: melds, pairs: false)
    }

    /// A tile whose discard finishes this 15-tile rack (an okey first: it doubles the score), or nil.
    public static func finishingTile(_ rack: [OkeyTile], okey: OkeyClassicFace?) -> OkeyTile? {
        guard rack.count == 15 else { return nil }
        for tile in rack.filter(\.isJoker) + rack.filter({ !$0.isJoker }) where arrangement(rack.filter { $0.id != tile.id }, okey: okey) != nil { return tile }
        return nil
    }

    /// Whether throwing `tileID` from this 15-tile rack finishes the round.
    public static func canFinish(_ rack: [OkeyTile], with tileID: String, okey: OkeyClassicFace?) -> Bool {
        guard rack.count == 15, rack.contains(where: { $0.id == tileID }) else { return false }
        return arrangement(rack.filter { $0.id != tileID }, okey: okey) != nil
    }
}

// MARK: - Rack (2 x 15 ıstaka, local order only)

public enum OkeyClassicRack {
    public static let columns = 15
    public static let cells = columns * 2
    /// Cell -> tile id or empty.
    public typealias Layout = [String?]
    public static var empty: Layout { Array(repeating: nil, count: cells) }

    /// Keep known tiles where the player put them, drop tiles that left, put new ones (a draw, the deal) in the first empty cell.
    public static func reconcile(_ layout: Layout?, ids: [String]) -> Layout {
        let wanted = Set(ids)
        var seen = Set<String>(), next = empty
        for (index, id) in (layout ?? []).prefix(cells).enumerated() {
            if let id, wanted.contains(id), !seen.contains(id) { next[index] = id; seen.insert(id) }
        }
        for id in ids where !seen.contains(id) {
            guard let free = next.firstIndex(where: { $0 == nil }) else { break }
            next[free] = id; seen.insert(id)
        }
        return next
    }

    /// Move a tile to a cell; an occupied cell slides its neighbours toward the nearest gap in that row, or swaps when the row is full.
    public static func move(_ layout: Layout, id: String, to: Int) -> Layout {
        guard let from = layout.firstIndex(of: id), to >= 0, to < cells, from != to else { return layout }
        var next = layout
        next[from] = nil
        if next[to] == nil { next[to] = id; return next }
        let rowStart = to - to % columns, rowEnd = rowStart + columns
        if let cell = (to + 1..<rowEnd).first(where: { next[$0] == nil }) {
            var shift = cell
            while shift > to { next[shift] = next[shift - 1]; shift -= 1 }
            next[to] = id; return next
        }
        if let cell = stride(from: to - 1, through: rowStart, by: -1).first(where: { next[$0] == nil }) {
            var shift = cell
            while shift < to { next[shift] = next[shift + 1]; shift += 1 }
            next[to] = id; return next
        }
        next[from] = next[to]; next[to] = id
        return next
    }

    /// Blocks left to right with one gap between them, never split across rows, then the leftovers after one more gap.
    public static func fromBlocks(_ blocks: [[String]], rest: [String]) -> Layout {
        var next = empty
        var cursor = 0
        func place(_ ids: [String]) -> Bool {
            let column = cursor % columns
            if column + ids.count > columns && ids.count <= columns && column > 0 { cursor += columns - column }
            if cursor + ids.count > cells { return false }
            for (offset, id) in ids.enumerated() { next[cursor + offset] = id }
            cursor += ids.count + 1
            return true
        }
        var fits = true
        for block in blocks where !block.isEmpty { if !place(block) { fits = false; break } }
        if fits {
            var index = min(cursor, cells), remaining = rest
            while !remaining.isEmpty && index < cells {
                if next[index] == nil { next[index] = remaining.removeFirst() }
                index += 1
            }
            if remaining.isEmpty { return next }
        }
        return reconcile(nil, ids: blocks.flatMap { $0 } + rest)
    }

    private static let nodeLimit = 20000

    /// Desktop "Seri diz" search: runs and groups covering as many tiles as possible, okeys filling gaps.
    static func bestSets(_ all: [OkeyClassicPiece]) -> (sets: [[OkeyClassicPiece]], rest: [OkeyClassicPiece]) {
        let naturals = all.filter { !$0.wild }.sorted(by: OkeyClassicPiece.byFace), wilds = all.filter(\.wild)
        var best: [[OkeyClassicPiece]] = [], bestCovered = 0, nodes = 0
        func search(_ remaining: [OkeyClassicPiece], _ free: [OkeyClassicPiece], _ sets: [[OkeyClassicPiece]], _ covered: Int) {
            nodes += 1
            if nodes > nodeLimit { return }
            if covered + remaining.count + free.count <= bestCovered { return }
            guard let tile = remaining.first else {
                if covered > bestCovered { bestCovered = covered; best = sets }
                return
            }
            let others = Array(remaining.dropFirst())
            var run = [tile], pool = others, spare = free, value = tile.value
            while run.count < 13 {
                if value == 1 && run.count > 1 { break } // 12-13-1 ends the run
                let nextValue = value == 13 ? 1 : value + 1
                if let index = pool.firstIndex(where: { $0.color == tile.color && $0.value == nextValue }) {
                    run.append(pool.remove(at: index))
                } else if !spare.isEmpty {
                    run.append(spare.removeFirst())
                } else { break }
                value = nextValue
                if run.count >= 3 { search(pool, spare, sets + [run], covered + run.count) }
            }
            var partners: [OkeyClassicPiece] = []
            for face in others where face.value == tile.value && face.color != tile.color && !partners.contains(where: { $0.color == face.color }) {
                partners.append(face)
            }
            for mask in stride(from: (1 << partners.count) - 1, through: 0, by: -1) {
                let chosen = partners.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                for size in stride(from: 4, through: 3, by: -1) {
                    let needed = size - 1 - chosen.count
                    guard needed >= 0, needed <= free.count else { continue }
                    let group = [tile] + chosen + free.prefix(needed)
                    let chosenIDs = Set(chosen.map(\.id))
                    search(others.filter { !chosenIDs.contains($0.id) }, Array(free.dropFirst(needed)), sets + [group], covered + group.count)
                }
            }
            search(others, free, sets, covered)
        }
        search(naturals, wilds, [], 0)
        let used = Set(best.flatMap { $0 }.map(\.id))
        var rest = naturals.filter { !used.contains($0.id) }
        for wild in wilds where !used.contains(wild.id) {
            // An okey the search did not need extends a set that can take it, else stays with the rest.
            if let target = best.firstIndex(where: { set in
                let value = set.first { !$0.wild }?.value
                return set.allSatisfy { $0.wild || $0.value == value } ? set.count < 4 : set.count < 13
            }) { best[target].append(wild) } else { rest.append(wild) }
        }
        return (best, rest)
    }

    /// Seri diz: a finishing rack in its finishing order when the tiles allow it (the tile to throw last), otherwise
    /// the largest set of runs and groups, each its own block, with the remaining tiles on the right.
    public static func arrangeRuns(_ tiles: [OkeyTile], okey: OkeyClassicFace) -> Layout {
        if let finish = finishing(tiles, okey: okey), !finish.arrangement.pairs {
            return fromBlocks(finish.arrangement.melds.map { $0.map(\.id) }, rest: finish.rest)
        }
        let (sets, rest) = bestSets(tiles.map { OkeyClassicPiece($0, okey: okey) })
        let sortedRest = rest.sorted { a, b in a.wild != b.wild ? !a.wild : OkeyClassicPiece.byFace(a, b) }
        return fromBlocks(sets.map { $0.map(\.id) }, rest: sortedRest.map(\.id))
    }

    /// Çift diz: same color and number side by side, okeys partnering the highest singles, then each other.
    public static func arrangePairs(_ tiles: [OkeyTile], okey: OkeyClassicFace) -> Layout {
        let all = tiles.map { OkeyClassicPiece($0, okey: okey) }
        let naturals = all.filter { !$0.wild }.sorted(by: OkeyClassicPiece.byFace)
        var spare = all.filter(\.wild)
        var pairs: [[OkeyClassicPiece]] = [], singles: [OkeyClassicPiece] = []
        var index = 0
        while index < naturals.count {
            if index + 1 < naturals.count, naturals[index].color == naturals[index + 1].color, naturals[index].value == naturals[index + 1].value {
                pairs.append([naturals[index], naturals[index + 1]]); index += 2
            } else { singles.append(naturals[index]); index += 1 }
        }
        singles.sort { a, b in a.value != b.value ? a.value > b.value : OkeyClassicPiece.byFace(a, b) }
        while !spare.isEmpty && !singles.isEmpty { pairs.append([singles.removeFirst(), spare.removeFirst()]) }
        while spare.count >= 2 { pairs.append([spare.removeFirst(), spare.removeFirst()]) }
        return fromBlocks(pairs.map { $0.map(\.id) }, rest: (singles.sorted(by: OkeyClassicPiece.byFace) + spare).map(\.id))
    }

    /// The 14 finishing tiles split into sets, plus the tile to throw (15-tile rack), when the rack finishes now.
    public static func finishing(_ tiles: [OkeyTile], okey: OkeyClassicFace?) -> (arrangement: OkeyClassicArrangement, rest: [String])? {
        if tiles.count == 14 { return OkeyClassicRules.arrangement(tiles, okey: okey).map { ($0, []) } }
        guard let tile = OkeyClassicRules.finishingTile(tiles, okey: okey),
              let arrangement = OkeyClassicRules.arrangement(tiles.filter { $0.id != tile.id }, okey: okey) else { return nil }
        return (arrangement, [tile.id])
    }
}

/// Keeps the rack order per table and round in UserDefaults (JSON; a few recent rounds, older ones are dropped).
public struct OkeyClassicRackStore {
    private let defaults: UserDefaults
    private let storageKey: String
    public static let keep = 4
    private struct Entry: Codable { let key: String; let cells: [String?] }
    public init(defaults: UserDefaults = .standard, storageKey: String = "rooms.okey.racks") { self.defaults = defaults; self.storageKey = storageKey }
    private var entries: [Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    public func load(_ key: String) -> OkeyClassicRack.Layout? { entries.first { $0.key == key }?.cells }
    public func save(_ layout: OkeyClassicRack.Layout, for key: String) {
        let next = [Entry(key: key, cells: Array(layout.prefix(OkeyClassicRack.cells)))] + entries.filter { $0.key != key }
        if let data = try? JSONEncoder().encode(Array(next.prefix(Self.keep))) { defaults.set(data, forKey: storageKey) }
    }
}

// MARK: - Controls

/// Which table controls are live, from the server's `legalActions` plus the local finish check.
public struct OkeyClassicControls: Equatable, Sendable {
    /// "Kapalı taş çek" / tap the middle stack.
    public let drawStock: Bool
    /// "Önceki taşı al" / tap the left neighbour's top tile.
    public let takeLeft: Bool
    /// "At" with the selected tile (or drag it onto your pile).
    public let discard: Bool
    /// The tile "Bitir" throws (the selected one when it finishes, else any finishing tile); nil keeps "Bitir" off.
    public let finishTileID: String?
    /// "Göstergeyi göster".
    public let showIndicator: Bool
    /// Drag targets: a tile may be thrown at all right now.
    public var canThrow: Bool { discard || finishTileID != nil }

    /// `finisher`: `OkeyClassicControls.finisher(view)` (computed once per rack; it runs the finish search).
    public init(view: OkeyClassicView?, legalActions: [String], busy: Bool, selected: String?, finisher: String?) {
        let live = !busy && view.map { !$0.ended && !$0.spectator } == true
        let legal = Set(live ? legalActions : [])
        let hand = view?.hand ?? []
        let selectedInHand = selected.flatMap { id in hand.contains { $0.id == id } ? id : nil }
        drawStock = legal.contains("draw")
        takeLeft = legal.contains("draw") && view?.leftTop != nil
        discard = legal.contains("discard") && selectedInHand != nil
        if legal.contains("finish"), let view {
            if let selectedInHand, OkeyClassicRules.canFinish(hand, with: selectedInHand, okey: view.okey) { finishTileID = selectedInHand }
            else { finishTileID = finisher.flatMap { id in hand.contains { $0.id == id } ? id : nil } }
        } else { finishTileID = nil }
        showIndicator = legal.contains("show-indicator")
    }

    /// A finishing tile for the viewer's own 15-tile rack on their discard step, else nil.
    public static func finisher(_ view: OkeyClassicView) -> String? {
        guard view.myTurn, view.stage == .discard, let hand = view.hand else { return nil }
        return OkeyClassicRules.finishingTile(hand, okey: view.okey)?.id
    }
}

// MARK: - Texts and summary

public enum OkeyClassicText {
    public static func tileName(_ tile: OkeyTile, okey: OkeyClassicFace) -> String {
        if tile.isFalseJoker { return "Sahte okey · \(okey.title)" }
        if tile.isJoker { return "Okey · \(tile.color.title) \(tile.value)" }
        return "\(tile.color.title) \(tile.value)"
    }
    /// One line for a move; `mine` uses the second person.
    public static func describe(_ action: OkeyClassicLastAction, name: String, mine: Bool, okey: OkeyClassicFace) -> String {
        let tile = action.tile.map { tileName($0, okey: okey) } ?? "taş"
        switch action.kind {
        case .draw:
            if !action.fromDiscard { return mine ? "Ortadan çektin" : "\(name) ortadan çekti" }
            return mine ? "\(tile) aldın" : "\(name) \(tile) aldı"
        case .discard: return mine ? "\(tile) attın" : "\(name) \(tile) attı"
        case .showIndicator: return mine ? "Göstergeyi gösterdin" : "\(name) göstergeyi gösterdi"
        case .finish: return mine ? "\(tile) atıp bitirdin" : "\(name) \(tile) atıp bitirdi"
        }
    }
    /// Why the round ended, in one line.
    public static func endReason(_ view: OkeyClassicView, name: (Int) -> String) -> String {
        guard !view.exhausted, let finish = view.finish else { return "Ortada taş kalmadı · Kazanan yok" }
        let who = name(finish.seat)
        if finish.pairs && finish.okeyDiscard { return "\(who) çifte gidip okey atarak bitirdi" }
        if finish.pairs { return "\(who) çifte gidip bitirdi" }
        if finish.okeyDiscard { return "\(who) okey atarak bitirdi" }
        return "\(who) bitirdi"
    }
    public static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : String(value) }
}

/// One row of the round summary.
public struct OkeyClassicSummaryRow: Equatable, Sendable, Identifiable {
    public let round: Int
    public let name: String
    /// This round's points; nil when the view has no result.
    public let points: Int?
    /// Countdown: points left (start + table score); winner mode: the table total. Nil without statistics.
    public let total: Int?
    public let winner: Bool
    public var id: Int { round }
}

public extension GameState {
    func okeySummary(_ view: OkeyClassicView, me: String) -> [OkeyClassicSummaryRow] {
        (0..<OkeyClassicView.players).map { round in
            let seat = okeySeat(round: round)
            let score = seat.flatMap { table.statistics[$0.userId]?.score }
            let points = view.result?.points
            return OkeyClassicSummaryRow(
                round: round, name: okeyName(round: round, me: me),
                points: points.flatMap { $0.indices.contains(round) ? $0[round] : nil },
                total: score.map { view.scoring == .countdown ? view.startingPoints + $0 : $0 },
                winner: view.result?.winners.contains(round) == true)
        }
    }
}

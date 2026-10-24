import Foundation

// 101 Okey table logic for the iPhone table (`Okey101TableView`). Mirrors the desktop table in
// `apps/desktop/src/games/okey101/` (preview.ts, arrange.ts, rack-layout.ts, moves.ts, OkeyRoundSummary.tsx) and the
// engine rules in `packages/games/src/okey101.ts` / `okey101-table.ts`. The server still decides every move; this only
// previews, arranges the local rack and gates controls on `legalActions`.
// All seat indexes here are positions (index into `GameState.orderedSeats`), like `Okey101HandView`.

private extension KeyedDecodingContainer {
    func okey101Soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

// MARK: - View extras

/// House rules of the table (`view.rules.options`, profile `rooms-101-v2`). A profile without options, or a missing
/// key, keeps the v1 behaviour (`okey101Options` merges the options over the legacy switches).
public struct Okey101HouseRules: Codable, Equatable, Sendable {
    public var islekPenalty = false
    public var eldenBitme = false
    public var pickupPenalty = false
    public var pickupUndo = true
    public var foldingPairs = false
    public var gostergeBonus = false
    /// 12-13-1 runs; that high 1 counts 11.
    public var wrapAround = false
    public var reclaimedOkeyMustBeUsed = false
    public static let legacy = Okey101HouseRules()
    /// The published v2 defaults (`okey101DefaultOptions`).
    public static let standard = Okey101HouseRules(islekPenalty: true, eldenBitme: true, pickupPenalty: true, pickupUndo: false,
                                                   foldingPairs: true, gostergeBonus: true, wrapAround: false, reclaimedOkeyMustBeUsed: false)
    public init(islekPenalty: Bool = false, eldenBitme: Bool = false, pickupPenalty: Bool = false, pickupUndo: Bool = true,
                foldingPairs: Bool = false, gostergeBonus: Bool = false, wrapAround: Bool = false, reclaimedOkeyMustBeUsed: Bool = false) {
        self.islekPenalty = islekPenalty; self.eldenBitme = eldenBitme; self.pickupPenalty = pickupPenalty; self.pickupUndo = pickupUndo
        self.foldingPairs = foldingPairs; self.gostergeBonus = gostergeBonus; self.wrapAround = wrapAround
        self.reclaimedOkeyMustBeUsed = reclaimedOkeyMustBeUsed
    }
    enum CodingKeys: String, CodingKey { case islekPenalty, eldenBitme, pickupPenalty, pickupUndo, foldingPairs, gostergeBonus, wrapAround, reclaimedOkeyMustBeUsed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), base = Self.legacy
        islekPenalty = c.okey101Soft(Bool.self, .islekPenalty) ?? base.islekPenalty
        eldenBitme = c.okey101Soft(Bool.self, .eldenBitme) ?? base.eldenBitme
        pickupPenalty = c.okey101Soft(Bool.self, .pickupPenalty) ?? base.pickupPenalty
        pickupUndo = c.okey101Soft(Bool.self, .pickupUndo) ?? base.pickupUndo
        foldingPairs = c.okey101Soft(Bool.self, .foldingPairs) ?? base.foldingPairs
        gostergeBonus = c.okey101Soft(Bool.self, .gostergeBonus) ?? base.gostergeBonus
        wrapAround = c.okey101Soft(Bool.self, .wrapAround) ?? base.wrapAround
        reclaimedOkeyMustBeUsed = c.okey101Soft(Bool.self, .reclaimedOkeyMustBeUsed) ?? base.reclaimedOkeyMustBeUsed
    }
    /// Short Turkish lines for the rules badge row (only the switches that change play).
    public var badges: [String] {
        var list: [String] = []
        if wrapAround { list.append("12-13-1 serbest") }
        if islekPenalty { list.append("İşlek taş +101") }
        if pickupPenalty { list.append("Yandan alınıp kullanılmayan +101") }
        if eldenBitme { list.append("Elden bitme ×2") }
        if gostergeBonus { list.append("Gösterge −101") }
        return list
    }
}

/// One line of `view.penaltyLog`: işlek, unused side pick, reclaimed okey (+101) or gösterge (−101).
public struct Okey101PenaltyEntry: Codable, Equatable, Sendable {
    public let seat: Int
    public let reason: String
    public let amount: Int
    public init(seat: Int, reason: String, amount: Int) { self.seat = seat; self.reason = reason; self.amount = amount }
    public var reasonTitle: String {
        switch reason {
        case "islek": "İşlek taş attı"
        case "pickup": "Yandan aldığı taşı kullanmadı"
        case "reclaimed-okey": "Geri aldığı okeyi kullanmadı"
        case "gosterge": "Göstergeyi gösterdi"
        default: reason
        }
    }
}

/// How a round ended: okey/çift finishes double, elden bitme doubles again (at most ×4).
public struct Okey101Ending: Codable, Equatable, Sendable {
    public let okey: Bool
    public let pairs: Bool
    public let elden: Bool
    public let multiplier: Int
    public init(okey: Bool, pairs: Bool, elden: Bool, multiplier: Int) { self.okey = okey; self.pairs = pairs; self.elden = elden; self.multiplier = multiplier }
}

/// The 101 keys `Okey101HandView` does not model, read from the live view or from a history `result` (the round
/// summary has the same names minus `penalties`, `requiredPairs`, `highestPairs`).
public struct Okey101TableInfo: Decodable, Equatable, Sendable {
    public var profileID = "rooms-101-v1"
    public var folding = false
    public var teams = false
    public var house = Okey101HouseRules.legacy
    public var indicator: OkeyTile?
    public var highestOpening = 100
    public var highestPairs = 0
    /// Pairs a first pair opening needs (server `required101Pairs`); 5 on older servers.
    public var requiredPairs = 5
    public var opened: [String?] = []
    public var scores: [Int] = []
    public var winner: Int?
    public var penalties: [Int] = []
    public var penaltyLog: [Okey101PenaltyEntry] = []
    public var gostergeShown: [Bool] = []
    public var ending: Okey101Ending?
    public var stage = ""

    struct Rules: Decodable {
        let id: String?; let folding: Bool?; let teams: Bool?; let options: Okey101HouseRules?
    }
    enum CodingKeys: String, CodingKey {
        case rules, indicator, highestOpening, highestPairs, requiredPairs, opened, scores, winner, penalties, penaltyLog, gostergeShown, ending, stage
    }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let rules = c.okey101Soft(Rules.self, .rules) {
            profileID = rules.id ?? profileID; folding = rules.folding ?? false; teams = rules.teams ?? false
            house = rules.options ?? .legacy
        }
        indicator = c.okey101Soft(OkeyTile.self, .indicator)
        highestOpening = c.okey101Soft(Int.self, .highestOpening) ?? 100
        highestPairs = c.okey101Soft(Int.self, .highestPairs) ?? 0
        requiredPairs = c.okey101Soft(Int.self, .requiredPairs) ?? 5
        opened = c.okey101Soft([String?].self, .opened) ?? []
        scores = c.okey101Soft([Int].self, .scores) ?? []
        winner = c.okey101Soft(Int.self, .winner)
        penalties = c.okey101Soft([Int].self, .penalties) ?? []
        penaltyLog = c.okey101Soft([Okey101PenaltyEntry].self, .penaltyLog) ?? []
        gostergeShown = c.okey101Soft([Bool].self, .gostergeShown) ?? []
        ending = c.okey101Soft(Okey101Ending.self, .ending)
        stage = c.okey101Soft(String.self, .stage) ?? ""
    }
    /// The points a first run opening needs: 101, or more than the highest opening on a katlamalı table.
    public var openingThreshold: Int { folding ? max(101, highestOpening + 1) : 101 }
    /// Per-position penalty total: `penalties` when sent, else summed from the log (history summaries).
    public func penalty(atPosition position: Int) -> Int {
        if penalties.indices.contains(position) { return penalties[position] }
        return penaltyLog.filter { $0.seat == position }.reduce(0) { $0 + $1.amount }
    }
    public func openedMode(atPosition position: Int) -> String? { opened.indices.contains(position) ? opened[position] : nil }
}

public extension GameState {
    /// The 101 keys beyond `okey101` (house rules, penalties, ending); nil without a 101 hand.
    var okey101Info: Okey101TableInfo? { kind == .okey101 && okey101 != nil ? view(as: Okey101TableInfo.self) : nil }
    /// The last finished round's summary from the history (also for a viewer who arrives after it ended).
    var okey101LastRound: Okey101TableInfo? {
        guard kind == .okey101, let result = history.last?.result, let data = try? JSONEncoder().encode(result) else { return nil }
        return try? JSONDecoder().decode(Okey101TableInfo.self, from: data)
    }
    /// The round's turn as a position: the view's own, else the game's seat number mapped to a position.
    var okey101TurnPosition: Int? {
        guard status == .playing else { return nil }
        if let turn = okey101?.turn { return turn }
        return turnSeat.flatMap { seat in orderedSeats.firstIndex { $0.seat == seat.seat } }
    }
    /// Points per user over every finished 101 round at this table (history `scores` by position).
    var okey101Totals: [String: Int] {
        var totals: [String: Int] = [:]
        for entry in history {
            guard let data = try? JSONEncoder().encode(entry.result), let info = try? JSONDecoder().decode(Okey101TableInfo.self, from: data) else { continue }
            for (position, score) in info.scores.enumerated() {
                guard let user = entry.seats?.first(where: { $0.position == position })?.userId else { continue }
                totals[user, default: 0] += score
            }
        }
        return totals
    }
}

// MARK: - Tiles

public extension OkeyTile {
    /// A sahte okey (★): the two tiles with the okey's face that are not wild (server `fake`, physical ids `false-joker-N`).
    var okey101IsFake: Bool { !isJoker && isFalseJoker }
    /// VoiceOver / log name: "Kırmızı 7", "Okey · Mavi 3", "Sahte okey".
    var okey101Label: String {
        if isFalseJoker && !isJoker { return "Sahte okey" }
        return isJoker ? "Okey · \(color.title) \(value)" : "\(color.title) \(value)"
    }
}

// MARK: - Preview (server readings)

/// The okey readings the server applies to a new meld (`assignedMeld`) and the meld/opening checks
/// (`validate101MeldWith`, `validate101Opening`, `validate101Pairs`).
public enum Okey101Preview {
    public enum Failure: String, Error, Equatable, Sendable {
        case invalidMeld = "INVALID_MELD"
        case needsNaturalTile = "MELD_NEEDS_NATURAL_TILE"
        case pairRequired = "PAIR_REQUIRED"
        case invalidWildcardMeld = "INVALID_WILDCARD_MELD"
        case tilesNotInHand = "TILES_NOT_IN_HAND"
        case openingTooLow = "OPENING_TOO_LOW"
        case invalidPairsOpening = "INVALID_PAIRS_OPENING"
    }
    static let colors: [OkeyColor] = [.red, .yellow, .blue, .black]

    private static func wild(_ tile: OkeyTile, color: OkeyColor, value: Int) -> OkeyTile { OkeyTile(id: tile.id, color: color, value: value, joker: true) }

    /// Run reading of an ordered meld: okeys take the value of their position (a 14 is a high 1).
    static func runReading(_ tiles: [OkeyTile], wrapAround: Bool) -> [OkeyTile]? {
        let fixed = tiles.enumerated().filter { !$0.element.isJoker }
        guard let head = fixed.first, fixed.allSatisfy({ $0.element.color == head.element.color }) else { return nil }
        func positions(_ item: (offset: Int, element: OkeyTile)) -> [Int] {
            wrapAround && item.element.value == 1 && item.offset > 0 ? [1, 14] : [item.element.value]
        }
        for first in positions(head) {
            let start = first - head.offset
            guard fixed.allSatisfy({ positions($0).contains(start + $0.offset) }) else { continue }
            guard start >= 1, start + tiles.count - 1 <= (wrapAround ? 14 : 13) else { continue }
            return tiles.enumerated().map { index, tile in
                tile.isJoker ? wild(tile, color: head.element.color, value: start + index == 14 ? 1 : start + index) : tile
            }
        }
        return nil
    }
    /// Group reading: okeys take the shared value and the colours no natural tile uses.
    static func groupReading(_ tiles: [OkeyTile]) -> [OkeyTile]? {
        let fixed = tiles.filter { !$0.isJoker }
        guard let head = fixed.first, fixed.allSatisfy({ $0.value == head.value }), Set(fixed.map(\.color)).count == fixed.count else { return nil }
        var unused = colors.filter { color in !fixed.contains { $0.color == color } }
        guard tiles.count <= fixed.count + unused.count else { return nil }
        return tiles.map { tile in tile.isJoker ? wild(tile, color: unused.removeFirst(), value: head.value) : tile }
    }

    /// Points of a resolved meld (a high 1 after 13 counts 11); throws when it is not a valid run or group.
    public static func meldPoints(_ tiles: [OkeyTile], wrapAround: Bool) throws -> Int {
        guard (3...13).contains(tiles.count), Set(tiles.map(\.id)).count == tiles.count,
              tiles.allSatisfy({ (1...13).contains($0.value) }) else { throw Failure.invalidMeld }
        let high = wrapAround && tiles.count >= 3 && tiles[tiles.count - 1].value == 1 && tiles[tiles.count - 2].value == 13
        let values = tiles.enumerated().map { high && $0.offset == tiles.count - 1 ? 14 : $0.element.value }
        let run = tiles.allSatisfy { $0.color == tiles[0].color } && values.indices.allSatisfy { $0 == 0 || values[$0] == values[$0 - 1] + 1 }
        let group = tiles.count <= 4 && tiles.allSatisfy { $0.value == tiles[0].value } && Set(tiles.map(\.color)).count == tiles.count
        guard run || group else { throw Failure.invalidMeld }
        return run && high ? values.reduce(0) { $0 + ($1 == 14 ? 11 : $1) } : tiles.reduce(0) { $0 + $1.value }
    }
    static func validates(_ tiles: [OkeyTile], wrapAround: Bool) -> Bool { (try? meldPoints(tiles, wrapAround: wrapAround)) != nil }

    private static func allReadings(_ tiles: [OkeyTile], wrapAround: Bool) -> [(kind: OkeyMeldKind, tiles: [OkeyTile])] {
        var list: [(kind: OkeyMeldKind, tiles: [OkeyTile])] = []
        if let run = runReading(tiles, wrapAround: wrapAround) { list.append((.run, run)) }
        if let group = groupReading(tiles) { list.append((.group, group)) }
        return list
    }
    /// Valid readings of a new run/group meld with okeys, run first (the server's order); empty without okeys.
    public static func readings(_ tiles: [OkeyTile], wrapAround: Bool) -> [OkeyMeldKind] {
        guard tiles.contains(where: \.isJoker) else { return [] }
        return allReadings(tiles, wrapAround: wrapAround).filter { validates($0.tiles, wrapAround: wrapAround) }.map(\.kind)
    }
    /// The okeys allow both a run and a group: the player chooses "Sıralı" / "Aynı sayı" (`meldKinds`).
    public static func isAmbiguous(_ tiles: [OkeyTile], wrapAround: Bool) -> Bool { readings(tiles, wrapAround: wrapAround).count > 1 }

    /// The tiles of a draft meld as the server will read them (okeys carry the face they stand for). With both
    /// readings legal `kind` picks, otherwise the first valid one; a reading that cannot validate is never preferred.
    public static func resolve(_ tiles: [OkeyTile], pairs: Bool, kind: OkeyMeldKind? = nil, wrapAround: Bool) throws -> [OkeyTile] {
        guard tiles.contains(where: \.isJoker) else { return tiles }
        let fixed = tiles.filter { !$0.isJoker }
        guard let head = fixed.first else {
            if pairs && tiles.count == 2 { return tiles }
            throw Failure.needsNaturalTile
        }
        if pairs {
            guard tiles.count == 2 else { throw Failure.pairRequired }
            return tiles.map { $0.isJoker ? wild($0, color: head.color, value: head.value) : $0 }
        }
        let all = allReadings(tiles, wrapAround: wrapAround)
        let valid = all.filter { validates($0.tiles, wrapAround: wrapAround) }
        guard let chosen = valid.first(where: { $0.kind == kind }) ?? valid.first ?? all.first else { throw Failure.invalidWildcardMeld }
        return chosen.tiles
    }

    /// Every resolved tile is in the hand by id (an okey may stand for any face; a natural must keep its own).
    static func inHand(_ used: [OkeyTile], hand: [OkeyTile]) -> Bool {
        guard Set(used.map(\.id)).count == used.count else { return false }
        return used.allSatisfy { tile in hand.contains { $0.id == tile.id && ($0.isJoker || ($0.color == tile.color && $0.value == tile.value)) } }
    }
    /// `validate101Opening`: total points of resolved melds, which must reach `threshold`.
    public static func openingTotal(hand: [OkeyTile], melds: [[OkeyTile]], threshold: Int, wrapAround: Bool) throws -> Int {
        let used = melds.flatMap { $0 }
        guard !used.isEmpty, inHand(used, hand: hand) else { throw Failure.tilesNotInHand }
        let total = try melds.reduce(0) { $0 + (try meldPoints($1, wrapAround: wrapAround)) }
        guard total >= threshold else { throw Failure.openingTooLow }
        return total
    }
    /// `validate101Pairs`: at least `required` pairs of one colour and number each.
    public static func validatePairs(hand: [OkeyTile], pairs: [[OkeyTile]], required: Int) throws {
        guard pairs.count >= required, pairs.allSatisfy({ $0.count == 2 && $0[0].color == $0[1].color && $0[0].value == $0[1].value }) else {
            throw Failure.invalidPairsOpening
        }
        guard inHand(pairs.flatMap { $0 }, hand: hand) else { throw Failure.tilesNotInHand }
    }
}

// MARK: - Opening builder

/// One meld being built: tile ids in rack order, and the reading for an ambiguous okey meld.
public struct Okey101Draft: Equatable, Sendable, Identifiable {
    public var ids: [String]
    public var kind: OkeyMeldKind?
    public init(ids: [String], kind: OkeyMeldKind? = nil) { self.ids = ids; self.kind = kind }
    public var id: String { ids.joined(separator: "|") }
}

/// What the opening builder shows: the preview total against what the table requires, and why it cannot open yet.
public struct Okey101OpeningCheck: Equatable, Sendable {
    /// Points of the drafts that read as valid melds (runs mode).
    public let total: Int
    /// Points needed (runs, first opening) or pairs needed (pairs, first opening); 0 once opened.
    public let required: Int
    public let pairCount: Int
    /// Why "Aç" is off; nil when the opening is ready.
    public let problem: String?
    /// Each draft as the server will read it (nil for a draft that does not read as a meld).
    public let resolved: [[OkeyTile]?]
    public var ready: Bool { problem == nil }
    /// The status line under the drafts.
    public var line: String {
        if let problem { return problem }
        if required > 0 { return pairsMode ? "\(pairCount) / \(required) çift · Hazır" : "\(total) / \(required) puan · Hazır" }
        return pairsMode ? "\(pairCount) çift · Hazır" : "\(total) puan · Hazır"
    }
    let pairsMode: Bool
}

public enum Okey101Opening {
    /// Order ids as they sit on the rack (left to right, top shelf first): okeys read by position, so drafts and process
    /// selections must follow the rack, not the tap order.
    public static func rackOrder(_ ids: [String], layout: Okey101Rack.Layout) -> [String] {
        ids.sorted { (layout.firstIndex(of: $0) ?? .max) < (layout.firstIndex(of: $1) ?? .max) }
    }
    /// A new draft from selected tiles; an ambiguous okey meld starts as "Sıralı" (run), as on the desktop.
    public static func draft(_ ids: [String], hand: [OkeyTile], layout: Okey101Rack.Layout, pairs: Bool, wrapAround: Bool) -> Okey101Draft {
        let ordered = rackOrder(ids, layout: layout)
        let tiles = ordered.compactMap { id in hand.first { $0.id == id } }
        return Okey101Draft(ids: ordered, kind: !pairs && Okey101Preview.isAmbiguous(tiles, wrapAround: wrapAround) ? .run : nil)
    }
    /// `meldKinds` for `open`: nil unless some draft carries a reading (pairs never send kinds).
    public static func kinds(_ drafts: [Okey101Draft], pairs: Bool) -> [OkeyMeldKind?]? {
        !pairs && drafts.contains { $0.kind != nil } ? drafts.map(\.kind) : nil
    }
    /// Mirrors the desktop builder: the server's readings, keep one tile to discard, 101 (or the katlamalı bar) or
    /// the required pair count for a first opening, per-meld validity once opened.
    public static func evaluate(drafts: [Okey101Draft], hand: [OkeyTile], pairs: Bool, opened: String?, info: Okey101TableInfo) -> Okey101OpeningCheck {
        let wrap = info.house.wrapAround
        let groups = drafts.map { draft in draft.ids.compactMap { id in hand.first { $0.id == id } } }
        let resolved: [[OkeyTile]?] = zip(groups, drafts).map { group, draft in
            guard let tiles = try? Okey101Preview.resolve(group, pairs: pairs, kind: draft.kind, wrapAround: wrap) else { return nil }
            if pairs { return tiles.count == 2 && tiles[0].color == tiles[1].color && tiles[0].value == tiles[1].value ? tiles : nil }
            return Okey101Preview.validates(tiles, wrapAround: wrap) ? tiles : nil
        }
        let total = pairs ? 0 : resolved.compactMap { $0 }.reduce(0) { $0 + ((try? Okey101Preview.meldPoints($1, wrapAround: wrap)) ?? 0) }
        let first = opened == nil
        let required = first ? (pairs ? info.requiredPairs : info.openingThreshold) : 0
        let used = drafts.reduce(0) { $0 + $1.ids.count }
        func check(_ problem: String?) -> Okey101OpeningCheck {
            Okey101OpeningCheck(total: total, required: required, pairCount: drafts.count, problem: problem, resolved: resolved, pairsMode: pairs)
        }
        if drafts.isEmpty { return check("Açmak için seri veya çift hazırla") }
        if used >= hand.count { return check("Atmak için bir taş bırak") }
        guard resolved.allSatisfy({ $0 != nil }) else { return check(pairs ? "Geçerli çift hazırla" : "Hazır gruplardan biri geçersiz") }
        let melds = resolved.compactMap { $0 }
        guard Okey101Preview.inHand(melds.flatMap { $0 }, hand: hand) else { return check("Hazır gruplardan biri geçersiz") }
        if first {
            if pairs, drafts.count < required { return check("En az \(required) geçerli çift gerekir · \(drafts.count) hazır") }
            if !pairs, total < required { return check("Açılış için en az \(required) puan gerekir · \(total) hazır") }
        }
        return check(nil)
    }
}

// MARK: - Rack (ıstaka)

/// The player's own ıstaka: two shelves of 15 cells, each a tile id or empty. The order is local only (the server keeps
/// an unordered hand). Port of the desktop `rack-layout.ts` + `arrange.ts`.
public enum Okey101Rack {
    public static let columns = 15
    public static let cells = columns * 2
    public typealias Layout = [String?]
    public static var empty: Layout { Array(repeating: nil, count: cells) }

    /// Keep every known tile where the player put it, drop tiles that left the hand, put new tiles in the first empty cell.
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
    /// Move a tile to a cell. An occupied target pushes its neighbours toward the nearest empty cell in the same shelf
    /// (like sliding tiles on a real rack) and swaps when that shelf is full.
    public static func move(_ layout: Layout, id: String, to: Int) -> Layout {
        guard let from = layout.firstIndex(of: id), to >= 0, to < cells, from != to, layout.count == cells else { return layout }
        var next = layout
        next[from] = nil
        if next[to] == nil { next[to] = id; return next }
        let rowStart = to - to % columns, rowEnd = rowStart + columns
        if let cell = (to + 1..<rowEnd).first(where: { next[$0] == nil }) {
            for shift in stride(from: cell, to: to, by: -1) { next[shift] = next[shift - 1] }
            next[to] = id; return next
        }
        if let cell = stride(from: to - 1, through: rowStart, by: -1).first(where: { next[$0] == nil }) {
            for shift in cell..<to { next[shift] = next[shift + 1] }
            next[to] = id; return next
        }
        next[from] = next[to]; next[to] = id
        return next
    }
    /// Blocks left to right with one empty cell between them, never splitting a block across the shelves, then the
    /// leftovers after one more gap; packs without gaps when the gaps would not fit.
    public static func fromBlocks(_ blocks: [[String]], rest: [String]) -> Layout {
        var next = empty, cursor = 0
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
            var index = min(cursor, cells), remaining = rest[...]
            while let id = remaining.first, index < cells {
                if next[index] == nil { next[index] = id; remaining = remaining.dropFirst() }
                index += 1
            }
            if remaining.isEmpty { return next }
        }
        return reconcile(nil, ids: blocks.flatMap { $0 } + rest)
    }
    /// Contiguous tiles on the rack (no gap, never across the two shelves).
    public static func blocks(_ layout: Layout) -> [[String]] {
        var blocks: [[String]] = [], current: [String] = []
        for (cell, id) in layout.enumerated() {
            if cell % columns == 0 && !current.isEmpty { blocks.append(current); current = [] }
            if let id { current.append(id) } else if !current.isEmpty { blocks.append(current); current = [] }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private struct Face: Equatable { let id: String; let color: OkeyColor; let value: Int; let wild: Bool }
    private static func rank(_ color: OkeyColor) -> Int { Okey101Preview.colors.firstIndex(of: color) ?? 4 }
    private static func byFace(_ a: Face, _ b: Face) -> Bool {
        if rank(a.color) != rank(b.color) { return rank(a.color) < rank(b.color) }
        if a.value != b.value { return a.value < b.value }
        return a.id < b.id
    }
    private static func faces(_ tiles: [OkeyTile]) -> [Face] { tiles.map { Face(id: $0.id, color: $0.color, value: $0.value, wild: $0.isJoker) } }
    /// Search budget: keeps a 22-tile rack instant even when it is full of near-runs.
    static let nodeLimit = 20_000

    /// Runs and groups covering as many tiles (then points) as possible, okeys filling gaps.
    private static func bestSets(_ all: [Face], wrapAround: Bool) -> (sets: [[Face]], rest: [Face]) {
        let naturals = all.filter { !$0.wild }.sorted(by: byFace), wilds = all.filter(\.wild)
        func score(_ sets: [[Face]]) -> Int { sets.reduce(0) { $0 + $1.count * 1000 + $1.reduce(0) { $0 + $1.value } } }
        var best: [[Face]] = [], bestScore = 0, nodes = 0
        func search(_ remaining: [Face], _ free: [Face], _ sets: [[Face]], _ skipped: [Face]) {
            nodes += 1
            if nodes > nodeLimit { return }
            guard let tile = remaining.first else {
                let value = score(sets)
                if value > bestScore { bestScore = value; best = sets }
                return
            }
            let others = Array(remaining.dropFirst())
            // Runs that start with this tile (the lowest of its colour still in play).
            var run = [tile], pool = others, spare = free, spareSkipped = skipped, value = tile.value
            while run.count < 13 {
                if value == 13 && !wrapAround { break }
                if value == 1 && run.count > 1 { break } // 12-13-1 ends the run
                let nextValue = value == 13 ? 1 : value + 1
                if let natural = pool.firstIndex(where: { $0.color == tile.color && $0.value == nextValue }) {
                    run.append(pool.remove(at: natural))
                } else if nextValue == 1, let high = spareSkipped.firstIndex(where: { $0.color == tile.color && $0.value == 1 }) {
                    run.append(spareSkipped.remove(at: high))
                } else if !spare.isEmpty {
                    run.append(spare.removeFirst())
                } else { break }
                value = nextValue
                if run.count >= 3 { search(pool, spare, sets + [run], spareSkipped) }
            }
            // Groups with this number: one tile per other colour, okeys making up 3 or 4.
            var partners: [Face] = []
            for face in others where face.value == tile.value && face.color != tile.color && !partners.contains(where: { $0.color == face.color }) {
                partners.append(face)
            }
            for mask in stride(from: (1 << partners.count) - 1, through: 0, by: -1) {
                let chosen = partners.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                for size in [4, 3] {
                    let needed = size - 1 - chosen.count
                    if needed < 0 || needed > free.count { continue }
                    search(others.filter { !chosen.contains($0) }, Array(free.dropFirst(needed)), sets + [[tile] + chosen + free.prefix(needed)], skipped)
                }
            }
            search(others, free, sets, skipped + [tile])
        }
        search(naturals, wilds, [], [])
        let used = Set(best.flatMap { $0 }.map(\.id))
        return (best, (naturals + wilds).filter { !used.contains($0.id) })
    }

    /// Seri diz: the largest set of runs and groups, each its own block, the rest sorted by colour and number, unused okeys last.
    public static func arrangeRuns(_ tiles: [OkeyTile], wrapAround: Bool = false) -> Layout {
        let (sets, rest) = bestSets(faces(tiles), wrapAround: wrapAround)
        let sortedRest = rest.sorted { a, b in a.wild != b.wild ? !a.wild : byFace(a, b) }
        return fromBlocks(sets.map { $0.map(\.id) }, rest: sortedRest.map(\.id))
    }
    /// Çift diz: same colour and number side by side, an okey as the partner of the highest single.
    public static func arrangePairs(_ tiles: [OkeyTile]) -> Layout {
        let all = faces(tiles), naturals = all.filter { !$0.wild }.sorted(by: byFace)
        var spare = all.filter(\.wild), pairs: [[Face]] = [], singles: [Face] = [], index = 0
        while index < naturals.count {
            let face = naturals[index]
            if index + 1 < naturals.count, naturals[index + 1].color == face.color, naturals[index + 1].value == face.value {
                pairs.append([face, naturals[index + 1]]); index += 2
            } else { singles.append(face); index += 1 }
        }
        singles.sort { $0.value != $1.value ? $0.value > $1.value : byFace($0, $1) }
        while !spare.isEmpty && !singles.isEmpty { pairs.append([singles.removeFirst(), spare.removeFirst()]) }
        while spare.count >= 2 { pairs.append([spare.removeFirst(), spare.removeFirst()]) }
        return fromBlocks(pairs.map { $0.map(\.id) }, rest: (singles.sorted(by: byFace) + spare).map(\.id))
    }
    /// Rack blocks that read as a valid meld or pair right now ("Istakadaki dizileri al").
    public static func validBlocks(_ layout: Layout, hand: [OkeyTile], excluding used: Set<String>, pairs: Bool, wrapAround: Bool) -> [[String]] {
        blocks(layout).filter { block in
            guard !block.contains(where: used.contains), pairs ? block.count == 2 : block.count >= 3 else { return false }
            let tiles = block.compactMap { id in hand.first { $0.id == id } }
            guard tiles.count == block.count, let read = try? Okey101Preview.resolve(tiles, pairs: pairs, wrapAround: wrapAround) else { return false }
            return pairs ? read[0].color == read[1].color && read[0].value == read[1].value : Okey101Preview.validates(read, wrapAround: wrapAround)
        }
    }
}

/// Keeps the rack order across view rebuilds and app restarts for one round: a single entry, ignored when the key
/// (table, round, viewer, gösterge) changed, so storage never grows.
public struct Okey101RackStore {
    let defaults: UserDefaults
    static let entryKey = "rooms.okey101.rack"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static func key(ownerID: String, round: Int, userID: String, indicatorID: String?) -> String {
        "\(ownerID):\(round):\(userID):\(indicatorID ?? "")"
    }
    public func load(_ key: String) -> Okey101Rack.Layout? {
        guard let entry = defaults.dictionary(forKey: Self.entryKey), entry["key"] as? String == key,
              let cells = entry["cells"] as? [String], cells.count == Okey101Rack.cells else { return nil }
        return cells.map { $0.isEmpty ? nil : $0 }
    }
    public func save(_ key: String, layout: Okey101Rack.Layout) {
        defaults.set(["key": key, "cells": layout.map { $0 ?? "" }], forKey: Self.entryKey)
    }
}

// MARK: - Seats and controls

/// Places around the table counted from the viewer: the next player (counter-clockwise turn order) sits on the right.
public enum Okey101Place: Int, CaseIterable, Sendable {
    case bottom, right, top, left
    /// The position sitting here for a viewer at `base` (spectators see position 0 at the bottom).
    public func position(base: Int?) -> Int { ((base ?? 0) + rawValue) % 4 }
    /// Where a position sits for a viewer at `base`.
    public static func of(position: Int, base: Int?) -> Okey101Place { Okey101Place(rawValue: ((position - (base ?? 0)) % 4 + 4) % 4) ?? .bottom }
    /// Each discard pile lies in the corner between its owner and the next player: bottom → bottom-right, right →
    /// top-right, top → top-left, left → bottom-left (the pile next to you is the one you may take).
    public var cornerTitle: String {
        switch self {
        case .bottom: "sağ alt"
        case .right: "sağ üst"
        case .top: "sol üst"
        case .left: "sol alt"
        }
    }
}

/// Which 101 controls are on, from the server's `legalActions` only (never guessed from the stage).
public struct Okey101Controls: Equatable, Sendable {
    public var drawStock = false
    /// Take the left player's last discard (it must be used this turn).
    public var takeSide = false
    /// Çek in the discard stage: put the side tile back and draw from the stock (only when the server lists `draw`).
    public var undoPick = false
    public var undoCostsPenalty = false
    public var discard = false
    public var openRuns = false
    public var openPairs = false
    public var process = false
    public var gosterge = false
    public init() {}
    public init(game: GameState, me: String, busy: Bool = false) {
        guard !busy, game.status == .playing, let hand = game.okey101, hand.stage != "ended",
              let position = game.position(of: me), game.okey101TurnPosition == position else {
            // Gösterge is legal on the first turn only, so it is also only on while it is the viewer's turn.
            return
        }
        let info = game.okey101Info ?? Okey101TableInfo()
        if hand.stage == "draw" {
            drawStock = game.can(.draw)
            takeSide = game.can(.draw) && hand.takeableDiscard(forPosition: position) != nil
        } else {
            undoPick = game.can(.draw)
            undoCostsPenalty = info.house.pickupPenalty
        }
        discard = game.can(.discard)
        openRuns = game.can(.open)
        openPairs = game.can(.openPairs)
        process = game.can(.process)
        gosterge = game.can(.gosterge)
    }
    /// "Yandan aldığın taşı bu el kullan; kullanmazsan +101": the side tile the viewer took is still in the hand.
    public static func pickupWarning(picked: String?, game: GameState, me: String) -> Bool {
        guard let picked, let hand = game.okey101, hand.stage == "discard", let position = game.position(of: me), game.okey101TurnPosition == position,
              game.okey101Info?.house.pickupPenalty == true else { return false }
        return game.myOkeyTiles(me).contains { $0.id == picked }
    }
}

// MARK: - Round summary

public struct Okey101SummaryRow: Equatable, Sendable, Identifiable {
    public let position: Int
    public let status: String
    public let penalty: Int
    public let score: Int?
    public let winner: Bool
    public var id: Int { position }
}

public enum Okey101Summary {
    /// Why the round ended, in one line.
    public static func endingLine(_ info: Okey101TableInfo, name: (Int) -> String) -> String {
        guard let winner = info.winner else { return "Taşlar bitti, kimse bitiremedi" }
        let who = name(winner), ending = info.ending
        if ending?.elden == true && ending?.okey == true { return "\(who) elden okey atarak bitirdi" }
        if ending?.elden == true && ending?.pairs == true { return "\(who) elden çift bitirdi" }
        if ending?.elden == true { return "\(who) elden bitirdi" }
        if ending?.okey == true { return "\(who) okey atarak bitirdi" }
        if ending?.pairs == true { return "\(who) çift bitirdi" }
        return "\(who) bitirdi"
    }
    /// "Cezalar ×2" when an okey, çift or elden finish multiplies the others' penalties.
    public static func multiplierLine(_ info: Okey101TableInfo) -> String? {
        guard let multiplier = info.ending?.multiplier, multiplier > 1 else { return nil }
        return "Cezalar ×\(multiplier)"
    }
    public static func ruleLine(_ info: Okey101TableInfo) -> String {
        (info.winner == nil ? "Açanlar elinde kalan taşları, açmayanlar 202 yazar." : "Bitiren −101 (okey ya da çift bitişte −202). Açmayan 202 yazar.")
            + (info.teams ? " Eşli masada eşlerin puanı toplanır." : "")
    }
    public static func rows(_ info: Okey101TableInfo, players: Int = 4) -> [Okey101SummaryRow] {
        (0..<max(players, info.scores.count)).map { position in
            let mode = info.openedMode(atPosition: position)
            let status = position == info.winner ? "Bitirdi" : mode == "pairs" ? "Çift açtı" : mode != nil ? "Açtı" : "Açmadı"
            return Okey101SummaryRow(position: position, status: status, penalty: info.penalty(atPosition: position),
                                     score: info.scores.indices.contains(position) ? info.scores[position] : nil, winner: position == info.winner)
        }
    }
    public static func signed(_ amount: Int) -> String { amount > 0 ? "+\(amount)" : String(amount) }
}

// MARK: - Move log

/// The 101 view has no "last action": short lines from two consecutive public views (discard tops, tile counts,
/// melds, penalties). Port of the desktop `moves.ts`; nothing hidden is used.
public enum Okey101MoveLog {
    public static func describe(before: Okey101HandView, beforeLog: [Okey101PenaltyEntry], after: Okey101HandView, afterLog: [Okey101PenaltyEntry],
                                name: (Int) -> String) -> [String] {
        var lines: [String] = []
        let topsBefore = (0..<4).map { before.discards.indices.contains($0) ? before.discards[$0].last : nil }
        let topsAfter = (0..<4).map { after.discards.indices.contains($0) ? after.discards[$0].last : nil }
        func count(_ view: Okey101HandView, _ seat: Int) -> Int { view.hands.first { $0.seat == seat }?.count ?? 0 }
        var takenBy = Set<Int>()
        for seat in 0..<4 {
            let taker = (seat + 1) % 4
            if let gone = topsBefore[seat], topsAfter[seat]?.id != gone.id, count(after, taker) > count(before, taker) {
                takenBy.insert(taker)
                lines.append("\(name(taker)) yandan \(gone.okey101Label) aldı")
            }
        }
        for seat in 0..<4 where count(after, seat) > count(before, seat) && !takenBy.contains(seat) {
            lines.append("\(name(seat)) ortadan çekti")
        }
        var opened: [Int: Int] = [:]
        for meld in after.melds.dropFirst(before.melds.count) { opened[meld.owner, default: 0] += 1 }
        for owner in opened.keys.sorted() { lines.append("\(name(owner)) \(opened[owner] ?? 0) per açtı") }
        if let mover = before.turn,
           before.melds.enumerated().contains(where: { index, meld in after.melds.indices.contains(index) && after.melds[index].tiles.map(\.id) != meld.tiles.map(\.id) }) {
            lines.append("\(name(mover)) yerdeki pere taş işledi")
        }
        for seat in 0..<4 {
            if let top = topsAfter[seat], top.id != topsBefore[seat]?.id, count(after, seat) < count(before, seat) {
                lines.append("\(name(seat)) \(top.okey101Label) attı")
            }
        }
        for entry in afterLog.dropFirst(beforeLog.count) {
            lines.append("\(name(entry.seat)) · \(entry.reasonTitle) · \(Okey101Summary.signed(entry.amount))")
        }
        return lines
    }
}

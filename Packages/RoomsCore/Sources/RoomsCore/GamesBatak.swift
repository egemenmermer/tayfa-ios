import Foundation

// iPhone Batak table model: the same reading of the Batak view as the desktop table
// (`apps/desktop/src/games/batak/model.ts`, view from `batakView` in packages/games/src/batak-table.ts).
//
// Every seat index here is a ROUND index (position in `GameState.orderedSeats`), not a table seat number:
// `bids`, `tricks`, `hands[].seat`, `trick[].seat`, `bidLog[].seat`, `completedTricks[].winner`, `bidder`, `turn`.
//
// `GameState.batak` (`BatakHandView`) cannot be used for the whole round: the service sends `trump: null` until the
// bidder picks it (outside Koz Maça), which fails that strict decode, and it lacks `passed`, `bidLog`, `trumpBroken`,
// `rules`, `winners` and `buried`. `BatakRound` reads everything softly.

private struct BatakSoftKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
private extension KeyedDecodingContainer where K == BatakSoftKey {
    func soft<T: Decodable>(_ type: T.Type, _ key: String) -> T? { (try? decodeIfPresent(type, forKey: BatakSoftKey(key))) ?? nil }
}
/// A list where one malformed element is dropped instead of failing the list.
private struct BatakLossy<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var items: [T] = []
        while !c.isAtEnd {
            if let item = try? c.decode(T.self) { items.append(item) } else { _ = try? c.decode(JSONValue.self) }
        }
        self.items = items
    }
}

/// `bidLog` entry: a bid or a pass (Koz Maça: each player's call; a pass there means 1).
public struct BatakBidEntry: Codable, Equatable, Sendable {
    public let seat: Int
    public let pass: Bool
    public let amount: Int?
    public init(seat: Int, pass: Bool, amount: Int?) { self.seat = seat; self.pass = pass; self.amount = amount }
    enum CodingKeys: String, CodingKey { case seat, action, amount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = (try? c.decode(Int.self, forKey: .seat)) ?? 0
        pass = (try? c.decode(String.self, forKey: .action)) == "pass"
        amount = (try? c.decodeIfPresent(Int.self, forKey: .amount)) ?? nil
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seat, forKey: .seat); try c.encode(pass ? "pass" : "bid", forKey: .action)
        try c.encodeIfPresent(amount, forKey: .amount)
    }
}

public enum BatakStage: String, Sendable { case bidding, trump, bury, playing, ended }

/// One Batak round as this viewer sees it.
public struct BatakRound: Decodable, Equatable, Sendable {
    public var variant: BatakVariant
    public var stage: BatakStage
    public var turn: Int?
    public var bid: Int
    public var bids: [Int]
    public var bidder: Int
    public var passed: [Int]
    public var bidLog: [BatakBidEntry]
    /// Nil until the bidder picks it (always spades in Koz Maça).
    public var trump: CardSuit?
    public var trumpBroken: Bool
    public var rules: BatakHouseRules
    public var tricks: [Int]
    public var trick: [BatakPlay]
    public var scores: [Int]
    /// Per round index, once the round ended.
    public var winners: [Bool]?
    public var completedTricks: [BatakTrick]
    public var hands: [BatakHandSlot]
    /// The Gömmeli bidder's own gömü after burying; empty for everyone else.
    public var buried: [PlayingCard]
    public var buriedCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BatakSoftKey.self)
        guard let stageName = c.soft(String.self, "stage"), let hands = c.soft(BatakLossy<BatakHandSlot>.self, "hands") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a Batak round"))
        }
        variant = c.soft(String.self, "variant").flatMap(BatakVariant.init(rawValue:)) ?? .ihaleli
        stage = BatakStage(rawValue: stageName) ?? .playing
        turn = c.soft(Int.self, "turn")
        bid = c.soft(Int.self, "bid") ?? 0
        bids = c.soft([Int].self, "bids") ?? []
        bidder = c.soft(Int.self, "bidder") ?? 0
        passed = c.soft([Int].self, "passed") ?? []
        bidLog = c.soft(BatakLossy<BatakBidEntry>.self, "bidLog")?.items ?? []
        let trump = c.soft(String.self, "trump").flatMap(CardSuit.init(rawValue:))
        // Older services sent "spades" before the pick; never show a trump the bidder has not chosen.
        let chosen = variant == .kozMaca || !(stage == .bidding || stage == .trump)
        self.trump = chosen ? (trump ?? (variant == .kozMaca ? .spades : nil)) : nil
        trumpBroken = c.soft(Bool.self, "trumpBroken") ?? false
        let rules = c.soft([String: JSONValue].self, "rules") ?? [:]
        func flag(_ key: String, _ fallback: Bool) -> Bool { if case .bool(let value)? = rules[key] { return value }; return fallback }
        self.rules = BatakHouseRules(noTrumpLeadUntilBroken: flag("noTrumpLeadUntilBroken", true),
                                     defenderBatakPenalty: flag("defenderBatakPenalty", false),
                                     writeContract: flag("writeContract", false))
        tricks = c.soft([Int].self, "tricks") ?? []
        trick = c.soft(BatakLossy<BatakPlay>.self, "trick")?.items ?? []
        scores = c.soft([Int].self, "scores") ?? []
        winners = c.soft([Bool].self, "winners")
        completedTricks = c.soft(BatakLossy<BatakTrick>.self, "completedTricks")?.items ?? []
        self.hands = hands.items
        buried = c.soft(BatakLossy<PlayingCard>.self, "buried")?.items ?? []
        buriedCount = c.soft(Int.self, "buriedCount") ?? 0
    }

    // MARK: Seats

    /// Players in the round: the hand slots, else the seated players.
    public func playerCount(seated: Int) -> Int { hands.isEmpty ? seated : hands.count }
    public func cards(at round: Int?) -> [PlayingCard] { hands.first { $0.seat == round }?.cards ?? [] }
    public func count(at round: Int) -> Int { hands.first { $0.seat == round }?.count ?? 0 }

    // MARK: Auction

    /// The bids the viewer may say now; empty when none is allowed (never a trapping range).
    public var bidOptions: [Int] {
        if variant == .kozMaca { return Array(1...13) }
        let minimum = max(variant.minimumBid, bid + 1), maximum = variant.maximumBid
        return minimum <= maximum ? Array(minimum...maximum) : []
    }
    /// What a seat said last in the auction ("Pas", "7"; Koz Maça: its call, pass = 1).
    public func lastBid(of round: Int) -> String? {
        guard let entry = bidLog.last(where: { $0.seat == round }) else { return nil }
        if variant == .kozMaca { return String(entry.amount ?? 1) }
        return entry.pass ? "Pas" : entry.amount.map(String.init) ?? ""
    }
    /// One line for a bid ("Ece 7 dedi", "Can pas dedi", Koz Maça "Ece 3 el dedi").
    public func bidLine(_ entry: BatakBidEntry, name: String) -> String {
        if variant == .kozMaca { return "\(name) \(entry.amount ?? 1) el dedi" }
        return entry.pass ? "\(name) pas dedi" : "\(name) \(entry.amount ?? 0) dedi"
    }

    // MARK: Cards

    /// The cards the viewer may play now: the engine's `legalBatakCards` with this round's rules and trump state
    /// (what the server checks). Empty unless it is the viewer's turn to play.
    public func legalCardIDs(viewer: Int?) -> Set<String> {
        guard stage == .playing, let viewer, turn == viewer, let trump else { return [] }
        return Set(Self.legalCards(cards(at: viewer), trick: trick, trump: trump, trumpBroken: trumpBroken, rules: rules).map(\.id))
    }
    /// Literal port of `legalBatakCards` (packages/games/src/batak.ts).
    public static func legalCards(_ hand: [PlayingCard], trick: [BatakPlay], trump: CardSuit, trumpBroken: Bool, rules: BatakHouseRules) -> [PlayingCard] {
        guard let lead = trick.first?.card.suit else {
            if rules.noTrumpLeadUntilBroken && !trumpBroken {
                let open = hand.filter { $0.suit != trump }
                if !open.isEmpty { return open }
            }
            return hand
        }
        let following = hand.filter { $0.suit == lead }
        if !following.isEmpty {
            let highest = trick.filter { $0.card.suit == lead }.map(\.card.rank).max() ?? 0
            let higher = following.filter { $0.rank > highest }
            return !higher.isEmpty && !trick.contains { $0.card.suit == trump && lead != trump } ? higher : following
        }
        let trumps = hand.filter { $0.suit == trump }
        if trumps.isEmpty { return hand }
        let highestTrump = trick.filter { $0.card.suit == trump }.map(\.card.rank).max() ?? 0
        let higher = trumps.filter { $0.rank > highestTrump }
        return higher.isEmpty ? trumps : higher
    }

    /// "Koz kırıldı / kırılmadı" applies when the table plays K1 and the trump is known.
    public var showsTrumpBroken: Bool { rules.noTrumpLeadUntilBroken && trump != nil }

    // MARK: Contract and summary

    /// Tricks a seat has to take: the contract for the bidder (the team in Eşli), Koz Maça's own call.
    public func target(of round: Int) -> Int? {
        if variant == .kozMaca { let call = bids.indices.contains(round) ? bids[round] : 0; return call > 0 ? call : nil }
        if stage == .bidding { return nil }
        if variant == .esli { return round % 2 == bidder % 2 ? bid : nil }
        return round == bidder ? bid : nil
    }
    private func tricks(at index: Int) -> Int { tricks.indices.contains(index) ? tricks[index] : 0 }
    /// Tricks that count towards `target`: the partnership's in Eşli, the seat's own elsewhere.
    public func taken(by round: Int) -> Int {
        variant == .esli ? tricks(at: round % 2) + tricks(at: round % 2 + 2) : tricks(at: round)
    }
    public func summary(players: Int) -> [BatakSummaryRow] {
        (0..<max(0, players)).map { round in
            let contract = target(of: round), taken = taken(by: round)
            var mark: BatakSummaryMark?
            if let contract { mark = taken >= contract ? .made : .set }
            else if rules.defenderBatakPenalty && variant != .kozMaca && taken == 0 { mark = .batak }
            return BatakSummaryRow(round: round, contract: contract, tricks: tricks(at: round), taken: taken,
                                   points: scores.indices.contains(round) ? scores[round] : 0, mark: mark)
        }
    }
}

public enum BatakSummaryMark: Sendable, Equatable {
    case made, set, batak
    public var title: String {
        switch self {
        case .made: "Çıktı"
        case .set: "Battı"
        case .batak: "Batak"
        }
    }
}
public struct BatakSummaryRow: Equatable, Sendable {
    public let round: Int
    public let contract: Int?
    public let tricks: Int
    public let taken: Int
    public let points: Int
    public let mark: BatakSummaryMark?
}

/// Running score sheet: one row per finished round in the table history (oldest first) and the totals.
public struct BatakScoreSheet: Equatable, Sendable {
    public let rows: [[Int]]
    public let totals: [Int]
    public init(history: [GameHistoryEntry], players: Int) {
        let rows = history.map { entry in
            entry.result["scores"].array.map { value -> Int in if case .number(let n) = value { return Int(n) }; return 0 }
        }.filter { $0.count == players && players > 0 }
        self.rows = rows
        totals = (0..<max(0, players)).map { seat in rows.reduce(0) { $0 + $1[seat] } }
    }
}

// MARK: - Layout

/// Where a round index sits on the viewer's table.
public enum BatakSpot: String, CaseIterable, Sendable {
    case bottom, right, top, left, topRight, topLeft
}
public enum BatakLayout {
    /// Own seat at the bottom, then the turn order counter-clockwise like a Turkish table: the next player on the
    /// RIGHT. Three-handed Gömmeli puts the other two in the top corners. A spectator sees round 0 at the bottom.
    public static func spot(of round: Int, viewer: Int?, players: Int) -> BatakSpot {
        guard players > 0 else { return .bottom }
        let offset = ((round - (viewer ?? 0)) % players + players) % players
        if players == 3 { return [BatakSpot.bottom, .topRight, .topLeft][offset] }
        return [BatakSpot.bottom, .right, .top, .left][offset % 4]
    }
    /// The round index at a spot, if any.
    public static func round(at spot: BatakSpot, viewer: Int?, players: Int) -> Int? {
        (0..<max(0, players)).first { self.spot(of: $0, viewer: viewer, players: players) == spot }
    }

    private static let cycle: [CardSuit] = [.spades, .hearts, .clubs, .diamonds]
    /// The own hand as a player holds it: suits alternate black and red (♠ ♥ ♣ ♦), aces first inside a suit,
    /// trump rightmost. Port of the desktop `sortHand`.
    public static func sortHand(_ hand: [PlayingCard], trump: CardSuit?) -> [PlayingCard] {
        let start = trump.flatMap { suit in cycle.firstIndex(of: suit).map { index in index + 1 } } ?? 0
        let rotated = cycle.indices.map { cycle[(start + $0) % 4] }
        let held = rotated.filter { suit in hand.contains { $0.suit == suit } }
        let last: [CardSuit] = trump.map { suit in held.contains(suit) ? [suit] : [] } ?? []
        let free = held.filter { $0 != trump }
        func orders(_ list: [CardSuit]) -> [[CardSuit]] {
            list.count <= 1 ? [list] : list.indices.flatMap { index in
                orders(list.enumerated().filter { $0.offset != index }.map(\.element)).map { [list[index]] + $0 }
            }
        }
        func clashes(_ list: [CardSuit]) -> Int { zip(list, list.dropFirst()).filter { $0.red == $1.red }.count }
        let candidates = orders(free).map { $0 + last }
        let present = candidates.dropFirst().reduce(candidates[0]) { clashes($1) < clashes($0) ? $1 : $0 }
        func order(_ suit: CardSuit) -> Int { present.firstIndex(of: suit) ?? 9 }
        return hand.sorted { order($0.suit) != order($1.suit) ? order($0.suit) < order($1.suit) : $0.rank > $1.rank }
    }
}

// MARK: - Trick hold and sweep

/// A completed trick stays on the felt for `holdSeconds`, then sweeps to its winner for `sweepSeconds`
/// (desktop `TRICK_HOLD_MS` 1200 / `TRICK_SWEEP_MS` 350). The next lead cuts the hold short. The server clears
/// `trick` the moment it completes, so the client keeps the last completed trick itself.
public struct BatakTrickTracker: Equatable, Sendable {
    public static let holdSeconds: TimeInterval = 1.2
    public static let sweepSeconds: TimeInterval = 0.35
    public enum Phase: Equatable, Sendable { case holding, sweeping }
    public struct Held: Equatable, Sendable {
        /// Completed-trick count plus the deal: one key per trick.
        public let key: String
        public let plays: [BatakPlay]
        public let winner: Int
        public let completedAt: Date
        public var sweepAt: Date
    }
    public private(set) var held: Held?
    private var baseline = false
    private var done = 0
    private var bids = 0
    public init() {}

    /// Feeds a new view. Returns true when a trick just completed (for sound/haptics). The first view is the
    /// baseline: nothing replays when the table opens or reconnects; a fresh deal clears the hold.
    @discardableResult
    public mutating func observe(_ round: BatakRound, deal: Int, now: Date) -> Bool {
        let count = round.completedTricks.count
        defer { done = count; bids = round.bidLog.count; baseline = true }
        guard baseline else { return false }
        if count < done || round.bidLog.count < bids { held = nil; return false }
        if count > done, let last = round.completedTricks.last {
            held = Held(key: "\(deal):\(count)", plays: last.plays, winner: last.winner, completedAt: now,
                        sweepAt: round.trick.isEmpty ? now.addingTimeInterval(Self.holdSeconds) : now)
            return true
        }
        // The winner already led the next trick: sweep now instead of hiding the new card.
        if var current = held, !round.trick.isEmpty, current.sweepAt > now { current.sweepAt = now; held = current }
        return false
    }
    public func phase(at now: Date) -> Phase? {
        guard let held else { return nil }
        if now < held.sweepAt { return .holding }
        if now < held.sweepAt.addingTimeInterval(Self.sweepSeconds) { return .sweeping }
        return nil
    }
    /// When the phase next changes (the view schedules one redraw there).
    public func nextChange(after now: Date) -> Date? {
        guard let held else { return nil }
        let end = held.sweepAt.addingTimeInterval(Self.sweepSeconds)
        if now < held.sweepAt { return held.sweepAt }
        return now < end ? end : nil
    }
    /// The view already shows a trick completed that `observe` has not seen yet (the render before `onChange`):
    /// draw `completedTricks.last` in place so the last card never blinks.
    public func completionPending(_ round: BatakRound) -> Bool { baseline && round.completedTricks.count > done }
    /// Drops a trick whose sweep is over.
    public mutating func expire(at now: Date) { if phase(at: now) == nil { held = nil } }
}

public extension GameState {
    /// The Batak round for this viewer; nil before the first deal reached this client or without access.
    var batakRound: BatakRound? { kind == .batak ? view(as: BatakRound.self) : nil }
}

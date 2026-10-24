import Foundation

// Pişti (`rooms-pisti-v1`) view model for the iPhone table. Source of truth: `packages/games/src/pisti.ts` and the
// match wrapper `match.ts` in the desktop repository; the desktop reading lives in `apps/desktop/src/games/pisti/model.ts`.
//
// Index semantics (easy to get wrong):
// - Every per-player array in the view (`handCounts`, `result.points`, `series.totals`, `series.rounds[].points`,
//   `viewerSeat`, `turn`, `lastPlay.seat`, `lastCapture.seat`) is indexed by ROUND index: the position in the seats
//   sorted by seat number (`GameState.orderedSeats`), NOT by `GameSeat.seat`.
// - `capturedCounts`, `pisti` and `jackPisti` are per SIDE: the round index itself in a 2-player game, `round % 2`
//   for the partners seated across in a 4-player team game.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

// MARK: - Wire types

public enum PistiCaptureKind: String, Sendable {
    case capture, pisti, jackPisti = "jack-pisti", remainder
}

/// The last card played (`view.lastPlay`).
public struct PistiPlayRecord: Decodable, Equatable, Sendable {
    public let seq: Int
    /// Round index of the player.
    public let seat: Int
    public let card: PlayingCard
    /// Whether the card took the pile.
    public let captured: Bool
}

/// The last capture (`view.lastCapture`).
public struct PistiCaptureRecord: Decodable, Equatable, Sendable {
    public let seq: Int
    public let seat: Int
    /// Cards taken, including the capturing card.
    public let count: Int
    public let kind: PistiCaptureKind
    /// The capturing card; nil for the end-of-deal remainder.
    public let card: PlayingCard?
    enum CodingKeys: String, CodingKey { case seq, seat, count, kind, card }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        seat = c.soft(Int.self, .seat) ?? 0
        count = c.soft(Int.self, .count) ?? 0
        kind = c.soft(String.self, .kind).flatMap(PistiCaptureKind.init(rawValue:)) ?? .capture
        card = c.soft(PlayingCard.self, .card)
    }
}

public struct PistiResult: Decodable, Equatable, Sendable {
    /// Points per round index; in a team game both partners carry the team's points.
    public let points: [Int]
    public let winners: [Int]
}

/// One deal of a Pişti match as the viewer may see it: `view` itself, or `view.series.previous`.
public struct PistiView: Decodable, Equatable, Sendable {
    public let seats: Int
    public let teams: Bool
    public let target: Int
    /// The viewer's round index; nil when watching.
    public let viewerSeat: Int?
    /// Round index whose turn it is; nil once the deal is over.
    public let turn: Int?
    /// The viewer's own cards; nil for spectators.
    public let hand: [PlayingCard]?
    public let handCounts: [Int]
    /// Cards on the table; only the top one is visible.
    public let tableCount: Int
    public let tableTop: PlayingCard?
    public let deckCount: Int
    /// Per side.
    public let capturedCounts: [Int]
    public let pisti: [Int]
    public let jackPisti: [Int]
    public let lastPlay: PistiPlayRecord?
    public let lastCapture: PistiCaptureRecord?
    /// Set once the deal is over.
    public let result: PistiResult?

    enum CodingKeys: String, CodingKey {
        case seats, teams, target, viewerSeat, turn, hand, handCounts, tableCount, tableTop, deckCount
        case capturedCounts, pisti, jackPisti, lastPlay, lastCapture, result
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seats = try c.decode(Int.self, forKey: .seats)
        teams = c.soft(Bool.self, .teams) ?? (seats == 4)
        target = c.soft(Int.self, .target) ?? 151
        viewerSeat = c.soft(Int.self, .viewerSeat)
        turn = c.soft(Int.self, .turn)
        hand = c.soft([PlayingCard].self, .hand)
        handCounts = c.soft([Int].self, .handCounts) ?? []
        tableCount = c.soft(Int.self, .tableCount) ?? 0
        tableTop = c.soft(PlayingCard.self, .tableTop)
        deckCount = c.soft(Int.self, .deckCount) ?? 0
        capturedCounts = c.soft([Int].self, .capturedCounts) ?? []
        pisti = c.soft([Int].self, .pisti) ?? []
        jackPisti = c.soft([Int].self, .jackPisti) ?? []
        lastPlay = c.soft(PistiPlayRecord.self, .lastPlay)
        lastCapture = c.soft(PistiCaptureRecord.self, .lastCapture)
        result = c.soft(PistiResult.self, .result)
    }
}

extension GameState {
    /// The Pişti view of a Pişti table; nil for other games or a view this build cannot read.
    public var pistiView: PistiView? { kind == .pisti ? view(as: PistiView.self) : nil }
}
extension GameSeries {
    /// The last finished deal (the next one is already dealt when the match goes on).
    public var pistiPrevious: PistiView? {
        guard let previous, case .object = previous, let data = try? JSONEncoder().encode(previous) else { return nil }
        return try? JSONDecoder().decode(PistiView.self, from: data)
    }
}

// MARK: - Sides and seating around the table

/// Where a player sits for this viewer, turn order running counter-clockwise like a Turkish table:
/// own seat at the bottom, the next player on the right, the partner across at the top (desktop `relativePosition`).
public enum PistiPosition: String, Sendable { case bottom, right, top, left }

extension PistiView {
    /// Number of sides: players alone in 2p, two teams of partners in 4p.
    public var sideCount: Int { seats == 4 ? 2 : max(1, seats) }
    public func side(ofRound round: Int) -> Int { teams ? round % 2 : round }
    /// Round indices on one side: one player, or the two partners seated across.
    public func members(ofSide side: Int) -> [Int] { (0..<max(0, seats)).filter { self.side(ofRound: $0) == side } }
    /// The viewer's side; nil when watching.
    public var viewerSide: Int? { viewerSeat.map(side(ofRound:)) }
    /// The viewer's side, or side 0 for spectators (drawn at the bottom).
    public var homeSide: Int { viewerSide ?? 0 }
    public func position(ofRound round: Int) -> PistiPosition {
        guard seats > 0 else { return .bottom }
        let offset = ((round - (viewerSeat ?? 0)) % seats + seats) % seats
        if seats == 2 { return offset == 0 ? .bottom : .top }
        return [PistiPosition.bottom, .right, .top, .left][min(offset, 3)]
    }
    /// Round indices from the one at the top of the table around to the others, for drawing: bottom, right, top, left.
    public func round(at position: PistiPosition) -> Int? { (0..<max(0, seats)).first { self.position(ofRound: $0) == position } }
    public func isPartner(round: Int) -> Bool { teams && viewerSeat != nil && round != viewerSeat && side(ofRound: round) == viewerSide }
    /// Points of one side from a per-round array (both partners carry the same team points).
    public func sidePoints(_ points: [Int], side: Int) -> Int {
        let index = members(ofSide: side).first ?? side
        return points.indices.contains(index) ? points[index] : 0
    }
    public func captured(side: Int) -> Int { capturedCounts.indices.contains(side) ? capturedCounts[side] : 0 }
    public func pistiCount(side: Int) -> Int { (pisti.indices.contains(side) ? pisti[side] : 0) + (jackPisti.indices.contains(side) ? jackPisti[side] : 0) }
    public func handCount(round: Int) -> Int { handCounts.indices.contains(round) ? handCounts[round] : 0 }
    /// It is the viewer's turn and the deal is still on.
    public var viewerToPlay: Bool { viewerSeat != nil && turn == viewerSeat && result == nil }
    /// Whether `card` would take the pile (a jack takes anything; otherwise the top card's rank must match).
    public func takesPile(_ card: PlayingCard) -> Bool {
        guard let top = tableTop else { return false }
        return card.rank == 11 || card.rank == top.rank
    }
}

// MARK: - Hand

/// One card of the viewer's hand, as the table draws it.
public struct PistiHandCard: Equatable, Identifiable, Sendable {
    public let card: PlayingCard
    /// Tapping plays it. Every card of the hand is playable on the viewer's turn; nothing else is.
    public let playable: Bool
    /// It would take the pile: a hint on the viewer's turn.
    public let takes: Bool
    public var id: String { card.id }
}

extension PistiView {
    /// The viewer's hand with what is playable. `canPlay` is the server's say (`legalActions` has `play`, no command in flight).
    public func handCards(canPlay: Bool) -> [PistiHandCard] {
        let active = canPlay && viewerToPlay
        return (hand ?? []).map { PistiHandCard(card: $0, playable: active, takes: active && takesPile($0)) }
    }
}

// MARK: - Deal summary and match

public enum PistiPoints {
    public static let pisti = 10, jackPisti = 20, mostCards = 3
}

public struct PistiSideSummary: Equatable, Sendable {
    public let side: Int
    public let cards: Int
    /// +3 for strictly the most cards.
    public let mostCards: Bool
    public let pisti: Int
    public let jackPisti: Int
    /// Aces, jacks, ♣2 and ♦10 together: the deal total minus the bonuses (the view carries no split).
    public let cardPoints: Int
    public let total: Int
}

extension PistiView {
    /// How a settled deal scored per side. `points` is `result.points` or the deal's entry of `series.rounds`.
    public func summary(points: [Int]) -> [PistiSideSummary] {
        let most = capturedCounts.max() ?? 0
        let leaders = capturedCounts.filter { $0 == most }.count
        return (0..<sideCount).map { side in
            let total = sidePoints(points, side: side)
            let mostCards = leaders == 1 && captured(side: side) == most && most > 0
            let single = pisti.indices.contains(side) ? pisti[side] : 0
            let jack = jackPisti.indices.contains(side) ? jackPisti[side] : 0
            let bonus = (mostCards ? PistiPoints.mostCards : 0) + single * PistiPoints.pisti + jack * PistiPoints.jackPisti
            return PistiSideSummary(side: side, cards: captured(side: side), mostCards: mostCards, pisti: single, jackPisti: jack,
                                    cardPoints: max(0, total - bonus), total: total)
        }
    }
}

/// One side's place in the match.
public struct PistiStanding: Equatable, Identifiable, Sendable {
    public let side: Int
    public let total: Int
    public let target: Int
    public let own: Bool
    public let winner: Bool
    public var id: Int { side }
    /// 0...1 progress to the target.
    public var progress: Double { target > 0 ? min(1, Double(max(0, total)) / Double(target)) : 0 }
}

extension PistiView {
    /// Match totals per side (`series.totals` is per round index; partners carry the same number).
    public func standings(series: GameSeries?) -> [PistiStanding] {
        let winnerSides = Set((series?.winners ?? []).map(side(ofRound:)))
        return (0..<sideCount).map { side in
            PistiStanding(side: side, total: sidePoints(series?.totals ?? [], side: side), target: target,
                          own: side == viewerSide, winner: winnerSides.contains(side))
        }
    }
}

// MARK: - Names and the line under the pile

private func pistiRankName(_ rank: Int) -> String {
    switch rank {
    case 11: "Vale"
    case 12: "Kız"
    case 13: "Papaz"
    case 14: "As"
    default: String(rank)
    }
}
extension PlayingCard {
    /// "Maça Vale", "Kupa 7".
    public var pistiName: String { "\(suit.title) \(pistiRankName(rank))" }
}

extension GameState {
    /// The seat of a round index (position in the seats sorted by seat number).
    public func pistiSeat(round: Int) -> GameSeat? {
        let ordered = orderedSeats
        return ordered.indices.contains(round) ? ordered[round] : nil
    }
    /// A player's name for the table text; the viewer is "Sen".
    public func pistiName(round: Int, me: String?) -> String {
        guard let seat = pistiSeat(round: round) else { return "Oyuncu" }
        return seat.userId == me ? "Sen" : seat.name
    }
    /// "Sen + Ece" for partners, a single name otherwise.
    public func pistiSideName(_ view: PistiView, side: Int, me: String?) -> String {
        let names = view.members(ofSide: side).map { pistiName(round: $0, me: me) }
        return names.isEmpty ? "Oyuncu" : names.joined(separator: " + ")
    }
}

public enum PistiNarration {
    /// "Ece Maça 7 attı" (the viewer: "Sen … attın").
    public static func playLine(_ play: PistiPlayRecord, name: String, you: Bool) -> String {
        "\(name) \(play.card.pistiName) \(you ? "attın" : "attı")"
    }
    public static func captureLine(_ capture: PistiCaptureRecord, name: String, you: Bool) -> String {
        switch capture.kind {
        case .pisti: return "\(name) pişti yaptı · +10"
        case .jackPisti: return "\(name) vale pişti yaptı · +20"
        case .remainder: return "Yerde kalan \(capture.count) kart son alan \(name) tarafına gitti"
        case .capture:
            let verb = you ? "aldın" : "aldı"
            return capture.card?.rank == 11 ? "\(name) valeyle \(capture.count) kart \(verb)" : "\(name) \(capture.count) kart \(verb)"
        }
    }
    /// What the line under the pile says: the capture, then the play (the capture belongs to the same play when `seq` matches).
    public static func lastLine(_ view: PistiView, game: GameState, me: String?) -> String {
        var parts: [String] = []
        if let capture = view.lastCapture {
            parts.append(captureLine(capture, name: game.pistiName(round: capture.seat, me: me), you: game.pistiSeat(round: capture.seat)?.userId == me))
        }
        if let play = view.lastPlay {
            parts.append(playLine(play, name: game.pistiName(round: play.seat, me: me), you: game.pistiSeat(round: play.seat)?.userId == me))
        }
        if parts.isEmpty, let turn = view.turn { return "\(game.pistiName(round: turn, me: me)) açıyor" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Table events

/// A play the viewer has not seen yet, derived from consecutive views (the server sends no event bodies).
public struct PistiTableEvent: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case play, capture, pisti, jackPisti, remainder }
    public let id: String
    public let kind: Kind
    /// Round index of the player.
    public let round: Int
    public let card: PlayingCard?
    /// Cards swept off the table, 0 for a plain play.
    public let count: Int
    /// The deal ended with this play; the finished deal is `series.previous`.
    public let dealEnded: Bool
    public var isPisti: Bool { kind == .pisti || kind == .jackPisti }
    /// Bonus shown in the PİŞTİ! overlay.
    public var bonus: Int { kind == .jackPisti ? PistiPoints.jackPisti : kind == .pisti ? PistiPoints.pisti : 0 }
}

/// Turns views into events. The first view is the baseline: nothing replays when the table opens or reconnects.
/// The next deal is dealt inside the action that ended the previous one, so a finished deal's last play
/// sits in `series.previous` while `series.rounds` has grown.
public struct PistiEventTracker: Equatable, Sendable {
    private var seenKey: String?
    private var seenRounds = 0
    public init() {}

    public mutating func observe(_ view: PistiView, series: GameSeries?) -> PistiTableEvent? {
        let rounds = series?.rounds.count ?? 0
        let key = "\(rounds):\(view.lastPlay?.seq ?? 0)"
        defer { seenKey = key; seenRounds = rounds }
        guard let seen = seenKey, seen != key else { return nil }
        let dealEnded = rounds > seenRounds
        let source = dealEnded && series?.winners == nil ? (series?.pistiPrevious ?? view) : view
        guard let play = source.lastPlay else { return nil }
        let capture = source.lastCapture.flatMap { $0.seq == play.seq ? $0 : nil }
        let kind: PistiTableEvent.Kind
        switch capture?.kind {
        case .pisti?: kind = .pisti
        case .jackPisti?: kind = .jackPisti
        case .remainder?: kind = .remainder
        case .capture?: kind = .capture
        case nil: kind = .play
        }
        return PistiTableEvent(id: "\(key):\(play.seat)", kind: kind, round: capture?.seat ?? play.seat, card: capture == nil ? play.card : capture?.card,
                               count: capture?.count ?? 0, dealEnded: dealEnded)
    }
}

import Foundation

// Hold'em table logic for the iPhone table view: the parts of `holdemView` that `HoldemHandView` does not model
// (public action log, mucked hands, runout), raise presets, the action bar, pot labels, seat layout and buy-ins.
// Mirrors the desktop `games/holdem/model.ts` so both clients show the same table.

// MARK: - View extras

/// One public betting action from `view.log` (server `HoldemLogEntry`). Blinds are logged as actions.
public struct HoldemLogEntry: Decodable, Equatable, Sendable {
    /// `preflop`, `flop`, `turn` or `river`.
    public let street: String
    public let userId: String
    /// `smallBlind`, `bigBlind`, `fold`, `check`, `call` or `raise`.
    public let action: String
    /// Chips actually moved (a short stack pays less than asked).
    public let amount: Int
    /// The player's street total after the action.
    public let to: Int
    public let allIn: Bool
    public init(street: String, userId: String, action: String, amount: Int, to: Int, allIn: Bool) {
        self.street = street; self.userId = userId; self.action = action; self.amount = amount; self.to = to; self.allIn = allIn
    }
    enum CodingKeys: String, CodingKey { case street, userId, action, amount, to, allIn }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        action = try c.decode(String.self, forKey: .action)
        street = (try? c.decodeIfPresent(String.self, forKey: .street)) ?? "preflop"
        amount = Self.int(c, .amount)
        to = Self.int(c, .to)
        allIn = ((try? c.decodeIfPresent(Bool.self, forKey: .allIn)) ?? nil) ?? false
    }
    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let value = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil, value.isFinite { return Int(value) }
        return 0
    }

    /// The bubble over the seat (desktop `actionLabel`): "Gör 40", "Artır 120", "All-in 300", "Kontrol", "Bırak".
    public var label: String {
        if allIn && action != "fold" && action != "check" { return "All-in \(to.formatted())" }
        switch action {
        case "smallBlind": return "Küçük kör \(amount.formatted())"
        case "bigBlind": return "Büyük kör \(amount.formatted())"
        case "fold": return "Bırak"
        case "check": return "Kontrol"
        case "call": return "Gör \(amount.formatted())"
        case "raise": return "Artır \(to.formatted())"
        default: return action
        }
    }
    /// Hand log line: "Ece · Gör 40".
    public func line(name: String) -> String { "\(name) · \(label)" }
}

/// `view.log`, `view.mucked` and `view.runoutFrom`; read with `GameState.view(as: HoldemViewExtras.self)`.
/// Every field is optional on the wire (older services send none of them).
public struct HoldemViewExtras: Decodable, Equatable, Sendable {
    public let log: [HoldemLogEntry]
    /// Showdown players who kept their cards hidden (table rule `muckLosers`).
    public let mucked: [String]
    /// The street whose betting was the last before the board was dealt out with nobody left to act.
    public let runoutFrom: String?
    public static let empty = HoldemViewExtras(log: [], mucked: [], runoutFrom: nil)
    public init(log: [HoldemLogEntry], mucked: [String], runoutFrom: String?) { self.log = log; self.mucked = mucked; self.runoutFrom = runoutFrom }
    enum CodingKeys: String, CodingKey { case log, mucked, runoutFrom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed entry drops only itself.
        if var list = try? c.nestedUnkeyedContainer(forKey: .log) {
            var entries: [HoldemLogEntry] = []
            while !list.isAtEnd {
                if let entry = try? list.decode(HoldemLogEntry.self) { entries.append(entry) }
                else { _ = try? list.decode(HoldemSkip.self) }
            }
            log = entries
        } else { log = [] }
        mucked = ((try? c.decodeIfPresent([String].self, forKey: .mucked)) ?? nil) ?? []
        runoutFrom = (try? c.decodeIfPresent(String.self, forKey: .runoutFrom)) ?? nil
    }

    /// Each player's latest action on the street being played (on the last logged street once the hand ended),
    /// for the bubble over the seat. A new street starts with no bubbles.
    public func lastActions(stage: String) -> [String: HoldemLogEntry] {
        let street = stage == "ended" ? log.last?.street : stage
        var latest: [String: HoldemLogEntry] = [:]
        for entry in log where entry.street == street { latest[entry.userId] = entry }
        return latest
    }
    /// Small and big blind of this hand, from the logged blinds (heads-up the button posts the small blind).
    public var blinds: (small: String?, big: String?) {
        (log.first { $0.action == "smallBlind" }?.userId, log.first { $0.action == "bigBlind" }?.userId)
    }
}
/// Consumes one undecodable array element.
private struct HoldemSkip: Decodable { init(from decoder: Decoder) throws {} }

// MARK: - Raise

/// One raise shortcut as a street total (`GameAction.raise(to:)`).
public struct HoldemRaisePreset: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case min, halfPot, pot, allIn }
    public let kind: Kind
    public let amount: Int
    public var id: Kind { kind }
    public var title: String {
        switch kind {
        case .min: "Min"
        case .halfPot: "½ Pot"
        case .pot: "Pot"
        case .allIn: "All-in"
        }
    }
}

/// What the raise sheet works with: the server's legal totals plus the pot for the presets.
public struct HoldemRaise: Equatable, Sendable {
    /// Every chip in the pots, this street's bets included.
    public let pot: Int
    /// Highest street total so far.
    public let maximumBet: Int
    /// The viewer's street total.
    public let streetBet: Int
    /// Legal `raise(to:)` totals: a full raise up to all-in, or only all-in for a short stack.
    public let range: ClosedRange<Int>
    public init(pot: Int, maximumBet: Int, streetBet: Int, range: ClosedRange<Int>) {
        self.pot = pot; self.maximumBet = maximumBet; self.streetBet = streetBet; self.range = range
    }
    public var allIn: Int { range.upperBound }
    /// Only all-in is possible (the slider has nothing to choose).
    public var allInOnly: Bool { range.lowerBound == range.upperBound }
    public func clamp(_ amount: Int) -> Int { min(range.upperBound, max(range.lowerBound, amount)) }
    /// A pot-sized raise is a call plus the pot after that call; every preset is clamped to the legal range,
    /// so none can send an illegal total. Halves round up like the desktop's `Math.round`.
    public var presets: [HoldemRaisePreset] {
        let call = max(0, maximumBet - streetBet), afterCall = pot + call
        return [
            HoldemRaisePreset(kind: .min, amount: range.lowerBound),
            HoldemRaisePreset(kind: .halfPot, amount: clamp(maximumBet + (afterCall + 1) / 2)),
            HoldemRaisePreset(kind: .pot, amount: clamp(maximumBet + afterCall)),
            HoldemRaisePreset(kind: .allIn, amount: range.upperBound),
        ]
    }
    /// The confirm button: "120 fişe artır" or "All-in 980".
    public func confirmTitle(_ amount: Int) -> String {
        clamp(amount) >= range.upperBound ? "All-in \(range.upperBound.formatted())" : "\(clamp(amount).formatted()) fişe artır"
    }
}

public extension HoldemHandView {
    /// Pot total; before the service sends pots, the sum of contributions.
    var potOrContributions: Int { pots.isEmpty ? seats.reduce(0) { $0 + $1.contribution } : potTotal }
    /// What the viewer pays to call: a short stack calls all-in for less.
    func callAmount(_ userID: String?) -> Int { min(player(userID)?.chips ?? 0, toCall(userID)) }
    /// Raise sheet input for the viewer; nil when the stack cannot exceed the current bet.
    func raise(for userID: String?) -> HoldemRaise? {
        guard let own = player(userID), let range = raiseRange(userID) else { return nil }
        return HoldemRaise(pot: potOrContributions, maximumBet: maximumBet, streetBet: own.streetBet, range: range)
    }
    /// Seat index (into `seats`) → user id of the dealer button.
    var buttonUserID: String? { buttonPlayer?.userId }
    /// Card ids to highlight at showdown: the winning players' best five, only once the hand is settled.
    var winningCardIDs: Set<String> {
        guard ended, let showdown else { return [] }
        return Set(payouts.filter { $0.value > 0 }.keys.flatMap { showdown[$0]?.bestFiveCardIds ?? [] })
    }
    /// Players paid this hand, largest payout first.
    var paidPlayers: [(userId: String, amount: Int)] {
        payouts.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
    var splitPot: Bool { pots.contains { $0.split } }
}

// MARK: - Action bar

/// The viewer's buttons, straight from `legalActions`: the server offers `check` or `call`, never both.
public struct HoldemActionBar: Equatable, Sendable {
    public enum Middle: Equatable, Sendable {
        case check
        case call(Int)
        /// Neither offered: the button shows "Gör" disabled.
        case none
    }
    public let fold: Bool
    public let middle: Middle
    public let middleEnabled: Bool
    public let raise: Bool
    /// "Kontrol et", "Gör 40", "All-in 30" (a call that empties the stack); desktop wording.
    public let middleTitle: String

    public init(legalActions: [String], busy: Bool, callAmount: Int, stack: Int, canRaise: Bool) {
        let open = { (name: String) in !busy && legalActions.contains(name) }
        fold = open("fold")
        if legalActions.contains("check") {
            middle = .check; middleEnabled = open("check"); middleTitle = "Kontrol et"
        } else if legalActions.contains("call") {
            middle = .call(callAmount); middleEnabled = open("call")
            middleTitle = callAmount > 0 && callAmount >= stack ? "All-in \(callAmount.formatted())" : "Gör \(callAmount.formatted())"
        } else {
            middle = .none; middleEnabled = false; middleTitle = "Gör"
        }
        raise = open("raise") && canRaise
    }
    /// Any button is live: the bar is worth showing.
    public var anyEnabled: Bool { fold || middleEnabled || raise }
}

// MARK: - Pots

public extension PokerPot {
    /// "Ana pot · 300", "Yan pot 1 · 120 · Paylaşıldı · Ece +60, Can +60". `index` is the pot's place in `pots`
    /// (the main pot comes first, so the first side pot is 1, as on the desktop).
    func label(index: Int, name: (String) -> String) -> String {
        var parts = [kind == "side" ? "Yan pot \(index)" : "Ana pot", amount.formatted()]
        if split { parts.append("Paylaşıldı") }
        if !winners.isEmpty {
            parts.append(winners.map { id in awards[id].map { "\(name(id)) +\($0.formatted())" } ?? name(id) }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
    var isSide: Bool { kind == "side" }
}

// MARK: - Seats

/// Seat placement around the oval: the viewer's seat (seat 0 for spectators) at the bottom, then clockwise in seat order.
public enum HoldemSeatLayout {
    /// Unit-ellipse point for a seat (`x`,`y` in -1…1, y grows downwards; bottom centre is (0, 1)).
    public static func point(capacity: Int, seat: Int, ownSeat: Int?) -> (x: Double, y: Double) {
        let count = max(1, capacity)
        let step = (seat - (ownSeat ?? 0)) % count
        let angle = Double.pi / 2 + Double((step + count) % count) * 2 * Double.pi / Double(count)
        let round = { (v: Double) in (v * 1000).rounded() / 1000 }
        return (round(cos(angle)), round(sin(angle)))
    }
    /// Seat numbers in drawing order from the bottom, clockwise.
    public static func order(capacity: Int, ownSeat: Int?) -> [Int] {
        let count = max(1, capacity), anchor = ownSeat ?? 0
        return (0..<count).map { (anchor + $0) % count }
    }
}

/// The line under a seat, in the desktop's order of importance.
public enum HoldemSeatStatus {
    public static func text(seat: GameSeat, player: HoldemSeatView?, hand: HoldemHandView?, mucked: [String], me: String, turn: Int?) -> String {
        if seat.pendingNextHand == true { return "Sonraki el bekleniyor" }
        guard let hand, let player else { return seat.connected ? "Masada" : "Bağlantısı kesildi" }
        if player.folded { return "Eli bıraktı" }
        if hand.ended {
            if (hand.payouts[seat.userId] ?? 0) > 0 {
                let title = hand.splitPot ? "Ortak kazanan" : "Kazanan"
                return hand.showdown?[seat.userId].map { "\(title) · \($0.title)" } ?? title
            }
            if mucked.contains(seat.userId) { return "Kartını açmadı" }
            if let shown = hand.showdown?[seat.userId] { return shown.title }
            return "Masada"
        }
        if player.chips == 0 { return "All-in" }
        if turn == seat.seat { return seat.userId == me ? "Sıra sende" : "Sırada" }
        if !seat.connected { return "Bağlantısı kesildi" }
        return "Masada"
    }
}

// MARK: - Buy-in

/// Virtual chips brought to a seat (`GameCommand.sit(seat:buyIn:)`), checked like the service (`games.ts`).
public enum HoldemBuyIn {
    /// Taking a free seat: any amount in the table's buy-in range.
    public static func range(_ rules: HoldemTableRules?) -> ClosedRange<Int>? {
        guard let rules, rules.minBuyIn <= rules.maxBuyIn, rules.minBuyIn > 0 else { return nil }
        return rules.minBuyIn...rules.maxBuyIn
    }
    /// The amount the sheet starts at: the table's starting stack, clamped into the range.
    public static func initial(_ rules: HoldemTableRules?) -> Int? {
        guard let range = range(rules), let rules else { return nil }
        return min(range.upperBound, max(range.lowerBound, rules.initialChips))
    }
    /// Rebuy on the own seat: only between hands, and only once the stack fell below the minimum buy-in
    /// (otherwise the service answers `CHIP_CHANGE_NOT_ALLOWED` / `CHIP_CHANGE_DURING_HAND`).
    public static func canRebuy(chips: Int, rules: HoldemTableRules?, status: GameStatus) -> Bool {
        guard let rules, range(rules) != nil else { return false }
        return status != .playing && chips < rules.minBuyIn
    }
    /// The stack after a rebuy: the service caps it at the maximum buy-in.
    public static func stackAfterRebuy(chips: Int, amount: Int, rules: HoldemTableRules) -> Int { min(rules.maxBuyIn, chips + amount) }
}

/// Street names for the centre of the table.
public enum HoldemStreet {
    public static func title(_ stage: String) -> String {
        switch stage {
        case "preflop": "Preflop"
        case "flop": "Flop"
        case "turn": "Turn"
        case "river": "River"
        case "ended": "El tamamlandı"
        default: "Masa"
        }
    }
}

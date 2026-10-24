import Foundation

// Server-authoritative Kıraathane tables (Activities protocol v1, `room.game`).
// The service projects one `GamePublicState` per viewer: only the viewer's own hidden cards/tiles are present,
// other hands arrive as counts. Source of truth: `packages/activity-protocol/src/index.ts`,
// `packages/games/src/*` and `apps/services/activities/games.ts` in the desktop repository.
//
// Index semantics differ per field (see each view):
// - `GameState.turn` and `GameSeat.seat` are table seat numbers (0–8).
// - Hold'em and Blackjack hand views index their own `seats`/`players` arrays (late sitters are absent): match by user id.
// - Batak and 101 views use positions: the index into the table seats sorted by seat number (`GameState.orderedSeats`).

private extension KeyedDecodingContainer {
    /// A missing, null or malformed optional field never fails the surrounding game.
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
}

// MARK: - Kinds and states

public enum GameKind: Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case holdem, blackjack, batak, okey101
    /// Registry games (`packages/games/src/registry.ts`); their views are read with `GameState.view(as:)`.
    case pisti, okey, tavla
    /// A game this build does not know; shown as a table but not played.
    case unknown(String)
    /// Every game this build knows, in the desktop catalog order (`apps/desktop/src/games/catalog.ts`).
    public static let allCases: [GameKind] = [.holdem, .blackjack, .batak, .okey101, .pisti, .okey, .tavla]
    public init(rawValue: String) {
        switch rawValue {
        case "holdem": self = .holdem
        case "blackjack": self = .blackjack
        case "batak": self = .batak
        case "101": self = .okey101
        case "rooms-pisti-v1": self = .pisti
        case "rooms-okey-v1": self = .okey
        case "rooms-tavla-v1": self = .tavla
        default: self = .unknown(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .holdem: "holdem"
        case .blackjack: "blackjack"
        case .batak: "batak"
        case .okey101: "101"
        case .pisti: "rooms-pisti-v1"
        case .okey: "rooms-okey-v1"
        case .tavla: "rooms-tavla-v1"
        case .unknown(let value): value
        }
    }
    public var id: String { rawValue }
    public var known: Bool { if case .unknown = self { return false }; return true }
    /// Turkish table name, as the desktop shows it.
    public var title: String {
        switch self {
        case .holdem: "Texas Hold’em"
        case .blackjack: "Blackjack"
        case .batak: "Batak"
        case .okey101: "101 Okey"
        case .pisti: "Pişti"
        case .okey: "Okey"
        case .tavla: "Tavla"
        case .unknown: "Oyun masası"
        }
    }
    /// The catalog's player count line.
    public var playersLine: String {
        switch self {
        case .holdem: "2–9 oyuncu"
        case .blackjack: "1–7 oyuncu"
        case .batak: "3–4 oyuncu"
        case .okey101, .okey: "4 oyuncu"
        case .pisti: "2 veya 4 oyuncu"
        case .tavla: "2 oyuncu"
        case .unknown: ""
        }
    }
    /// One catalog sentence (desktop `detail`).
    public var detail: String {
        switch self {
        case .holdem: "Blind, flop ve showdown. Sanal fişle."
        case .blackjack: "Krupiyeye karşı 21. Herkes kendi elini oynar."
        case .batak: "İhaleli, eşli, koz maça ya da gömmeli."
        case .okey101: "Tekli ya da eşli. Botlar boş yerleri doldurur."
        case .pisti: "Yerdeki kartı aynı kartla ya da valeyle topla."
        case .okey: "Klasik Okey: 14 taşı per ya da çift olarak diz."
        case .tavla: "Zarı at, pullarını topla. Maç sayıya oynanır."
        case .unknown: "Bu oyun bu sürümde oynanamıyor. Uygulamayı güncelle."
        }
    }
    /// Seat counts the service accepts to start (module `seats`).
    public var seatCounts: [Int] {
        switch self {
        case .holdem: Array(2...9)
        case .blackjack: Array(1...7)
        case .batak: [3, 4]
        case .okey101, .okey: [4]
        case .pisti: [2, 4]
        case .tavla: [2]
        case .unknown: []
        }
    }
    /// Seats to draw when the server sends no capacity (desktop `fallbackCapacity`).
    public var fallbackCapacity: Int {
        switch self {
        case .holdem: 9
        case .blackjack: 7
        case .batak, .okey101, .okey, .pisti: 4
        case .tavla: 2
        case .unknown: 0
        }
    }
    /// Virtual chips (bets, buy-ins) rather than points.
    public var usesChips: Bool { self == .holdem || self == .blackjack }
    /// Tile racks and the board need the long edge of the phone.
    public var prefersLandscape: Bool { self == .okey101 || self == .okey || self == .tavla }
    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public enum GameStatus: Hashable, Sendable, Codable {
    case waiting, playing, finished, unknown(String)
    public init(rawValue: String) {
        switch rawValue {
        case "waiting": self = .waiting
        case "playing": self = .playing
        case "finished": self = .finished
        default: self = .unknown(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .waiting: "waiting"
        case .playing: "playing"
        case .finished: "finished"
        case .unknown(let value): value
        }
    }
    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// The `game.action` names of the protocol; `GameTableView.legalActions` reports a subset of these.
public enum GameActionKind: String, CaseIterable, Sendable {
    case start, fold, check, call, raise, bet, hit, stand, double, split
    case bid, pass, bury, trump, play, draw, discard, open
    case openPairs = "open-pairs"
    case process
    // Blackjack table rules (insurance/surrender switches) and 101's gösterge.
    case surrender, insurance
    case declineInsurance = "decline-insurance"
    case gosterge
    // Registry games: Okey (draw/discard above), Tavla; Pişti uses `play`.
    case finish
    case showIndicator = "show-indicator"
    case roll, move, undo, confirm
}

// MARK: - Cards and tiles

public enum CardSuit: String, Codable, CaseIterable, Sendable {
    case clubs, diamonds, hearts, spades
    public var symbol: String {
        switch self {
        case .clubs: "♣"
        case .diamonds: "♦"
        case .hearts: "♥"
        case .spades: "♠"
        }
    }
    public var title: String {
        switch self {
        case .clubs: "Sinek"
        case .diamonds: "Karo"
        case .hearts: "Kupa"
        case .spades: "Maça"
        }
    }
    public var red: Bool { self == .diamonds || self == .hearts }
}
/// A physical card; `rank` is 2–14 (11 J, 12 Q, 13 K, 14 A).
public struct PlayingCard: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let suit: CardSuit
    public let rank: Int
    public init(id: String, suit: CardSuit, rank: Int) { self.id = id; self.suit = suit; self.rank = rank }
    public var rankLabel: String {
        switch rank {
        case 11: "J"
        case 12: "Q"
        case 13: "K"
        case 14: "A"
        default: String(rank)
        }
    }
}

public enum OkeyColor: String, Codable, CaseIterable, Sendable {
    case red, yellow, blue, black
    public var title: String {
        switch self {
        case .red: "Kırmızı"
        case .yellow: "Sarı"
        case .blue: "Mavi"
        case .black: "Siyah"
        }
    }
}
/// A physical 101 tile. In a meld on the table a joker carries the color/value it stands for.
public struct OkeyTile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let color: OkeyColor
    public let value: Int
    public let joker: Bool?
    public init(id: String, color: OkeyColor, value: Int, joker: Bool? = nil) { self.id = id; self.color = color; self.value = value; self.joker = joker }
    /// The real okey (wildcard). False jokers (`false-joker-*`) are not wildcards; they stand for the okey's value.
    public var isJoker: Bool { joker == true }
    public var isFalseJoker: Bool { id.hasPrefix("false-joker") }
}

// MARK: - Table (common to every game)

public struct GameSeat: Codable, Equatable, Sendable, Identifiable {
    public let seat: Int
    public let userId: String
    public let name: String
    /// A permanent bot, or a human seat a bot is playing for now.
    public let bot: Bool
    public let chips: Int
    public let connected: Bool
    /// Hold'em: sat down during a hand and plays from the next one.
    public let pendingNextHand: Bool?
    public var id: Int { seat }
    public var isBotSeat: Bool { userId.hasPrefix("bot-") }
}
public struct GameSpectator: Codable, Equatable, Sendable, Identifiable {
    public let userId: String
    public let name: String
    public var id: String { userId }
}
public struct GameRecoveryEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let at: Double
    public let hand: Int
    /// `takeover-started`, `return-requested`, `control-returned` or `turn-timeout`.
    public let type: String
    public let action: String?
    public let toCall: Int?
}
/// The viewer's own seat recovery: a bot takes over 30 s after a disconnect; `game.sit` on the own seat asks for it back.
public struct GameRecovery: Codable, Equatable, Sendable {
    public let disconnectedAt: Double?
    public let takeoverAt: Double?
    public let pendingReturn: Bool
    public let takeover: Bool
    public let events: [GameRecoveryEvent]?
    /// A bot plays this seat and no return was requested yet: offer "Masaya geri dön" (`GameCommand.sit(seat: own seat)`).
    public var canRequestReturn: Bool { takeover && !pendingReturn }
}
public struct GameStatistics: Codable, Equatable, Sendable {
    public let hands: Int
    public let wins: Int
    public let score: Int
}
/// Hold'em table rules (`game.create`/`game.configure`).
public struct HoldemTableRules: Codable, Equatable, Sendable {
    public var name: String
    public var capacity: Int
    public var smallBlind: Int
    public var bigBlind: Int
    public var minBuyIn: Int
    public var maxBuyIn: Int
    public var initialChips: Int
    public var spectatorsAllowed: Bool
    public init(name: String, capacity: Int, smallBlind: Int, bigBlind: Int, minBuyIn: Int, maxBuyIn: Int, initialChips: Int, spectatorsAllowed: Bool) {
        self.name = name; self.capacity = capacity; self.smallBlind = smallBlind; self.bigBlind = bigBlind
        self.minBuyIn = minBuyIn; self.maxBuyIn = maxBuyIn; self.initialChips = initialChips; self.spectatorsAllowed = spectatorsAllowed
    }
    /// The service default (`defaultHoldemRules`).
    public static let standard = HoldemTableRules(name: "Hold’em", capacity: 9, smallBlind: 10, bigBlind: 20, minBuyIn: 1000, maxBuyIn: 1000, initialChips: 1000, spectatorsAllowed: true)
    /// The protocol's range and consistency checks; the service rejects anything else.
    public var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...32).contains(trimmed.count) && (2...9).contains(capacity)
            && (1...100_000).contains(smallBlind) && (1...100_000).contains(bigBlind)
            && [minBuyIn, maxBuyIn, initialChips].allSatisfy { (1...1_000_000).contains($0) }
            && smallBlind <= bigBlind && minBuyIn >= bigBlind && minBuyIn <= maxBuyIn
            && initialChips >= minBuyIn && initialChips <= maxBuyIn
    }
    var json: JSONValue {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .object([
            "name": .string(String((trimmed.isEmpty ? "Hold’em" : trimmed).prefix(32))), "capacity": .number(Double(capacity)),
            "smallBlind": .number(Double(smallBlind)), "bigBlind": .number(Double(bigBlind)),
            "minBuyIn": .number(Double(minBuyIn)), "maxBuyIn": .number(Double(maxBuyIn)),
            "initialChips": .number(Double(initialChips)), "spectatorsAllowed": .bool(spectatorsAllowed),
        ])
    }
}

/// A match played over several rounds (Pişti to a target, Tavla to `matchTo`): `view.series` from the service's `asMatch`.
/// Every array here is indexed by the round's own seat index (Pişti: seat position, or side in a 4-player team game;
/// Tavla: 0/1) — not by table seat numbers.
public struct GameSeries: Codable, Equatable, Sendable {
    public struct Round: Codable, Equatable, Sendable {
        public let points: [Int]
        public let winners: [Int]
    }
    /// Match points so far.
    public let totals: [Int]
    public let rounds: [Round]
    /// Set once the match is over.
    public let winners: [Int]?
    /// The last finished round in that game's own view shape (decode it with the game's view type).
    public let previous: JSONValue?
    public var finished: Bool { winners != nil }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totals = c.soft([Int].self, .totals) ?? []
        rounds = c.soft([Round].self, .rounds) ?? []
        winners = c.soft([Int].self, .winners)
        let previous = c.soft(JSONValue.self, .previous)
        self.previous = previous == .null ? nil : previous
    }
}

/// The keys every game view carries, also in the lobby, before the first hand and for viewers without access.
public struct GameTableView: Codable, Equatable, Sendable {
    public let ownRecovery: GameRecovery?
    public let tableName: String?
    /// Hold'em only.
    public let rules: HoldemTableRules?
    public let spectators: [GameSpectator]
    public let watching: Bool
    /// Seated, or watching a table that allows spectators. Without it the view has no hand and no history.
    public let spectatorAccess: Bool
    /// What the server lets the viewer do right now (`GameActionKind` raw values). Never includes Blackjack `bet`
    /// or the seat commands (`sit`, `leave`, `watch`, `bot.add`).
    public let legalActions: [String]
    /// Server time (ms) when the current turn times out and a rules bot plays it.
    public let turnDeadline: Double?
    public let capacity: Int?
    /// User id → hands, wins and total score at this table.
    public let statistics: [String: GameStatistics]
    /// Pişti/Tavla matches (`view.series`); nil for single-hand games.
    public let series: GameSeries?
    public static let empty = GameTableView(ownRecovery: nil, tableName: nil, rules: nil, spectators: [], watching: false, spectatorAccess: false,
                                            legalActions: [], turnDeadline: nil, capacity: nil, statistics: [:], series: nil)
    init(ownRecovery: GameRecovery?, tableName: String?, rules: HoldemTableRules?, spectators: [GameSpectator], watching: Bool, spectatorAccess: Bool,
         legalActions: [String], turnDeadline: Double?, capacity: Int?, statistics: [String: GameStatistics], series: GameSeries?) {
        self.ownRecovery = ownRecovery; self.tableName = tableName; self.rules = rules; self.spectators = spectators; self.watching = watching
        self.spectatorAccess = spectatorAccess; self.legalActions = legalActions; self.turnDeadline = turnDeadline; self.capacity = capacity; self.statistics = statistics
        self.series = series
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownRecovery = c.soft(GameRecovery.self, .ownRecovery)
        tableName = c.soft(String.self, .tableName)
        rules = c.soft(HoldemTableRules.self, .rules)
        spectators = c.soft([GameSpectator].self, .spectators) ?? []
        watching = c.soft(Bool.self, .watching) ?? false
        spectatorAccess = c.soft(Bool.self, .spectatorAccess) ?? false
        legalActions = c.soft([String].self, .legalActions) ?? []
        turnDeadline = c.soft(Double.self, .turnDeadline)
        capacity = c.soft(Int.self, .capacity)
        statistics = c.soft([String: GameStatistics].self, .statistics) ?? [:]
        series = c.soft(GameSeries.self, .series)
    }
}

public struct GameHistorySeat: Codable, Equatable, Sendable {
    public let seat: Int
    /// Position in the hand (Batak/101 index).
    public let position: Int
    public let userId: String
    public let name: String
    public let bot: Bool
    public let startingChips: Int?
}
/// A finished hand. `result` differs per game (payouts/board, dealer/results, scores/contract, scores/winner/melds).
public struct GameHistoryEntry: Codable, Equatable, Sendable {
    public let hand: Int
    public let endedAt: Double
    public let result: JSONValue
    public let tableName: String?
    public let seats: [GameHistorySeat]?
}

// MARK: - Hold'em

public struct PokerHandEvaluation: Codable, Equatable, Sendable {
    /// `high-card` … `straight-flush`.
    public let category: String
    public let score: [Int]
    public let bestFiveCardIds: [String]
    public var title: String {
        switch category {
        case "high-card": "Yüksek kart"
        case "one-pair": "Bir çift"
        case "two-pair": "İki çift"
        case "three-of-a-kind": "Üçlü"
        case "straight": "Kent"
        case "flush": "Renk"
        case "full-house": "Full house"
        case "four-of-a-kind": "Kare"
        case "straight-flush": "Sıralı renk"
        default: "El"
        }
    }
}
public struct PokerPot: Codable, Equatable, Sendable {
    /// `main` or `side`.
    public let kind: String
    public let amount: Int
    public let eligible: [String]
    public let winners: [String]
    public let awards: [String: Int]
    public let split: Bool
}
public struct HoldemSeatView: Codable, Equatable, Sendable, Identifiable {
    public let userId: String
    public let chips: Int
    /// The viewer's own two cards; everyone still in at showdown; otherwise empty.
    public let cards: [PlayingCard]
    public let hiddenCardCount: Int
    public let folded: Bool
    public let streetBet: Int
    public let contribution: Int
    public var id: String { userId }
    public var allIn: Bool { chips == 0 && !folded }
}
public struct HoldemHandView: Codable, Equatable, Sendable {
    public let revision: Int
    /// Index into `seats`.
    public let button: Int
    /// Index into `seats`, nil once the hand ends.
    public let turn: Int?
    /// `preflop`, `flop`, `turn`, `river` or `ended`.
    public let stage: String
    public let board: [PlayingCard]
    public let maximumBet: Int
    public let minimumRaise: Int
    public let payouts: [String: Int]
    public let winners: [String]
    public let seats: [HoldemSeatView]
    public let pots: [PokerPot]
    /// The viewer's best five of own cards and the board (from the flop on).
    public let ownHand: PokerHandEvaluation?
    /// User id → hand, only when the hand went to showdown.
    public let showdown: [String: PokerHandEvaluation]?
    /// `uncontested` or `showdown` once settled.
    public let settlementReason: String?

    public var ended: Bool { stage == "ended" }
    public func player(_ userID: String?) -> HoldemSeatView? { seats.first { $0.userId == userID } }
    public var turnPlayer: HoldemSeatView? { turn.flatMap { seats.indices.contains($0) ? seats[$0] : nil } }
    public var buttonPlayer: HoldemSeatView? { seats.indices.contains(button) ? seats[button] : nil }
    public var potTotal: Int { pots.reduce(0) { $0 + $1.amount } }
    /// Chips the player must add to call (0 means check).
    public func toCall(_ userID: String?) -> Int { player(userID).map { max(0, maximumBet - $0.streetBet) } ?? 0 }
    /// Allowed `raise(to:)` totals for this street: a full raise up to all-in, or only all-in when the stack is short.
    /// Nil when the stack cannot exceed the current bet. Whether raising is open at all comes from `legalActions`.
    public func raiseRange(_ userID: String?) -> ClosedRange<Int>? {
        guard !ended, let own = player(userID), !own.folded else { return nil }
        let allIn = own.streetBet + own.chips
        guard allIn > maximumBet else { return nil }
        return min(maximumBet + minimumRaise, allIn)...allIn
    }
}

// MARK: - Blackjack

public struct BlackjackHand: Codable, Equatable, Sendable {
    public let cards: [PlayingCard]
    public let bet: Int
    /// `playing`, `stood` or `bust`.
    public let state: String
    public let split: Bool
    public var total: Int { Blackjack.total(cards) }
}
public struct BlackjackPlayerView: Codable, Equatable, Sendable, Identifiable {
    public let userId: String
    /// Chips left after the bets on the table.
    public let credits: Int
    /// The bet chosen for this round.
    public let bet: Int
    public let hands: [BlackjackHand]
    public let activeHand: Int
    public var id: String { userId }
}
public struct BlackjackResult: Codable, Equatable, Sendable {
    public let userId: String
    public let hand: Int
    /// `win`, `lose`, `push` or `blackjack`.
    public let outcome: String
    public let returned: Int
}
public struct BlackjackHandView: Codable, Equatable, Sendable {
    public let revision: Int
    /// The up card while playing; every card once finished.
    public let dealer: [PlayingCard]
    public let dealerHiddenCount: Int
    public let players: [BlackjackPlayerView]
    /// Index into `players`.
    public let turn: Int?
    public let finished: Bool
    public let results: [BlackjackResult]
    public func player(_ userID: String?) -> BlackjackPlayerView? { players.first { $0.userId == userID } }
    public var turnPlayer: BlackjackPlayerView? { turn.flatMap { players.indices.contains($0) ? players[$0] : nil } }
    public var dealerTotal: Int { Blackjack.total(dealer) }
    public func results(_ userID: String?) -> [BlackjackResult] { results.filter { $0.userId == userID } }
}
public enum Blackjack {
    /// Best total, aces counting 11 until they would bust (`blackjackTotal`).
    public static func total(_ cards: [PlayingCard]) -> Int {
        var total = 0, aces = 0
        for card in cards {
            if card.rank == 14 { total += 11; aces += 1 } else { total += min(10, card.rank) }
        }
        while total > 21 && aces > 0 { total -= 10; aces -= 1 }
        return total
    }
    /// The service accepts a positive even bet up to the seat's chips, between hands only.
    public static func validBet(_ amount: Int, chips: Int) -> Bool { amount >= 2 && amount % 2 == 0 && amount <= chips }
}

// MARK: - Batak

public enum BatakVariant: String, Codable, CaseIterable, Sendable {
    case ihaleli, esli
    case kozMaca = "koz-maca"
    case gommeli
    public var title: String {
        switch self {
        case .ihaleli: "İhaleli"
        case .esli: "Eşli"
        case .kozMaca: "Koz Maça"
        case .gommeli: "Gömmeli"
        }
    }
    public var players: Int { self == .gommeli ? 3 : 4 }
    /// Lowest bid; in Koz Maça each player commits 1–13 once (pass = 1).
    public var minimumBid: Int {
        switch self {
        case .ihaleli: 5
        case .esli, .gommeli: 8
        case .kozMaca: 1
        }
    }
    public var maximumBid: Int { self == .gommeli ? 16 : 13 }
}
/// One play; `seat` is a position (see `GameState.orderedSeats`).
public struct BatakPlay: Codable, Equatable, Sendable {
    public let seat: Int
    public let card: PlayingCard
}
public struct BatakTrick: Codable, Equatable, Sendable {
    public let plays: [BatakPlay]
    /// Position of the player who took the trick.
    public let winner: Int
}
public struct BatakHandSlot: Codable, Equatable, Sendable {
    /// Position.
    public let seat: Int
    /// Only the viewer's own cards.
    public let cards: [PlayingCard]
    public let count: Int
}
/// All seat indexes here (`turn`, `bidder`, `bids`, `tricks`, `scores`, `hands`) are positions.
public struct BatakHandView: Codable, Equatable, Sendable {
    public let variant: BatakVariant
    /// `bidding`, `trump`, `bury`, `playing` or `ended`.
    public let stage: String
    public let turn: Int?
    /// Highest bid so far (0 before any); in Koz Maça see `bids`.
    public let bid: Int
    public let bids: [Int]
    public let bidder: Int
    /// The server reports `spades` before the trump is chosen; use `trumpKnown`.
    public let trump: CardSuit
    public let tricks: [Int]
    public let trick: [BatakPlay]
    public let scores: [Int]
    public let completedTricks: [BatakTrick]
    public let hands: [BatakHandSlot]
    public let buriedCount: Int
    public var trumpKnown: Bool { variant == .kozMaca || ["bury", "playing", "ended"].contains(stage) }
    public func cards(atPosition position: Int?) -> [PlayingCard] { hands.first { $0.seat == position }?.cards ?? [] }
    /// Eşli teams: positions 0+2 and 1+3.
    public func partner(of position: Int) -> Int? { variant == .esli ? (position + 2) % 4 : nil }
    /// Mirror of the service's `legalBatakCards` for greying out cards; the server still validates (`ILLEGAL_CARD`).
    public func legalCards(_ hand: [PlayingCard]) -> [PlayingCard] {
        guard stage == "playing", let lead = trick.first?.card.suit else { return hand }
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
}

// MARK: - 101 Okey

public struct OkeyRuleProfile: Codable, Equatable, Sendable {
    public let id: String
    public let folding: Bool
    public let teams: Bool
    public let openingMinimum: Int
    public let pairsMinimum: Int
}
public struct OkeyMeld: Codable, Equatable, Sendable {
    /// Position of the player who laid it.
    public let owner: Int
    public let tiles: [OkeyTile]
    public let pairs: Bool
}
public struct OkeyHandSlot: Codable, Equatable, Sendable {
    /// Position.
    public let seat: Int
    /// Only the viewer's own tiles.
    public let tiles: [OkeyTile]
    public let count: Int
}
/// All seat indexes here (`turn`, `opened`, `discards`, `scores`, `winner`, `hands`, meld `owner`) are positions.
public struct Okey101HandView: Codable, Equatable, Sendable {
    public let rules: OkeyRuleProfile
    public let indicator: OkeyTile
    public let remainingStock: Int
    public let turn: Int?
    /// `draw`, `discard` or `ended`.
    public let stage: String
    /// The opening total to beat in the folding (katlamalı) profile; 100 before anyone opened.
    public let highestOpening: Int
    /// Meld index is the `process(meld:)` target.
    public let melds: [OkeyMeld]
    /// Per position: `runs`, `pairs` or nil (not opened).
    public let opened: [String?]
    /// Per position: the top of that player's discard pile (zero or one tile).
    public let discards: [[OkeyTile]]
    public let scores: [Int]
    public let winner: Int?
    public let hands: [OkeyHandSlot]
    /// The value the real okey has (the indicator's next value, 13 → 1).
    public var jokerValue: Int { indicator.value % 13 + 1 }
    public func tiles(atPosition position: Int?) -> [OkeyTile] { hands.first { $0.seat == position }?.tiles ?? [] }
    /// The pile a player at `position` may take from: the previous player's discards.
    public func takeableDiscard(forPosition position: Int) -> OkeyTile? {
        let index = (position + 3) % 4
        return discards.indices.contains(index) ? discards[index].last : nil
    }
    public func openedMode(atPosition position: Int?) -> String? {
        guard let position, opened.indices.contains(position) else { return nil }
        return opened[position]
    }
}

// MARK: - Public state

/// The hand in progress or just finished, typed by game; nil in the lobby, before the first hand, without access,
/// or for a game kind this build does not know. Registry games (Pişti, Okey, Tavla) have no case here: their
/// per-game files read the view with `GameState.view(as:)`, so adding one never touches this file.
public enum GameHand: Equatable, Sendable {
    case holdem(HoldemHandView)
    case blackjack(BlackjackHandView)
    case batak(BatakHandView)
    case okey101(Okey101HandView)
    static func decode(_ kind: GameKind, from decoder: Decoder) -> GameHand? {
        switch kind {
        case .holdem: (try? HoldemHandView(from: decoder)).map(GameHand.holdem)
        case .blackjack: (try? BlackjackHandView(from: decoder)).map(GameHand.blackjack)
        case .batak: (try? BatakHandView(from: decoder)).map(GameHand.batak)
        case .okey101: (try? Okey101HandView(from: decoder)).map(GameHand.okey101)
        case .pisti, .okey, .tavla, .unknown: nil
        }
    }
}

/// `room.game`: one table per room, projected for the viewer.
public struct GameState: Codable, Equatable, Sendable {
    public let kind: GameKind
    public let ownerId: String
    public let status: GameStatus
    /// In join order, not sorted; see `orderedSeats`.
    public let seats: [GameSeat]
    /// The seat number whose turn it is.
    public let turn: Int?
    public let history: [GameHistoryEntry]
    public let table: GameTableView
    public let hand: GameHand?
    /// The view exactly as sent, for keys this build does not model.
    public let view: JSONValue

    enum CodingKeys: String, CodingKey { case kind, ownerId, status, seats, turn, view, history }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(GameKind.self, forKey: .kind)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        status = try c.decode(GameStatus.self, forKey: .status)
        seats = try c.decode([GameSeat].self, forKey: .seats)
        turn = c.soft(Int.self, .turn)
        history = c.soft([GameHistoryEntry].self, .history) ?? []
        view = c.soft(JSONValue.self, .view) ?? .object([:])
        if case .object = view, let viewDecoder = try? c.superDecoder(forKey: .view) {
            table = (try? GameTableView(from: viewDecoder)) ?? .empty
            hand = GameHand.decode(kind, from: viewDecoder)
        } else {
            table = .empty; hand = nil
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(ownerId, forKey: .ownerId); try c.encode(status, forKey: .status)
        try c.encode(seats, forKey: .seats); try c.encode(turn, forKey: .turn); try c.encode(view, forKey: .view); try c.encode(history, forKey: .history)
    }

    public var holdem: HoldemHandView? { if case .holdem(let value) = hand { return value }; return nil }
    public var blackjack: BlackjackHandView? { if case .blackjack(let value) = hand { return value }; return nil }
    public var batak: BatakHandView? { if case .batak(let value) = hand { return value }; return nil }
    public var okey101: Okey101HandView? { if case .okey101(let value) = hand { return value }; return nil }

    public func seat(of userID: String?) -> GameSeat? { seats.first { $0.userId == userID } }
    public var turnSeat: GameSeat? { turn.flatMap { number in seats.first { $0.seat == number } } }
    public func isMyTurn(_ userID: String?) -> Bool { userID != nil && turn != nil && seat(of: userID)?.seat == turn }
    public func isOwner(_ userID: String?) -> Bool { userID != nil && ownerId == userID }
    /// Seats sorted by number: Batak/101 positions index this list.
    public var orderedSeats: [GameSeat] { seats.sorted { $0.seat < $1.seat } }
    public func position(of userID: String?) -> Int? { orderedSeats.firstIndex { $0.userId == userID } }
    public func seat(atPosition position: Int?) -> GameSeat? {
        guard let position else { return nil }
        let ordered = orderedSeats
        return ordered.indices.contains(position) ? ordered[position] : nil
    }
    /// Seats the table has: the view's capacity, else the game's fallback (older servers).
    public var capacity: Int { min(GameCommand.maxSeats, max(0, table.capacity ?? kind.fallbackCapacity)) }
    /// Seat numbers nobody holds (Hold'em 2–9, Blackjack 7, Batak 3–4, 101/Okey 4, Pişti 2/4, Tavla 2).
    public var freeSeats: [Int] {
        guard table.capacity != nil else { return [] }
        let taken = Set(seats.map(\.seat))
        return (0..<capacity).filter { !taken.contains($0) }
    }
    /// The server's legal actions for the viewer, in its order; unknown names are dropped.
    public var legalActions: [GameActionKind] { table.legalActions.compactMap(GameActionKind.init(rawValue:)) }
    public func can(_ action: GameActionKind) -> Bool { table.legalActions.contains(action.rawValue) }
    /// Any action name, including registry-game names this build has no `GameActionKind` for.
    public func can(_ name: String) -> Bool { table.legalActions.contains(name) }
    /// "Yeni el" / "Rövanş": the server offers `start` between hands to whoever may deal.
    public var canDeal: Bool { status != .playing && can(.start) }
    /// The table owner or the room host may free a bot's seat or an away player's seat, never their own
    /// (desktop `SeatControlsContext`). The service makes the final call (`SEAT_REMOVE_NOT_ALLOWED`).
    public func canRemove(_ seat: GameSeat, viewer: String?, roomHost: Bool) -> Bool {
        guard let viewer, seat.userId != viewer, isOwner(viewer) || roomHost else { return false }
        return seat.bot || seat.isBotSeat || !seat.connected
    }
    /// Re-reads the view as a game's own type (registry games: Pişti, Okey, Tavla, and any later one).
    /// Nil when the view does not match; a broken view never fails the table.
    public func view<T: Decodable>(as type: T.Type) -> T? {
        guard case .object = view, let data = try? JSONEncoder().encode(view) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    /// Seconds until the turn timer runs out, using the same server offset as watch-together.
    public func turnSecondsLeft(nowMs: Double, serverOffsetMs: Double) -> Double? {
        guard status == .playing, turn != nil, let deadline = table.turnDeadline, deadline > 0 else { return nil }
        return max(0, (deadline - nowMs - serverOffsetMs) / 1000)
    }
    /// Batak/101: the viewer's own cards or tiles come from the hand slot at the viewer's position.
    public func myBatakCards(_ userID: String?) -> [PlayingCard] { batak?.cards(atPosition: position(of: userID)) ?? [] }
    public func myOkeyTiles(_ userID: String?) -> [OkeyTile] { okey101?.tiles(atPosition: position(of: userID)) ?? [] }
    /// 101: a discard taken this turn that still has to be used; `.draw` now returns it and draws from the stock.
    public var holdsPickedDiscard: Bool { okey101?.stage == "discard" && can(.draw) }
}

// MARK: - Commands

/// A flat `game.create.options` value (the protocol allows a string up to 64 characters, a finite number or a bool).
public enum GameOptionValue: Equatable, Sendable {
    case string(String), number(Double), bool(Bool)
    var json: JSONValue? {
        switch self {
        case .string(let value): .string(String(value.prefix(64)))
        case .number(let value): value.isFinite ? .number(value) : nil
        case .bool(let value): .bool(value)
        }
    }
}
/// `game.create.options`: at most 16 keys matching `^[a-zA-Z][a-zA-Z0-9]{0,31}$`; the game module checks the values.
public typealias GameOptions = [String: GameOptionValue]
enum GameOptionsEncoding {
    static let maxKeys = 16
    static func json(_ options: GameOptions) -> JSONValue? {
        let valid = options.keys.filter { $0.range(of: "^[a-zA-Z][a-zA-Z0-9]{0,31}$", options: .regularExpression) != nil }.sorted()
        var value: [String: JSONValue] = [:]
        for key in valid.prefix(maxKeys) { if let item = options[key]?.json { value[key] = item } }
        return value.isEmpty ? nil : .object(value)
    }
}

/// Blackjack table switches (`BLACKJACK_DEFAULT_RULES`: insurance on, surrender off).
public struct BlackjackTableOptions: Equatable, Sendable {
    public var insurance: Bool
    public var surrender: Bool
    public init(insurance: Bool = true, surrender: Bool = false) { self.insurance = insurance; self.surrender = surrender }
    public static let standard = BlackjackTableOptions()
    public var options: GameOptions { ["insurance": .bool(insurance), "surrender": .bool(surrender)] }
}
/// Batak house rules (`BatakRules`); the scoring switches do not apply to Koz Maça.
public struct BatakHouseRules: Equatable, Sendable {
    /// "Koz kırılmadan koz açılmaz".
    public var noTrumpLeadUntilBroken: Bool
    /// "Savunma batağı".
    public var defenderBatakPenalty: Bool
    /// "İhale kadar yaz".
    public var writeContract: Bool
    public init(noTrumpLeadUntilBroken: Bool = true, defenderBatakPenalty: Bool = false, writeContract: Bool = false) {
        self.noTrumpLeadUntilBroken = noTrumpLeadUntilBroken; self.defenderBatakPenalty = defenderBatakPenalty; self.writeContract = writeContract
    }
    public static let standard = BatakHouseRules()
    public var options: GameOptions {
        ["noTrumpLeadUntilBroken": .bool(noTrumpLeadUntilBroken), "defenderBatakPenalty": .bool(defenderBatakPenalty), "writeContract": .bool(writeContract)]
    }
}
/// Pişti match: `target` 101, 151 (default) or 251; an opening jack on top goes back into the deck by default.
public struct PistiTableOptions: Equatable, Sendable {
    public static let targets = [101, 151, 251]
    public var target: Int
    public var reshuffleJackTop: Bool
    public init(target: Int = 151, reshuffleJackTop: Bool = true) { self.target = target; self.reshuffleJackTop = reshuffleJackTop }
    public var options: GameOptions {
        ["target": .number(Double(Self.targets.contains(target) ? target : 151)), "reshuffleJackTop": .bool(reshuffleJackTop)]
    }
}
/// Classic Okey scoring: `countdown` (everyone starts at 20) or `winner` (+1 per win).
public enum OkeyScoring: String, CaseIterable, Sendable {
    case countdown, winner
    public var title: String { self == .countdown ? "Geri sayım" : "Kazanan +1" }
}
public struct OkeyTableOptions: Equatable, Sendable {
    public var scoring: OkeyScoring
    public init(scoring: OkeyScoring = .countdown) { self.scoring = scoring }
    public var options: GameOptions { ["scoring": .string(scoring.rawValue)] }
}
/// Tavla match to 3, 5 (default) or 7 points; `starterRerolls`: the higher opening die rerolls both dice.
public struct TavlaTableOptions: Equatable, Sendable {
    public static let targets = [3, 5, 7]
    public var matchTo: Int
    public var starterRerolls: Bool
    public init(matchTo: Int = 5, starterRerolls: Bool = false) { self.matchTo = matchTo; self.starterRerolls = starterRerolls }
    public var options: GameOptions {
        ["matchTo": .number(Double(Self.targets.contains(matchTo) ? matchTo : 5)), "starterRerolls": .bool(starterRerolls)]
    }
}

/// Which game a new table plays, with only the options that game accepts.
public enum GameSetup: Equatable, Sendable {
    /// Nil uses the service default rules; `muckLosers` hides losing showdown hands.
    case holdem(HoldemTableRules?, muckLosers: Bool = false)
    case blackjack(BlackjackTableOptions = .standard)
    case batak(BatakVariant, rules: BatakHouseRules = .standard)
    /// `folding` = katlamalı, `teams` = eşli.
    case okey101(folding: Bool, teams: Bool)
    case pisti(PistiTableOptions = PistiTableOptions())
    case okey(OkeyTableOptions = OkeyTableOptions())
    case tavla(TavlaTableOptions = TavlaTableOptions())
    /// Any registry game by its protocol id, with raw options (a game this build has no typed setup for).
    case custom(kind: GameKind, options: GameOptions)
    public var kind: GameKind {
        switch self {
        case .holdem: .holdem
        case .blackjack: .blackjack
        case .batak: .batak
        case .okey101: .okey101
        case .pisti: .pisti
        case .okey: .okey
        case .tavla: .tavla
        case .custom(let kind, _): kind
        }
    }
    /// `game.create.options` for this setup (empty means none are sent).
    public var options: GameOptions {
        switch self {
        case .holdem(_, let muck): muck ? ["muckLosers": .bool(true)] : [:]
        case .blackjack(let rules): rules.options
        case .batak(_, let rules): rules.options
        case .okey101: [:]
        case .pisti(let options): options.options
        case .okey(let options): options.options
        case .tavla(let options): options.options
        case .custom(_, let options): options
        }
    }
}
/// Consent to end the running primary activity (for example a cinema session) and open the table instead.
/// The service rejects it with `PRIMARY_ACTIVITY_STALE` when that activity changed meanwhile.
public struct GameReplacement: Equatable, Sendable {
    public let activity: String
    public let startedAt: Int
    public init(activity: String, startedAt: Int) { self.activity = activity; self.startedAt = startedAt }
    public init?(_ primary: ActivityPrimary?) {
        guard let primary, let startedAt = primary.startedAt, startedAt.isFinite, startedAt >= 0 else { return nil }
        self.init(activity: primary.activity, startedAt: Int(startedAt))
    }
}

/// `game.action` payloads. Positions/ids come from the views above.
public enum GameAction: Equatable, Sendable {
    /// Owner only, between hands.
    case start
    // Hold'em
    case fold, check, call
    /// `to` is the new total street bet (not the increment); see `HoldemHandView.raiseRange`.
    case raise(to: Int)
    // Blackjack
    /// Between hands: a positive even amount up to the seat's chips.
    case bet(Int)
    case hit, stand, double, split
    /// Table rules: only when `legalActions` offers them.
    case surrender, insurance, declineInsurance
    // Batak
    case bid(Int)
    /// In Koz Maça a pass commits to 1.
    case pass
    case trump(CardSuit)
    /// Gömmeli: exactly four own card ids.
    case bury(cardIDs: [String])
    case play(cardID: String)
    // 101 Okey
    /// Draw from the stock; in the discard stage after `takeDiscard`, undoes the take and draws from the stock.
    case draw
    /// Take the previous player's last discard (it must be used in an opening or a meld this turn).
    case takeDiscard
    case discard(tileID: String)
    /// Ordered physical tile ids per run/group; `kinds` reads each meld as a run or a group when its okeys allow
    /// both (nil entries let the server pick; nil sends nothing).
    case open(melds: [[String]], kinds: [OkeyMeldKind?]? = nil)
    /// Five or more pairs.
    case openPairs([[String]])
    /// Add tiles to the table meld at `meld`; with `replacingJoker`, swap the one natural tile for that joker.
    case process(meld: Int, tileIDs: [String], replacingJoker: String? = nil)
    /// First turn only: show the indicator's twin from the hand.
    case gosterge

    public var kind: GameActionKind {
        switch self {
        case .start: .start
        case .fold: .fold
        case .check: .check
        case .call: .call
        case .raise: .raise
        case .bet: .bet
        case .hit: .hit
        case .stand: .stand
        case .double: .double
        case .split: .split
        case .surrender: .surrender
        case .insurance: .insurance
        case .declineInsurance: .declineInsurance
        case .gosterge: .gosterge
        case .bid: .bid
        case .pass: .pass
        case .trump: .trump
        case .bury: .bury
        case .play: .play
        case .draw, .takeDiscard: .draw
        case .discard: .discard
        case .open: .open
        case .openPairs: .openPairs
        case .process: .process
        }
    }
    var json: JSONValue {
        var value: [String: JSONValue] = ["type": .string("game.action"), "action": .string(kind.rawValue)]
        let amount = { (n: Int) in JSONValue.number(Double(min(1_000_000, max(0, n)))) }
        let ids = { (list: [String]) in JSONValue.array(list.prefix(30).map(JSONValue.string)) }
        let groups = { (list: [[String]]) in JSONValue.array(list.prefix(10).map { .array($0.prefix(13).map(JSONValue.string)) }) }
        switch self {
        case .raise(let to): value["amount"] = amount(to)
        case .bet(let n), .bid(let n): value["amount"] = amount(n)
        case .trump(let suit): value["trump"] = .string(suit.rawValue)
        case .bury(let cards): value["tileIds"] = ids(cards)
        case .play(let card): value["cardId"] = .string(card)
        case .takeDiscard: value["cardId"] = .string("discard")
        case .discard(let tile): value["cardId"] = .string(tile)
        case .open(let melds, let kinds):
            value["melds"] = groups(melds)
            if let kinds { value["meldKinds"] = .array(kinds.prefix(10).map { $0.map { .string($0.rawValue) } ?? .null }) }
        case .openPairs(let melds): value["melds"] = groups(melds)
        case .process(let meld, let tiles, let joker):
            value["amount"] = amount(meld); value["tileIds"] = ids(tiles)
            if let joker { value["cardId"] = .string(joker) }
        default: break
        }
        return .object(value)
    }
}

/// 101: how an opening meld with okeys is read (`meldKinds`).
public enum OkeyMeldKind: String, Sendable { case run, group }

/// The `game.*` commands; send through `ActivityCommand.game(_:)` and `ActivityCommand.envelope`.
public enum GameCommand: Equatable, Sendable {
    /// Seat numbers run 0..<`maxSeats` (protocol `MAX_GAME_SEATS`).
    public static let maxSeats = 12
    /// Encoded `game.action.payload` limit (protocol `MAX_GAME_PAYLOAD_BYTES`).
    public static let maxPayloadBytes = 8192
    case create(GameSetup, replacing: GameReplacement? = nil)
    /// Owner only, Hold'em, before the first hand.
    case configure(HoldemTableRules)
    case watch(Bool)
    /// Take a free seat; on the own seat, asks to take control back from the bot. `buyIn` is Hold'em, and the
    /// Blackjack rebuy on the own seat when chips are below 2.
    case sit(seat: Int, buyIn: Int? = nil)
    /// Owner only.
    case addBot(seat: Int)
    /// Owner or room host: frees a bot's seat or an away player's seat (`game.seat.remove`).
    case removeSeat(seat: Int)
    /// "Masadan kalk": frees the seat between hands, a bot finishes a running hand; also stops watching.
    case leave
    case action(GameAction)
    /// A registry game's action: `{action, payload}` (Pişti `play`, Okey `draw`, Tavla `move`…). See `GameMove`.
    case act(name: String, payload: JSONValue? = nil)

    /// The protocol's shape check for `act` (`GAME_ACTION_PATTERN` and the payload size); the service checks the rest.
    public static func validAction(name: String, payload: JSONValue?) -> Bool {
        guard name.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil, name != "start" || payload == nil else { return false }
        guard let payload else { return true }
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        return data.count <= maxPayloadBytes
    }
    public var valid: Bool {
        if case .act(let name, let payload) = self { return Self.validAction(name: name, payload: payload) }
        return true
    }

    public var json: JSONValue {
        let seatNumber = { (n: Int) in JSONValue.number(Double(min(Self.maxSeats - 1, max(0, n)))) }
        switch self {
        case .create(let setup, let replacing):
            var value: [String: JSONValue] = ["type": .string("game.create"), "game": .string(setup.kind.rawValue)]
            switch setup {
            case .holdem(let rules, _): if let rules { value["holdem"] = rules.json }
            case .batak(let variant, _): value["variant"] = .string(variant.rawValue)
            case .okey101(let folding, let teams): value["folding"] = .bool(folding); value["teams"] = .bool(teams)
            case .blackjack, .pisti, .okey, .tavla, .custom: break
            }
            if let options = GameOptionsEncoding.json(setup.options) { value["options"] = options }
            if let replacing {
                value["replacePrimary"] = .object(["activity": .string(replacing.activity), "startedAt": .number(Double(max(0, replacing.startedAt)))])
            }
            return .object(value)
        case .configure(let rules): return .object(["type": .string("game.configure"), "holdem": rules.json])
        case .watch(let watching): return .object(["type": .string("game.watch"), "watching": .bool(watching)])
        case .sit(let seat, let buyIn):
            var value: [String: JSONValue] = ["type": .string("game.sit"), "seat": seatNumber(seat)]
            if let buyIn { value["buyIn"] = .number(Double(min(1_000_000, max(1, buyIn)))) }
            return .object(value)
        case .addBot(let seat): return .object(["type": .string("game.bot.add"), "seat": seatNumber(seat)])
        case .removeSeat(let seat): return .object(["type": .string("game.seat.remove"), "seat": seatNumber(seat)])
        case .leave: return .object(["type": .string("game.leave")])
        case .action(let action): return action.json
        case .act(let name, let payload):
            var value: [String: JSONValue] = ["type": .string("game.action"), "action": .string(name)]
            if let payload { value["payload"] = payload }
            return .object(value)
        }
    }
}

/// Typed `game.action` payloads of the registry games, as their `parseCommand` reads them.
public enum GameMove {
    /// Pişti: play a card from the hand.
    public static func pistiPlay(cardID: String) -> GameCommand { .act(name: "play", payload: .object(["cardId": .string(cardID)])) }
    /// Okey: draw from the stock or take the previous player's discard.
    public static func okeyDraw(fromDiscard: Bool) -> GameCommand { .act(name: "draw", payload: .object(["from": .string(fromDiscard ? "discard" : "stock")])) }
    public static func okeyDiscard(tileID: String) -> GameCommand { .act(name: "discard", payload: .object(["tileId": .string(tileID)])) }
    /// Finish by putting this last tile in the middle.
    public static func okeyFinish(tileID: String) -> GameCommand { .act(name: "finish", payload: .object(["tileId": .string(tileID)])) }
    public static let okeyShowIndicator = GameCommand.act(name: "show-indicator")
    /// Tavla point: 0…23, the bar (from) or off the board (to).
    public enum TavlaPoint: Equatable, Sendable {
        case point(Int), bar, off
        var json: JSONValue {
            switch self {
            case .point(let index): .number(Double(min(23, max(0, index))))
            case .bar: .string("bar")
            case .off: .string("off")
            }
        }
    }
    public static let tavlaRoll = GameCommand.act(name: "roll")
    /// One step; `die` picks which die it uses when both could.
    public static func tavlaMove(from: TavlaPoint, to: TavlaPoint, die: Int? = nil) -> GameCommand {
        var payload: [String: JSONValue] = ["from": from.json, "to": to.json]
        if let die { payload["die"] = .number(Double(min(6, max(1, die)))) }
        return .act(name: "move", payload: .object(payload))
    }
    public static let tavlaUndo = GameCommand.act(name: "undo")
    public static let tavlaConfirm = GameCommand.act(name: "confirm")
}

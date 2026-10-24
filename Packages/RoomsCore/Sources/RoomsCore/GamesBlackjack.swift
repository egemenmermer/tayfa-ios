import Foundation

// Blackjack table model for the iPhone table (desktop `apps/desktop/src/games/blackjack/model.ts`).
// `BlackjackHandView` in Games.swift predates the insurance/surrender rules; `BlackjackRound` reads the full
// `blackjackTableView` shape (insurancePending, rules, insurance stakes, surrendered hands) with every field
// optional, so an older service still draws a table. Game decisions stay server-owned: these are presentational.

private extension KeyedDecodingContainer {
    func blackjackSoft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
    /// Chip amounts are whole numbers on the wire; tolerate a `5.0`.
    func blackjackInt(_ key: Key) -> Int? { blackjackSoft(Int.self, key) ?? blackjackSoft(Double.self, key).flatMap { $0.isFinite ? Int($0.rounded()) : nil } }
}

// MARK: - View

/// Table rule switches (`BLACKJACK_DEFAULT_RULES`: insurance on, late surrender off).
public struct BlackjackRules: Codable, Equatable, Sendable {
    public var insurance: Bool
    public var surrender: Bool
    public init(insurance: Bool = true, surrender: Bool = false) { self.insurance = insurance; self.surrender = surrender }
    public static let standard = BlackjackRules()
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        insurance = c.blackjackSoft(Bool.self, .insurance) ?? Self.standard.insurance
        surrender = c.blackjackSoft(Bool.self, .surrender) ?? Self.standard.surrender
    }
}

public struct BlackjackRoundHand: Decodable, Equatable, Sendable {
    public let cards: [PlayingCard]
    public let bet: Int
    /// `playing`, `stood` or `bust`.
    public let state: String
    public let split: Bool
    public let surrendered: Bool
    public init(cards: [PlayingCard], bet: Int, state: String = "playing", split: Bool = false, surrendered: Bool = false) {
        self.cards = cards; self.bet = bet; self.state = state; self.split = split; self.surrendered = surrendered
    }
    enum CodingKeys: String, CodingKey { case cards, bet, state, split, surrendered }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cards = c.blackjackSoft([PlayingCard].self, .cards) ?? []
        bet = c.blackjackInt(.bet) ?? 0
        state = c.blackjackSoft(String.self, .state) ?? "playing"
        split = c.blackjackSoft(Bool.self, .split) ?? false
        surrendered = c.blackjackSoft(Bool.self, .surrendered) ?? false
    }
    public var total: BlackjackTotal { BlackjackTotal(cards) }
    public var bust: Bool { state == "bust" || total.best > 21 }
    /// Two-card 21 on an unsplit hand.
    public var natural: Bool { cards.count == 2 && !split && total.best == 21 }
}

public struct BlackjackRoundPlayer: Decodable, Equatable, Sendable, Identifiable {
    public let userId: String
    /// Chips left after the stakes on the table.
    public let credits: Int
    /// The bet chosen for this round ("Aynı bahis" repeats it).
    public let bet: Int
    public let hands: [BlackjackRoundHand]
    public let activeHand: Int
    /// Insurance stake taken this round (0 = declined, nil = never asked).
    public let insurance: Int?
    public let insuranceDecided: Bool
    /// Insurance payout at settlement (stake included).
    public let insuranceReturned: Int?
    public var id: String { userId }
    public init(userId: String, credits: Int, bet: Int, hands: [BlackjackRoundHand], activeHand: Int = 0,
                insurance: Int? = nil, insuranceDecided: Bool = false, insuranceReturned: Int? = nil) {
        self.userId = userId; self.credits = credits; self.bet = bet; self.hands = hands; self.activeHand = activeHand
        self.insurance = insurance; self.insuranceDecided = insuranceDecided; self.insuranceReturned = insuranceReturned
    }
    enum CodingKeys: String, CodingKey { case userId, credits, bet, hands, activeHand, insurance, insuranceDecided, insuranceReturned }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        credits = c.blackjackInt(.credits) ?? 0
        bet = c.blackjackInt(.bet) ?? 0
        hands = c.blackjackSoft([BlackjackRoundHand].self, .hands) ?? []
        activeHand = c.blackjackInt(.activeHand) ?? 0
        insurance = c.blackjackInt(.insurance)
        insuranceDecided = c.blackjackSoft(Bool.self, .insuranceDecided) ?? false
        insuranceReturned = c.blackjackInt(.insuranceReturned)
    }
    /// Chips staked this round: every hand (doubles and splits included) plus insurance.
    public var staked: Int { hands.reduce(0) { $0 + $1.bet } + (insurance ?? 0) }
}

/// One `room.game.view` of a Blackjack table.
public struct BlackjackRound: Decodable, Equatable, Sendable {
    public let revision: Int
    /// The up card while playing; every card once finished.
    public let dealer: [PlayingCard]
    public let dealerHiddenCount: Int
    public let players: [BlackjackRoundPlayer]
    /// Index into `players` (round order, not seat numbers).
    public let turn: Int?
    /// The insurance prompt is open: `turn` is the player who must answer; nobody plays yet.
    public let insurancePending: Bool
    public let rules: BlackjackRules
    public let finished: Bool
    public let results: [BlackjackResult]
    public init(revision: Int = 1, dealer: [PlayingCard], dealerHiddenCount: Int = 0, players: [BlackjackRoundPlayer], turn: Int? = nil,
                insurancePending: Bool = false, rules: BlackjackRules = .standard, finished: Bool = false, results: [BlackjackResult] = []) {
        self.revision = revision; self.dealer = dealer; self.dealerHiddenCount = dealerHiddenCount; self.players = players; self.turn = turn
        self.insurancePending = insurancePending; self.rules = rules; self.finished = finished; self.results = results
    }
    enum CodingKeys: String, CodingKey { case revision, dealer, dealerHiddenCount, players, turn, insurancePending, rules, finished, results }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let players = c.blackjackSoft([BlackjackRoundPlayer].self, .players) else {
            throw DecodingError.keyNotFound(CodingKeys.players, .init(codingPath: c.codingPath, debugDescription: "No Blackjack round"))
        }
        self.players = players
        revision = c.blackjackInt(.revision) ?? 0
        dealer = c.blackjackSoft([PlayingCard].self, .dealer) ?? []
        dealerHiddenCount = max(0, c.blackjackInt(.dealerHiddenCount) ?? 0)
        turn = c.blackjackInt(.turn)
        insurancePending = c.blackjackSoft(Bool.self, .insurancePending) ?? false
        rules = c.blackjackSoft(BlackjackRules.self, .rules) ?? .standard
        finished = c.blackjackSoft(Bool.self, .finished) ?? false
        results = c.blackjackSoft([BlackjackResult].self, .results) ?? []
    }

    public func player(_ userID: String?) -> BlackjackRoundPlayer? { players.first { $0.userId == userID } }
    /// Whose decision the table waits for (nil once the round is over).
    public var actingUserId: String? {
        guard !finished, let turn, players.indices.contains(turn) else { return nil }
        return players[turn].userId
    }
    /// The hand being played now; none during the insurance prompt (desktop decision).
    public func isActive(_ userID: String, hand index: Int) -> Bool {
        !insurancePending && actingUserId == userID && player(userID)?.activeHand == index
    }
    public func outcome(_ userID: String, hand index: Int) -> String? {
        results.first { $0.userId == userID && $0.hand == index }?.outcome
    }
    /// Chips back (hands and insurance) minus chips staked this round.
    public func net(_ userID: String) -> Int? {
        guard finished, let player = player(userID) else { return nil }
        let back = results.filter { $0.userId == userID }.reduce(0) { $0 + $1.returned } + (player.insuranceReturned ?? 0)
        return back - player.staked
    }
    /// The dealer's total as far as it is visible ("7/17" while soft and still drawing).
    public var dealerTotalLabel: String? {
        dealer.isEmpty ? nil : BlackjackTotal.label(dealer, settled: finished)
    }
    public func badge(_ userID: String, hand index: Int) -> BlackjackBadge? {
        guard let hand = player(userID)?.hands[safe: index] else { return nil }
        if let outcome = outcome(userID, hand: index) {
            if outcome == "lose" && hand.bust { return .bust }
            return BlackjackBadge(rawValue: outcome)
        }
        if hand.surrendered { return .surrender }
        if hand.bust { return .bust }
        if hand.natural { return .blackjack }
        return nil
    }
}

public enum BlackjackBadge: String, Sendable, CaseIterable {
    case blackjack, win, lose, push, surrender, bust
    public var title: String {
        switch self {
        case .blackjack: "Blackjack"
        case .win: "Kazandı"
        case .lose: "Kaybetti"
        case .push: "Berabere"
        case .surrender: "Teslim oldu"
        case .bust: "Aştı"
        }
    }
    /// Good news for the player (green), bad (red), neutral otherwise.
    public var positive: Bool? {
        switch self {
        case .blackjack, .win: true
        case .lose, .bust: false
        case .push, .surrender: nil
        }
    }
}

extension GameState {
    /// The Blackjack round with insurance/surrender fields; nil before the first deal or without access.
    public var blackjackRound: BlackjackRound? { kind == .blackjack ? view(as: BlackjackRound.self) : nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Totals and chips

/// A hand total with the soft alternative while an ace can still count 11 (`handTotal`).
public struct BlackjackTotal: Equatable, Sendable {
    public let hard: Int
    public let soft: Int?
    public var best: Int { soft ?? hard }
    public init(_ cards: [PlayingCard]) {
        let hard = cards.reduce(0) { $0 + ($1.rank == 14 ? 1 : min($1.rank, 10)) }
        self.hard = hard
        soft = cards.contains { $0.rank == 14 } && hard + 10 <= 21 ? hard + 10 : nil
    }
    /// "7/17" for a soft hand that is still open, the single best total otherwise; empty for no cards.
    public static func label(_ cards: [PlayingCard], settled: Bool) -> String {
        guard !cards.isEmpty else { return "" }
        let total = BlackjackTotal(cards)
        if let soft = total.soft, !settled, soft != 21 { return "\(total.hard)/\(soft)" }
        return String(total.best)
    }
}

public enum BlackjackChips {
    /// Rack denominations, largest first: 500 purple, 100 black, 25 green, 5 red, 1 white.
    public static let values = [500, 100, 25, 5, 1]
    /// Bet buttons; all even, so any sum stays a legal (even) bet.
    public static let betButtons = [2, 10, 20, 50, 100]
    /// The chips a stack of `amount` is made of, largest first.
    public static func stack(_ amount: Int) -> [Int] {
        var left = max(0, amount), chips: [Int] = []
        for value in values { while left >= value { chips.append(value); left -= value } }
        return chips
    }
    /// The same stack grouped: [(100, 2), (25, 1)].
    public static func breakdown(_ amount: Int) -> [(value: Int, count: Int)] {
        var out: [(value: Int, count: Int)] = []
        for chip in stack(amount) {
            if let last = out.last, last.value == chip { out[out.count - 1].count += 1 } else { out.append((chip, 1)) }
        }
        return out
    }
    /// The largest even bet a stack covers (bets are even and at least 2).
    public static func maxBet(_ chips: Int) -> Int { max(0, chips - chips % 2) }
    /// A chip button adds to the pending bet only while the sum stays coverable.
    public static func canAdd(_ chip: Int, to bet: Int, chips: Int) -> Bool { bet + chip <= maxBet(chips) && chip > 0 }
}

// MARK: - Controls

/// Which table controls the viewer gets, from the server's `legalActions` and the view.
public struct BlackjackControls: Equatable, Sendable {
    public enum Insurance: Equatable, Sendable {
        case none
        /// The prompt is the viewer's: `canTake` false = only "Sigorta alma" is legal (not enough chips).
        case mine(canTake: Bool, stake: Int)
        /// Someone else answers now.
        case waiting(name: String)
    }
    /// The viewer holds a hand this round and it is being played (not the insurance prompt): show the play row.
    public let showPlay: Bool
    public let hit: Bool
    public let stand: Bool
    public let double: Bool
    public let split: Bool
    /// Late surrender, shown only when the server lists it.
    public let surrender: Bool
    public let insurance: Insurance
    /// Between hands with chips: bet panel.
    public let betting: Bool
    /// Between hands below the smallest bet: "Para al" (`game.sit` with `buyIn`).
    public let rebuy: Bool

    public static let rebuyAmount = 1000

    public init(game: GameState, round: BlackjackRound?, me: String, busy: Bool) {
        let seat = game.seat(of: me), playing = game.status == .playing
        let live = playing && round.map { !$0.finished } == true
        let mine = round?.player(me), acting = round?.actingUserId
        let ownTurn = live && acting == me && mine != nil
        let pending = live && round?.insurancePending == true
        let ok = { (action: GameActionKind) in ownTurn && !pending && !busy && game.can(action) }
        showPlay = live && mine != nil && !pending
        hit = ok(.hit); stand = ok(.stand); double = ok(.double); split = ok(.split)
        surrender = ok(.surrender)
        if pending, let acting {
            if acting == me, let mine {
                insurance = .mine(canTake: game.can(.insurance), stake: (mine.hands.first?.bet ?? 0) / 2)
            } else {
                insurance = .waiting(name: game.seat(of: acting)?.name ?? "Oyuncu")
            }
        } else {
            insurance = .none
        }
        let between = seat != nil && !playing
        betting = between && (seat?.chips ?? 0) >= 2
        rebuy = between && (seat?.chips ?? 0) < 2
    }
}

// MARK: - Layout, moves, summary

public enum BlackjackLayout {
    /// Everyone else at the table in seat order (the viewer's own spot is drawn big at the bottom).
    public static func others(_ game: GameState, me: String) -> [GameSeat] { game.orderedSeats.filter { $0.userId != me } }
    /// Seated but not dealt in (sat down late, or could not cover the smallest bet).
    public static func sittingOut(_ game: GameState, round: BlackjackRound?, userID: String) -> Bool {
        guard game.status == .playing, let round, !round.finished else { return false }
        return game.seat(of: userID) != nil && round.player(userID) == nil
    }
}

/// What a player did between two views of the same round, so the table can name the last move.
public enum BlackjackMove: Equatable, Sendable {
    case hit(String), bust(String), stand(String), double(String), split(String), surrender(String)
    case insurance(String), declineInsurance(String)
    public var userId: String {
        switch self {
        case .hit(let id), .bust(let id), .stand(let id), .double(let id), .split(let id), .surrender(let id), .insurance(let id), .declineInsurance(let id): id
        }
    }
    public func text(_ name: String) -> String {
        switch self {
        case .hit: "\(name) kart aldı"
        case .bust: "\(name) kart aldı ve aştı"
        case .stand: "\(name) durdu"
        case .double: "\(name) ikiye katladı"
        case .split: "\(name) eli ayırdı"
        case .surrender: "\(name) teslim oldu"
        case .insurance: "\(name) sigorta aldı"
        case .declineInsurance: "\(name) sigorta almadı"
        }
    }
    /// Moves from `previous` to `next`; empty across rounds (callers pass nil when the hand number changed).
    public static func moves(from previous: BlackjackRound?, to next: BlackjackRound) -> [BlackjackMove] {
        guard let previous, !previous.finished else { return [] }
        var moves: [BlackjackMove] = []
        for player in next.players {
            guard let old = previous.player(player.userId) else { continue }
            if !old.insuranceDecided && player.insuranceDecided {
                moves.append((player.insurance ?? 0) > 0 ? .insurance(player.userId) : .declineInsurance(player.userId))
            }
            if player.hands.count > old.hands.count { moves.append(.split(player.userId)); continue }
            for (index, hand) in player.hands.enumerated() {
                guard let was = old.hands[safe: index] else { continue }
                if hand.surrendered && !was.surrendered { moves.append(.surrender(player.userId)) }
                else if hand.bet > was.bet { moves.append(.double(player.userId)) }
                else if hand.cards.count > was.cards.count && !(was.split && was.cards.count == 1) {
                    moves.append(hand.total.best > 21 ? .bust(player.userId) : .hit(player.userId))
                } else if was.state == "playing" && hand.state == "stood" && hand.cards.count == was.cards.count {
                    moves.append(.stand(player.userId))
                }
            }
        }
        return moves
    }
}

/// One line of the round summary: net per player, in seat order.
public struct BlackjackSummaryLine: Equatable, Sendable, Identifiable {
    public let userId: String
    public let name: String
    public let net: Int
    public let badges: [BlackjackBadge]
    public var id: String { userId }
    /// "+15", "−10", "0".
    public var netText: String { net > 0 ? "+\(net)" : net < 0 ? "−\(-net)" : "0" }

    public static func lines(_ game: GameState, round: BlackjackRound, me: String) -> [BlackjackSummaryLine] {
        guard round.finished else { return [] }
        let order = Dictionary(game.seats.map { ($0.userId, $0.seat) }, uniquingKeysWith: { first, _ in first })
        return round.players
            .sorted { (order[$0.userId] ?? Int.max) < (order[$1.userId] ?? Int.max) }
            .map { player in
                BlackjackSummaryLine(userId: player.userId,
                                     name: player.userId == me ? "Sen" : game.seat(of: player.userId)?.name ?? "Oyuncu",
                                     net: round.net(player.userId) ?? 0,
                                     badges: player.hands.indices.compactMap { round.badge(player.userId, hand: $0) })
            }
    }
}

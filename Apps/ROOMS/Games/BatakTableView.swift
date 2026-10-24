import SwiftUI
import UIKit
import RoomsCore

/// Batak table, portrait: up to four seats around the felt (you at the bottom, the next player on the RIGHT;
/// three-handed Gömmeli uses the top corners), the trick in the middle with every card in front of its player
/// (a completed trick stays 1.2 s, then sweeps to the winner), your hand as an overlapped scrollable fan at the
/// bottom (legal cards raised, illegal ones dimmed, tap to play), the auction panel (bid grid from the lowest
/// legal bid + Pas, bid history), the trump picker, the gömü selection for the Gömmeli bidder, the K1
/// "Koz kırıldı" chip, tricks against the contract per seat, the round summary and the running score sheet.
/// Everything is read through `GamesBatak.swift` (`BatakRound`); moves go out as `GameAction` through the context.
/// The host already draws the header (seats, turn clock), banners, errors, leave and the next deal.
struct BatakTableView: View {
    let context: GameTableContext
    var body: some View {
        if let round = context.game.batakRound {
            BatakBoard(context: context, round: round)
        } else {
            ContentUnavailableView {
                Label(context.game.table.spectatorAccess ? "Kartlar dağıtılmadı" : "Masa gizli", systemImage: "suit.spade.fill")
            } description: {
                Text(context.game.table.spectatorAccess ? "El başlayınca kartlar burada görünür." : "Masayı görmek için izleyici olarak katıl ya da boş bir koltuğa otur.")
            }
        }
    }
}

// MARK: - Board

private struct BatakBoard: View {
    let context: GameTableContext
    let round: BatakRound
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracker = BatakTrickTracker()
    /// Redraw clock for the trick hold/sweep phases.
    @State private var clock = Date()
    /// Gömü picks (card ids).
    @State private var picks: Set<String> = []
    @State private var showLast = false
    @State private var sheetOpen = false

    private var game: GameState { context.game }
    private var players: Int { round.playerCount(seated: game.orderedSeats.count) }
    /// The viewer's round index, nil for spectators.
    private var viewer: Int? { context.myPosition.flatMap { $0 < players ? $0 : nil } }
    private var ended: Bool { round.stage == .ended }
    private var auction: Bool { round.stage == .bidding || round.stage == .trump || round.stage == .bury }
    private var myTurn: Bool { viewer != nil && round.turn == viewer }
    private var eventKey: String { "\(game.history.count):\(round.completedTricks.count):\(round.trick.count):\(round.bidLog.count):\(round.stage.rawValue)" }
    private var holdKey: String { tracker.held.map { "\($0.key):\($0.sweepAt.timeIntervalSince1970)" } ?? "-" }
    private func name(_ index: Int) -> String {
        guard let seat = game.seat(atPosition: index) else { return "Oyuncu" }
        return seat.userId == context.me ? "Sen" : seat.name
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 10) {
                        BatakInfoBar(round: round, game: game, bidderName: name(round.bidder), onSheet: { sheetOpen = true })
                        felt(width: proxy.size.width - 24)
                        Text(lastLine).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                            .frame(maxWidth: .infinity, minHeight: 32)
                        if auction { auctionPanel }
                        if !round.buried.isEmpty { buriedRow }
                        if ended { BatakSummary(round: round, game: game, players: players, name: name) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                if viewer != nil && !ended { handArea }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .sheet(isPresented: $sheetOpen) {
            BatakScoreSheetView(game: game, players: players, name: name).presentationDetents([.medium, .large])
        }
        .onAppear { tracker.observe(round, deal: game.history.count, now: Date()) }
        .onChange(of: eventKey) { _, _ in observe() }
        .onChange(of: round.stage) { _, stage in
            picks = []; showLast = false
            if stage == .ended { GameSounds.play(.end) } else if stage == .bidding { GameSounds.play(.deal) }
        }
        .task(id: holdKey) {
            // One redraw at each phase change of the held trick (hold -> sweep -> gone).
            while let next = tracker.nextChange(after: Date()) {
                try? await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSinceNow)))
                if Task.isCancelled { return }
                withAnimation(reduceMotion ? nil : .easeIn(duration: BatakTrickTracker.sweepSeconds)) { clock = Date() }
            }
            tracker.expire(at: Date())
        }
    }

    private func observe() {
        var next = tracker
        let completed = next.observe(round, deal: game.history.count, now: Date())
        tracker = next
        clock = Date()
        if completed {
            GameSounds.play(.capture)
            if let held = next.held { AccessibilityNotification.Announcement("\(name(held.winner)) eli aldı").post() }
        } else if !round.trick.isEmpty {
            GameSounds.play(.play)
        }
    }

    /// What just happened, kept visible until the next move.
    private var lastLine: String {
        if let held = tracker.held, tracker.phase(at: clock) != nil { return "\(name(held.winner)) eli aldı" }
        if let play = round.trick.last { return "\(name(play.seat)) \(play.card.suit.title) \(play.card.rankLabel) attı" }
        switch round.stage {
        case .bidding:
            if let entry = round.bidLog.last { return round.bidLine(entry, name: name(entry.seat)) }
            return round.variant == .kozMaca ? "Herkes kaç el alacağını söyler" : "İhale başlıyor"
        case .trump: return "\(name(round.bidder)) \(round.bid) ile ihaleyi aldı, kozu seçiyor"
        case .bury: return "\(name(round.bidder)) gömüyü seçiyor"
        case .playing:
            if let last = round.completedTricks.last { return "\(name(last.winner)) eli aldı" }
            if let turn = round.turn { return "\(name(turn)) ilk kartı açıyor" }
            return ""
        case .ended: return "El bitti"
        }
    }

    // MARK: Felt

    private func felt(width: CGFloat) -> some View {
        let side = max(150, min(240, width - 2 * 84))
        let threeHanded = players == 3
        return VStack(spacing: 6) {
            HStack(alignment: .top) {
                if threeHanded {
                    seat(.topLeft)
                    Spacer(minLength: 4)
                    seat(.topRight)
                } else {
                    Spacer(minLength: 0)
                    seat(.top)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 4) {
                if !threeHanded { seat(.left).frame(width: 80) }
                center(side: side).frame(width: side, height: side * 0.9)
                if !threeHanded { seat(.right).frame(width: 80) }
            }
            seat(.bottom)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.33, blue: 0.22), Color(red: 0.04, green: 0.22, blue: 0.15)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12)))
    }

    @ViewBuilder private func seat(_ spot: BatakSpot) -> some View {
        if let index = BatakLayout.round(at: spot, viewer: viewer, players: players) {
            BatakSeatView(context: context, round: round, index: index, viewer: viewer, compact: spot == .bottom)
        }
    }

    /// The trick, each card in front of its player; the held trick on top while it waits and sweeps.
    private func center(side: CGFloat) -> some View {
        let cardWidth = min(56, side * 0.25)
        let distance = side * 0.25
        let phase = tracker.phase(at: clock)
        return ZStack {
            if auction && round.trick.isEmpty {
                BatakAuctionCenter(round: round, bidderName: name(round.bidder))
            }
            ForEach(Array(round.trick.enumerated()), id: \.element.card.id) { order, play in
                let at = offset(for: play.seat, distance: distance)
                GameCardView(card: play.card, width: cardWidth)
                    .offset(at)
                    .zIndex(Double(order))
                    // Removal is instant: the same cards continue as the held trick at the same spots.
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .offset(x: at.width * 2.4, y: at.height * 2.4).combined(with: .opacity),
                                            removal: .identity))
            }
            if let held = tracker.held, let phase {
                let to = offset(for: held.winner, distance: distance * 3.2)
                ForEach(Array(held.plays.enumerated()), id: \.element.card.id) { order, play in
                    GameCardView(card: play.card, width: cardWidth, selected: play.seat == held.winner && phase == .holding)
                        .offset(phase == .sweeping ? to : offset(for: play.seat, distance: distance))
                        .scaleEffect(phase == .sweeping ? 0.55 : 1)
                        .opacity(phase == .sweeping ? 0 : 1)
                        .zIndex(10 + Double(order))
                }
            } else if showLast, round.trick.isEmpty, let last = round.completedTricks.last {
                ForEach(last.plays, id: \.card.id) { play in
                    GameCardView(card: play.card, width: cardWidth, selected: play.seat == last.winner)
                        .offset(offset(for: play.seat, distance: distance))
                }
                Text("Son el").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.4), in: Capsule())
            }
            if round.stage == .playing, round.trick.isEmpty, tracker.held == nil, !round.completedTricks.isEmpty {
                Button(showLast ? "Gizle" : "Son eli göster") { showLast.toggle() }
                    .font(.caption.bold()).buttonStyle(.bordered).tint(.white)
                    .frame(minHeight: 44)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: round.trick.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(trickLabel)
    }
    private var trickLabel: String {
        let plays = round.trick.isEmpty ? (tracker.held?.plays ?? []) : round.trick
        if plays.isEmpty { return "Ortada kart yok" }
        return "Ortada: " + plays.map { "\(name($0.seat)) \($0.card.suit.title) \($0.card.rankLabel)" }.joined(separator: ", ")
    }
    private func offset(for index: Int, distance: CGFloat) -> CGSize {
        switch BatakLayout.spot(of: index, viewer: viewer, players: players) {
        case .bottom: CGSize(width: 0, height: distance)
        case .right: CGSize(width: distance, height: 0)
        case .top: CGSize(width: 0, height: -distance)
        case .left: CGSize(width: -distance, height: 0)
        case .topRight: CGSize(width: distance * 0.8, height: -distance * 0.55)
        case .topLeft: CGSize(width: -distance * 0.8, height: -distance * 0.55)
        }
    }

    // MARK: Auction

    private var auctionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !round.bidLog.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(round.bidLog.enumerated()), id: \.offset) { _, entry in
                            Text("\(name(entry.seat)) · \(said(entry))")
                                .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(entry.pass && round.variant != .kozMaca ? Palette.raised : Palette.accent.opacity(0.25), in: Capsule())
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("İhale geçmişi: " + round.bidLog.map { round.bidLine($0, name: name($0.seat)) }.joined(separator: ", "))
            }
            if round.stage == .bidding && (context.can(.bid) || context.can(.pass)) {
                bidGrid
            } else if round.stage == .trump && context.can(.trump) {
                trumpPicker
            } else if round.stage == .bury && context.can(.bury) {
                Text("Koz \(round.trump.map { "\($0.symbol) \($0.title)" } ?? ""). Gömmek için elinden 4 kart seç; gömü sayılmaz.")
                    .font(.footnote)
            } else if let turn = round.turn, !myTurn {
                Label(waitingLine(turn), systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func said(_ entry: BatakBidEntry) -> String {
        if round.variant == .kozMaca { return String(entry.amount ?? 1) }
        return entry.pass ? "Pas" : String(entry.amount ?? 0)
    }
    private func waitingLine(_ turn: Int) -> String {
        switch round.stage {
        case .bidding: "\(name(turn)) düşünüyor"
        case .trump: "\(name(turn)) kozu seçiyor"
        case .bury: "\(name(turn)) gömüyü seçiyor"
        default: ""
        }
    }
    private var bidGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(round.variant == .kozMaca ? "Kaç el alacaksın?" : round.bid > 0 ? "En yüksek ihale \(round.bid). Daha yüksek söyle ya da pas de." : "İhale ver ya da pas de.")
                .font(.subheadline.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(round.bidOptions, id: \.self) { amount in
                    Button { context.act(.bid(amount)) } label: {
                        Text("\(amount)").font(.title3.monospacedDigit().bold()).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(!context.can(.bid))
                    .accessibilityLabel(round.variant == .kozMaca ? "\(amount) el" : "\(amount) ihale")
                }
            }
            Button { context.act(.pass) } label: {
                Text(round.variant == .kozMaca ? "Pas (1 el)" : "Pas").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).disabled(!context.can(.pass))
        }
    }
    private var trumpPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("İhale \(round.bid) ile sende. Kozu seç.").font(.subheadline.bold())
            HStack(spacing: 8) {
                ForEach([CardSuit.spades, .hearts, .clubs, .diamonds], id: \.self) { suit in
                    Button { context.act(.trump(suit)) } label: {
                        VStack(spacing: 2) {
                            Text(suit.symbol).font(.title)
                            Text(suit.title).font(.caption.bold())
                        }
                        .foregroundStyle(suit.red ? Color.red : Color.black)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Koz \(suit.title)")
                }
            }
        }
    }
    private var buriedRow: some View {
        HStack(spacing: 8) {
            Text("Gömün").font(.caption.bold())
            ForEach(round.buried) { card in GameCardView(card: card, width: 30) }
            Spacer(minLength: 0)
        }
        .padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gömün: " + round.buried.map { "\($0.suit.title) \($0.rankLabel)" }.joined(separator: ", "))
    }

    // MARK: Hand

    private var handArea: some View {
        let hand = BatakLayout.sortHand(round.cards(at: viewer), trump: round.trump)
        let legal = round.legalCardIDs(viewer: viewer)
        let burying = round.stage == .bury && context.can(.bury)
        let playing = round.stage == .playing && myTurn && context.can(.play)
        let cardWidth: CGFloat = 64
        // Each covered card still shows a 44 pt strip; the fan scrolls when the hand is wider than the screen.
        let overlap = cardWidth - 44
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(turnLine).font(.subheadline.bold()).foregroundStyle(myTurn ? Palette.accent : Color.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if myTurn { GameTurnClock(game: game, serverOffsetMs: context.serverOffsetMs) }
            }
            if burying {
                HStack {
                    Text("Seçilen \(picks.count)/4").font(.footnote.monospacedDigit())
                    Spacer()
                    Button("Göm") {
                        context.act(.bury(cardIDs: hand.map(\.id).filter { picks.contains($0) }))
                        picks = []
                    }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    .disabled(picks.count != 4)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: -overlap) {
                    ForEach(hand) { card in
                        let isLegal = legal.contains(card.id)
                        let picked = picks.contains(card.id)
                        Button {
                            if burying { togglePick(card.id) } else if playing && isLegal { context.act(.play(cardID: card.id)) }
                        } label: {
                            GameCardView(card: card, width: cardWidth, selected: picked, dimmed: playing && !isLegal)
                                .offset(y: playing && isLegal ? -12 : 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(!(burying || (playing && isLegal)))
                        .accessibilityLabel("\(card.suit.title) \(card.rankLabel)")
                        .accessibilityValue(burying ? (picked ? "gömülecek" : "") : playing ? (isLegal ? "oynanabilir" : "oynanamaz") : "")
                        .accessibilityHint(burying ? "Gömmek için seç" : playing && isLegal ? "Oynamak için dokun" : "")
                    }
                }
                .padding(.top, 16).padding(.horizontal, 4)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: hand.map(\.id))
            }
            .frame(height: cardWidth * 1.4 + 22)
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(myTurn ? Palette.accent : Color.clear, lineWidth: 2))
    }
    private func togglePick(_ id: String) {
        GameHaptics.tap()
        if picks.contains(id) { picks.remove(id) } else if picks.count < 4 { picks.insert(id) }
    }
    private var turnLine: String {
        guard let turn = round.turn else { return ended ? "El bitti" : "" }
        if !myTurn { return "Sıra \(name(turn))’de" }
        switch round.stage {
        case .bidding: return round.variant == .kozMaca ? "Sıra sende: kaç el alacağını söyle" : "Sıra sende: ihale ver ya da pas de"
        case .trump: return "Sıra sende: kozu seç"
        case .bury: return "Sıra sende: gömülecek 4 kartı seç"
        case .playing: return round.trick.isEmpty ? "Sıra sende: eli aç" : "Sıra sende: bir kart oyna"
        case .ended: return "El bitti"
        }
    }
}

// MARK: - Info bar

private struct BatakInfoBar: View {
    let round: BatakRound
    let game: GameState
    let bidderName: String
    let onSheet: () -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(round.variant.title, strong: true)
                if round.variant != .kozMaca && round.stage != .bidding { chip("İhale \(round.bid) · \(bidderName)") }
                chip(round.trump.map { "Koz \($0.symbol) \($0.title)" } ?? "Koz seçilmedi")
                if round.showsTrumpBroken {
                    chip(round.trumpBroken ? "Koz kırıldı" : "Koz kırılmadı", tint: round.trumpBroken ? Color.green : nil)
                        .accessibilityHint("Koz kırılmadan koz açılmaz")
                }
                chip("El \(game.history.count + (round.stage == .ended ? 0 : 1))")
                Button(action: onSheet) { Label("Puanlar", systemImage: "list.number").font(.caption.bold()).frame(minHeight: 44) }
                    .buttonStyle(.bordered)
            }
        }
    }
    private func chip(_ text: String, strong: Bool = false, tint: Color? = nil) -> some View {
        Text(text).font(strong ? .caption.bold() : .caption).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background((tint ?? Palette.raised).opacity(tint == nil ? 1 : 0.35), in: Capsule())
    }
}

// MARK: - Center during the auction

private struct BatakAuctionCenter: View {
    let round: BatakRound
    let bidderName: String
    var body: some View {
        VStack(spacing: 4) {
            if round.stage == .bidding && round.variant == .kozMaca {
                Text("Koz Maça").font(.headline)
                Text("Herkes kaç el alacağını söyler").font(.caption)
            } else if round.stage == .bidding {
                Text(round.bid > 0 ? "\(round.bid)" : "—").font(.system(size: 44, weight: .heavy, design: .rounded))
                Text(round.bid > 0 ? "En yüksek: \(bidderName)" : "İhale bekleniyor").font(.caption)
            } else if round.stage == .trump {
                Text("\(round.bid)").font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("\(bidderName) kozu seçiyor").font(.caption)
            } else {
                Image(systemName: "tray.and.arrow.down.fill").font(.title)
                Text("\(bidderName) gömüyor").font(.caption)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Seat

private struct BatakSeatView: View {
    let context: GameTableContext
    let round: BatakRound
    let index: Int
    let viewer: Int?
    /// The viewer's own seat at the bottom: one row, no card count.
    let compact: Bool
    private var game: GameState { context.game }
    private var isTurn: Bool { round.turn == index && round.stage != .ended }
    private var partner: Bool { round.variant == .esli && viewer.map { (index - $0 + 4) % 4 == 2 } == true }
    private var bidder: Bool { round.variant != .kozMaca && round.stage != .bidding && index == round.bidder }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) { avatar; details }
            } else {
                VStack(spacing: 4) { avatar; details }
            }
        }
        .padding(6)
        .background(isTurn ? Palette.accent.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isTurn ? Palette.accent : Color.clear, lineWidth: 2))
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
    @ViewBuilder private var avatar: some View {
        if let seat = game.seat(atPosition: index) {
            GameSeatBadge(seat: seat, game: game, chat: context.chat, me: context.me, size: compact ? 30 : 36)
        } else {
            Text("Boş koltuk").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var details: some View {
        VStack(spacing: 3) {
            if bidder || partner {
                HStack(spacing: 4) {
                    if bidder { tag("İhaleci", Palette.accent) }
                    if partner { tag("Eşin", Color.teal) }
                }
            }
            if round.stage == .bidding || round.variant == .kozMaca, let said = round.lastBid(of: index) { tag(said, Color.orange) }
            if round.stage != .bidding { tricksPill }
            if !compact && round.count(at: index) > 0 {
                Text("\(round.count(at: index)) kart").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
        }
    }
    private var tricksPill: some View {
        let goal = round.target(of: index)
        let taken = goal == nil ? (round.tricks.indices.contains(index) ? round.tricks[index] : 0) : round.taken(by: index)
        let made = goal.map { taken >= $0 } ?? false
        return Text(goal.map { "\(taken)/\($0)" } ?? "\(taken)")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(made ? Color.green.opacity(0.55) : Color.black.opacity(0.35), in: Capsule())
    }
    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.6), in: Capsule())
    }
    private var label: String {
        let seat = game.seat(atPosition: index)
        var parts = [seat.map { $0.userId == context.me ? "Sen" : $0.name } ?? "Boş koltuk"]
        if seat?.isBotSeat == true { parts.append("bot") }
        if isTurn { parts.append("sıra onda") }
        if bidder { parts.append("ihaleci, \(round.bid)") }
        if partner { parts.append("eşin") }
        if round.stage != .bidding {
            let goal = round.target(of: index)
            let taken = goal == nil ? (round.tricks.indices.contains(index) ? round.tricks[index] : 0) : round.taken(by: index)
            parts.append(goal.map { "\(taken) el, hedef \($0)" } ?? "\(taken) el aldı")
        } else if let said = round.lastBid(of: index) {
            parts.append("söylediği \(said)")
        }
        if !compact && round.count(at: index) > 0 { parts.append("\(round.count(at: index)) kart") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Round summary and score sheet

private struct BatakSummary: View {
    let round: BatakRound
    let game: GameState
    let players: Int
    let name: (Int) -> String
    var body: some View {
        let rows = round.summary(players: players)
        let bidderRow = rows.first { $0.round == round.bidder }
        return VStack(alignment: .leading, spacing: 10) {
            Text(round.variant == .kozMaca ? "El bitti" : bidderRow?.mark == .made ? "\(name(round.bidder)) ihaleyi çıkardı" : "\(name(round.bidder)) battı")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Oyuncu")
                    Text("Hedef")
                    Text("Aldı")
                    Text("Puan")
                    Text("")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(rows, id: \.round) { row in
                    GridRow {
                        Text(name(row.round)).lineLimit(1)
                        Text(row.contract.map(String.init) ?? "–").monospacedDigit()
                        Text("\(row.taken)").monospacedDigit()
                        Text(row.points > 0 ? "+\(row.points)" : "\(row.points)").monospacedDigit().bold()
                            .foregroundStyle(row.points < 0 ? Color.red : Color.primary)
                        markView(row.mark)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            BatakSheetTable(sheet: BatakScoreSheet(history: game.history, players: players), players: players, name: name)
            Text(game.canDeal ? "Yeni eli aşağıdan başlat." : "Masa sahibi yeni eli başlatınca kartlar dağıtılır.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private func markView(_ mark: BatakSummaryMark?) -> some View {
        if let mark {
            Text(mark.title).font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                .background(mark == .made ? Color.green.opacity(0.5) : Color.red.opacity(0.5), in: Capsule())
        } else {
            Text("")
        }
    }
}

private struct BatakSheetTable: View {
    let sheet: BatakScoreSheet
    let players: Int
    let name: (Int) -> String
    var body: some View {
        if sheet.rows.isEmpty {
            Text("Henüz biten el yok.").font(.footnote).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("El").gridColumnAlignment(.leading)
                    ForEach(0..<players, id: \.self) { seat in Text(name(seat)).lineLimit(1) }
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(sheet.rows.enumerated()), id: \.offset) { number, row in
                    GridRow {
                        Text("\(number + 1)")
                        ForEach(0..<players, id: \.self) { seat in
                            Text("\(row[seat])").foregroundStyle(row[seat] < 0 ? Color.red : Color.primary)
                        }
                    }
                    .font(.footnote.monospacedDigit())
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Toplam")
                    ForEach(0..<players, id: \.self) { seat in Text("\(sheet.totals[seat])").bold() }
                }
                .font(.footnote.monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Puan tablosu, \(sheet.rows.count) el. Toplam: " + (0..<players).map { "\(name($0)) \(sheet.totals[$0])" }.joined(separator: ", "))
        }
    }
}

private struct BatakScoreSheetView: View {
    let game: GameState
    let players: Int
    let name: (Int) -> String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                BatakSheetTable(sheet: BatakScoreSheet(history: game.history, players: players), players: players, name: name)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Puan tablosu").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
    }
}

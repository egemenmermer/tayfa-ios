import SwiftUI
import RoomsCore

/// Blackjack table (desktop `games/blackjack/BlackjackTable.tsx`): the dealer with the hole card on top, everyone
/// else's spots in seat order, the viewer's own hands big at the bottom, then the controls for this moment — the
/// insurance prompt, Hit/Stand/Double/Split (+ surrender) as the server's `legalActions` allow, or between hands the
/// round summary, the bet panel and "Para al". Rules and totals come from `RoomsCore/GamesBlackjack.swift`.
/// The host already shows the header (seats, turn clock), banners, errors, leave and deal/rematch.
struct BlackjackTableView: View {
    let context: GameTableContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bet being put together between hands (0 = none yet).
    @State private var bet = 0
    /// The amount last sent with `bet`, so the panel can say it is set (the server sends no echo).
    @State private var sentBet: Int?
    /// An opponent's last move this round ("Can kart aldı").
    @State private var lastMove: String?

    private var game: GameState { context.game }
    private var me: String { context.me }

    var body: some View {
        let round = game.blackjackRound
        let controls = BlackjackControls(game: game, round: round, me: me, busy: context.busy)
        ScrollView {
            VStack(spacing: 14) {
                if let round { rulesStrip(round.rules) }
                felt(round)
                controlsArea(round, controls)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: round?.revision)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: game.status)
        }
        .onAppear { if bet == 0 { bet = initialBet(round) } }
        .onChange(of: BlackjackSnapshot(hand: BlackjackLayout.handNumber(game), round: round)) { old, new in track(old: old, new: new) }
        .onChange(of: context.mySeat?.chips) { _, _ in if bet == 0 || bet > BlackjackChips.maxBet(context.mySeat?.chips ?? 0) { bet = initialBet(round) } }
    }

    // MARK: Felt

    private func felt(_ round: BlackjackRound?) -> some View {
        VStack(spacing: 14) {
            dealerRow(round)
            Text(statusText(round)).font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            if let lastMove, round?.finished == false {
                Label(lastMove, systemImage: "arrow.turn.down.right").font(.footnote).foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity)
            }
            others(round)
            mySpot(round)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.06, green: 0.36, blue: 0.22), Color(red: 0.03, green: 0.22, blue: 0.14)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(red: 0.45, green: 0.3, blue: 0.15), lineWidth: 4))
    }

    private func dealerRow(_ round: BlackjackRound?) -> some View {
        let dealer = round?.dealer ?? []
        let slots = dealer.count + (round?.dealerHiddenCount ?? 0)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("KRUPİYE").font(.caption.bold()).tracking(1).foregroundStyle(.white.opacity(0.7))
                if let label = round?.dealerTotalLabel, !label.isEmpty { totalPill(label, highlight: false) }
            }
            HStack(spacing: -16) {
                if slots == 0 {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 54, height: 54 * 1.4).padding(.horizontal, 10)
                    }
                } else {
                    ForEach(0..<slots, id: \.self) { index in
                        BlackjackFlipCard(card: index < dealer.count ? dealer[index] : nil, width: 54)
                            .transition(cardTransition)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dealerAccessibility(round))
        }
        // Same identity from the deal through the reveal (so the hole card turns over), fresh cards on the next deal.
        .id(BlackjackLayout.handNumber(game))
    }

    @ViewBuilder private func others(_ round: BlackjackRound?) -> some View {
        let seats = BlackjackLayout.others(game, me: me)
        if !seats.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(seats) { seat in otherSpot(seat, round: round) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func otherSpot(_ seat: GameSeat, round: BlackjackRound?) -> some View {
        let player = round?.player(seat.userId)
        let acting = round?.actingUserId == seat.userId
        return VStack(spacing: 6) {
            GameSeatBadge(seat: seat, game: game, chat: context.chat, me: me, size: 28)
            if let round, let player {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(player.hands.indices, id: \.self) { index in
                        handView(player.hands[index], index: index, player: player, round: round, width: 26)
                    }
                }
                if let stake = player.insurance, stake > 0 { Text("Sigorta \(stake)").font(.caption2).foregroundStyle(.white.opacity(0.7)) }
            } else if BlackjackLayout.sittingOut(game, round: round, userID: seat.userId) {
                Text("Bu eli izliyor").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(8)
        .background(Color.black.opacity(acting ? 0.3 : 0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(acting ? Palette.accent.opacity(0.8) : Color.clear, lineWidth: 2))
    }

    @ViewBuilder private func mySpot(_ round: BlackjackRound?) -> some View {
        if let round, let player = round.player(me) {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(player.hands.indices, id: \.self) { index in
                            handView(player.hands[index], index: index, player: player, round: round, width: player.hands.count > 2 ? 44 : 56)
                        }
                    }
                    .padding(.horizontal, 4).padding(.top, 10)
                    .frame(minWidth: 280)
                }
                HStack(spacing: 10) {
                    Text("Sen").font(.subheadline.bold()).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    if let stake = player.insurance, stake > 0 { Text("Sigorta \(stake)").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                    Label("\(player.credits.formatted()) fiş", systemImage: "circle.grid.2x2.fill").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                        .accessibilityLabel("Kalan \(player.credits) sanal fiş")
                }
            }
        } else if context.mySeat != nil, BlackjackLayout.sittingOut(game, round: round, userID: me) {
            Text("Bu eli izliyorsun; sonraki elde oynarsın.").font(.footnote).foregroundStyle(.white.opacity(0.75))
        } else if round == nil {
            Text(game.table.spectatorAccess || context.mySeat != nil ? "Kartlar dağıtılınca eller burada görünür." : "Eli görmek için izleyici ol ya da otur.")
                .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
    }

    /// One hand: overlapping cards, total ("7/17"), bet chips and the outcome badge; the hand in play is outlined.
    private func handView(_ hand: BlackjackRoundHand, index: Int, player: BlackjackRoundPlayer, round: BlackjackRound, width: CGFloat) -> some View {
        let active = round.isActive(player.userId, hand: index)
        let total = BlackjackTotal.label(hand.cards, settled: hand.state != "playing" || round.finished)
        let badge = round.badge(player.userId, hand: index)
        let big = width >= 40
        return VStack(spacing: big ? 6 : 4) {
            if player.hands.count > 1 { Text("El \(index + 1)").font(.caption2.bold()).foregroundStyle(.white.opacity(0.75)) }
            HStack(spacing: -width * 0.5) {
                ForEach(hand.cards) { card in GameCardView(card: card, width: width).transition(cardTransition) }
            }
            .frame(minHeight: width * 1.4)
            HStack(spacing: 4) {
                if !total.isEmpty { totalPill(total, highlight: active) }
                GameChipView(amount: hand.bet, compact: !big)
            }
            if let badge { badgeView(badge, compact: !big).transition(.scale.combined(with: .opacity)) }
        }
        .padding(big ? 8 : 4)
        .background(active ? Palette.accent.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Palette.accent : Color.clear, lineWidth: 2))
        .scaleEffect(active && !reduceMotion ? 1.03 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(handAccessibility(hand, index: index, player: player, total: total, badge: badge, active: active))
    }

    // MARK: Controls

    @ViewBuilder private func controlsArea(_ round: BlackjackRound?, _ controls: BlackjackControls) -> some View {
        switch controls.insurance {
        case .mine(let canTake, let stake):
            insurancePrompt(canTake: canTake, stake: stake)
        case .waiting(let name):
            Label("Sigorta soruluyor · \(name)", systemImage: "shield.lefthalf.filled").font(.footnote)
                .frame(maxWidth: .infinity).padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        case .none:
            EmptyView()
        }
        if controls.showPlay { playButtons(controls) }
        if game.status != .playing {
            if let round, round.finished { summary(round) }
            if controls.rebuy { rebuyPanel() }
            if controls.betting { betPanel(round) }
        }
    }

    private func insurancePrompt(canTake: Bool, stake: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Krupiye As gösteriyor", systemImage: "shield.lefthalf.filled").font(.headline)
            Text("Sigorta \(stake) fiş; krupiyede blackjack çıkarsa 2:1 öder.").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { context.act(.insurance) } label: { Text("Sigorta al").frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.borderedProminent).disabled(!canTake || context.busy)
                Button { context.act(.declineInsurance) } label: { Text("Sigorta alma").frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.bordered).disabled(!context.can(.declineInsurance))
            }
            .font(.headline)
            if !canTake { Text("Sigorta için yeterli fişin yok.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func playButtons(_ controls: BlackjackControls) -> some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                playButton("Kart al", icon: "plus.rectangle.on.rectangle", enabled: controls.hit, prominent: true) { context.act(.hit) }
                playButton("Dur", icon: "hand.raised.fill", enabled: controls.stand, prominent: true) { context.act(.stand) }
                playButton("İkiye katla", icon: "multiply.circle", enabled: controls.double) { context.act(.double) }
                playButton("Ayır", icon: "rectangle.split.2x1", enabled: controls.split) { context.act(.split) }
            }
            if controls.surrender {
                playButton("Teslim ol · bahsin yarısı geri", icon: "flag", enabled: true) { context.act(.surrender) }
            }
        }
    }

    private func playButton(_ title: String, icon: String, enabled: Bool, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent && enabled ? Palette.canvas : Color.white)
        .background(prominent && enabled ? Palette.accent : Palette.raised, in: RoundedRectangle(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    private func summary(_ round: BlackjackRound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("El sonucu").font(.headline)
                Spacer()
                if let dealer = round.dealerTotalLabel { Text("Krupiye \(dealer)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            ForEach(BlackjackSummaryLine.lines(game, round: round, me: me)) { line in
                HStack(spacing: 8) {
                    Text(line.name).font(.subheadline.bold()).lineLimit(1)
                    Text(line.badges.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(line.netText).font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(line.net > 0 ? Color.green : line.net < 0 ? Color.red : Color.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(line.name): \(line.badges.map(\.title).joined(separator: ", ")), net \(line.netText) fiş")
            }
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func betPanel(_ round: BlackjackRound?) -> some View {
        let chips = context.mySeat?.chips ?? 0
        let limit = BlackjackChips.maxBet(chips)
        let lastBet = round?.player(me)?.bet ?? 0
        let valid = Blackjack.validBet(bet, chips: chips)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonraki el bahsi").font(.headline)
                    Text("En fazla \(limit) · \(chips.formatted()) fişin var").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                BlackjackChipStack(amount: bet)
                Text(bet.formatted()).font(.title2.monospacedDigit().bold())
            }
            HStack(spacing: 8) {
                ForEach(BlackjackChips.betButtons, id: \.self) { chip in
                    Button { bet += chip; sentBet = nil } label: {
                        Text("+\(chip)").font(.subheadline.monospacedDigit().bold()).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(context.busy || !BlackjackChips.canAdd(chip, to: bet, chips: chips))
                    .accessibilityLabel("\(chip) fiş ekle")
                }
            }
            HStack(spacing: 8) {
                Button("Temizle") { bet = 0; sentBet = nil }
                    .buttonStyle(.bordered).frame(minHeight: 44).disabled(bet == 0)
                Button("Aynı bahis") { place(lastBet) }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(context.busy || lastBet < 2 || lastBet > limit)
                Button { place(bet) } label: {
                    Text(sentBet == bet ? "Bahis \(bet) · tamam" : "Bahsi belirle").bold().lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas)
                .disabled(context.busy || !valid || sentBet == bet)
            }
            .font(.subheadline)
            if !valid && bet > 0 { Text("Bahis çift sayı olmalı, en az 2 ve fişlerin kadar.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func rebuyPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fişin bitti", systemImage: "circle.slash").font(.headline)
            Text("En küçük bahis 2 fiş. \(BlackjackControls.rebuyAmount) sanal fiş alıp oynamaya devam edebilirsin.").font(.footnote).foregroundStyle(.secondary)
            Button {
                guard let seat = context.mySeat else { return }
                context.move(.sit(seat: seat.seat, buyIn: BlackjackControls.rebuyAmount))
            } label: { Text("Para al").bold().frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).disabled(context.busy)
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func place(_ amount: Int) {
        guard Blackjack.validBet(amount, chips: context.mySeat?.chips ?? 0) else { return }
        bet = amount
        context.act(.bet(amount))
        sentBet = amount
    }

    // MARK: Pieces

    private func rulesStrip(_ rules: BlackjackRules) -> some View {
        let items = ["Krupiye 17’de durur", "Blackjack 3:2 öder", rules.insurance ? "Sigorta 2:1" : "Sigorta kapalı",
                     rules.surrender ? "Teslim açık" : "Teslim kapalı", "El \(BlackjackLayout.handNumber(game))"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { text in
                    Text(text).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface, in: Capsule()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func totalPill(_ text: String, highlight: Bool) -> some View {
        Text(text).font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(highlight ? Palette.accent : Color.black.opacity(0.45), in: Capsule())
            .foregroundStyle(highlight ? Palette.canvas : Color.white)
            .accessibilityLabel("Toplam \(text.replacingOccurrences(of: "/", with: " ya da "))")
    }

    private func badgeView(_ badge: BlackjackBadge, compact: Bool) -> some View {
        let color: Color = badge.positive == true ? .green : badge.positive == false ? .red : .gray
        return Text(badge.title).font((compact ? Font.caption2 : .caption).bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule()).foregroundStyle(.white)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    // MARK: Text

    private func statusText(_ round: BlackjackRound?) -> String {
        guard game.status == .playing, let round, !round.finished else {
            if context.mySeat == nil { return game.status == .playing ? "El sürüyor" : "Sonraki el bekleniyor" }
            return round == nil ? "Bahsini seç; el başlayınca kartlar dağıtılır." : "Sonraki el için bahsini seç"
        }
        let acting = round.actingUserId
        if round.insurancePending {
            return acting == me ? "Sigorta kararı senin" : "Sigorta soruluyor · \(acting.map { context.name(of: $0) } ?? "—")"
        }
        if acting == me, let mine = round.player(me) {
            return mine.hands.count > 1 ? "Sıra sende · El \(mine.activeHand + 1)" : "Sıra sende"
        }
        if let acting { return "\(context.name(of: acting)) oynuyor" }
        return "Krupiye oynuyor"
    }

    private func dealerAccessibility(_ round: BlackjackRound?) -> String {
        guard let round, !round.dealer.isEmpty else { return "Krupiye, kart yok" }
        let cards = round.dealer.map { "\($0.suit.title) \($0.rankLabel)" }.joined(separator: ", ")
        let hidden = round.dealerHiddenCount > 0 ? ", bir kapalı kart" : ""
        return "Krupiye: \(cards)\(hidden), toplam \(round.dealerTotalLabel ?? "")"
    }

    private func handAccessibility(_ hand: BlackjackRoundHand, index: Int, player: BlackjackRoundPlayer, total: String, badge: BlackjackBadge?, active: Bool) -> String {
        var parts = [context.name(of: player.userId)]
        if player.hands.count > 1 { parts.append("El \(index + 1)") }
        parts.append(hand.cards.map { "\($0.suit.title) \($0.rankLabel)" }.joined(separator: ", "))
        parts.append("toplam \(total.replacingOccurrences(of: "/", with: " ya da "))")
        parts.append("bahis \(hand.bet)")
        if let badge { parts.append(badge.title) }
        if active { parts.append("oynanan el") }
        return parts.joined(separator: ", ")
    }

    // MARK: Tracking

    private func initialBet(_ round: BlackjackRound?) -> Int {
        let limit = BlackjackChips.maxBet(context.mySeat?.chips ?? 0)
        let last = round?.player(me)?.bet ?? 0
        return min(last >= 2 ? last : 20, limit)
    }

    /// Names an opponent's last move and plays the table cues; a new round clears the move line.
    private func track(old: BlackjackSnapshot, new: BlackjackSnapshot) {
        guard let next = new.round else { lastMove = nil; return }
        if BlackjackSnapshot.cardCount(next) > BlackjackSnapshot.cardCount(old.round) { GameSounds.play(.deal) }
        if next.finished && old.round?.finished != true {
            GameSounds.play((next.net(me) ?? 0) > 0 ? .win : .end)
            sentBet = nil
            if bet == 0 || bet > BlackjackChips.maxBet(context.mySeat?.chips ?? 0) { bet = initialBet(next) }
        }
        if old.hand != new.hand || old.round?.finished == true || next.finished { lastMove = nil; return }
        if let move = BlackjackMove.moves(from: old.round, to: next).last(where: { $0.userId != me }) {
            lastMove = move.text(context.name(of: move.userId))
        }
    }
}

/// What `onChange` compares: the hand number plus the round view.
private struct BlackjackSnapshot: Equatable {
    let hand: Int
    let round: BlackjackRound?
    /// Cards on the table, so a newly dealt card plays the deal cue.
    static func cardCount(_ round: BlackjackRound?) -> Int {
        guard let round else { return 0 }
        var count = round.dealer.count
        for player in round.players { for hand in player.hands { count += hand.cards.count } }
        return count
    }
}

/// A card that turns over in place when it is revealed (the dealer's hole card). Starts in its current state, so
/// opening the table mid-round animates nothing; Reduce Motion swaps faces without turning.
private struct BlackjackFlipCard: View {
    let card: PlayingCard?
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double

    init(card: PlayingCard?, width: CGFloat) {
        self.card = card
        self.width = width
        _angle = State(initialValue: card == nil ? 180 : 0)
    }

    var body: some View {
        BlackjackFlipFace(angle: angle, card: card, width: width)
            .onChange(of: card) { _, next in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { angle = next == nil ? 180 : 0 }
            }
    }
}

/// Shows the back past 90° so the face appears halfway through the turn.
private struct BlackjackFlipFace: View, Animatable {
    var angle: Double
    let card: PlayingCard?
    let width: CGFloat
    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        let back = angle > 90
        GameCardView(card: back ? nil : card, faceDown: back, width: width)
            .rotation3DEffect(.degrees(back ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    }
}

/// A bet as real chips: one short stack per denomination (500 purple, 100 black, 25 green, 5 red, 1 white).
private struct BlackjackChipStack: View {
    let amount: Int
    private static func color(_ value: Int) -> Color {
        switch value {
        case 500: Color(red: 0.45, green: 0.25, blue: 0.7)
        case 100: Color(white: 0.12)
        case 25: Color(red: 0.1, green: 0.55, blue: 0.3)
        case 5: Color(red: 0.8, green: 0.15, blue: 0.2)
        default: Color(white: 0.92)
        }
    }
    var body: some View {
        let groups = BlackjackChips.breakdown(amount)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(spacing: -12) {
                    ForEach(0..<min(group.count, 5), id: \.self) { _ in
                        Circle().fill(Self.color(group.value))
                            .overlay(Circle().inset(by: 3).strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                    }
                }
            }
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(groups.isEmpty ? "Bahis yok" : groups.map { "\($0.count) adet \($0.value)" }.joined(separator: ", "))
    }
}

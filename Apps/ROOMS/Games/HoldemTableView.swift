import SwiftUI
import RoomsCore

/// Texas Hold’em table: a portrait oval with the board, pots and up to nine seats, the viewer's two cards big at the
/// bottom, and an action bar that offers only what the server lists in `legalActions`. Same information as the desktop
/// `games/holdem/HoldemTable.tsx` (bubbles from `view.log`, side pots, showdown highlight, mucked hands, hand log, buy-in).
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct HoldemTableView: View {
    let context: GameTableContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raiseOpen = false
    @State private var raiseAmount = 0
    @State private var buyIn: HoldemBuyInTarget?
    @State private var logOpen = false

    private var game: GameState { context.game }
    private var hand: HoldemHandView? { game.holdem }
    private var me: String { context.me }
    private var settled: Bool { hand?.ended == true }
    private var bigBlind: Int { max(1, game.table.rules?.bigBlind ?? 20) }

    var body: some View {
        // `view(as:)` re-encodes the view: read it once per render.
        let extras = game.view(as: HoldemViewExtras.self) ?? .empty
        VStack(spacing: 0) {
            table(extras).frame(minHeight: 230, maxHeight: .infinity)
            bottomPanel(extras).layoutPriority(1)
        }
        .sheet(isPresented: $raiseOpen) {
            if let raise = hand?.raise(for: me) {
                HoldemRaiseSheet(raise: raise, step: bigBlind, amount: $raiseAmount, enabled: context.can(.raise)) { total in
                    raiseOpen = false
                    context.act(.raise(to: raise.clamp(total)))
                }
                .presentationDetents([.height(raise.allInOnly ? 260 : 400)])
            }
        }
        .sheet(item: $buyIn) { target in
            if let range = HoldemBuyIn.range(game.table.rules) {
                HoldemBuyInSheet(target: target, range: range, initial: HoldemBuyIn.initial(game.table.rules) ?? range.lowerBound, step: bigBlind,
                                 chips: context.mySeat?.chips ?? 0, playing: game.status == .playing, busy: context.busy) { amount in
                    buyIn = nil
                    context.move(.sit(seat: target.seat, buyIn: amount))
                }
                .presentationDetents([.height(340)])
            }
        }
        // A new turn, street or hand starts the raise at the minimum; a turn that ends closes the sheet.
        .onChange(of: turnKey) { _, _ in
            raiseAmount = 0
            if !context.myTurn { raiseOpen = false }
        }
    }

    private var turnKey: String { "\(game.history.count):\(hand?.stage ?? "-"):\(game.turn ?? -1):\(hand?.maximumBet ?? 0)" }

    // MARK: Table

    private func table(_ extras: HoldemViewExtras) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Seat chips are about 76 × 64 pt; leave room for half a chip plus the bubble above the top seat.
            let radius = CGSize(width: max(60, size.width / 2 - 40), height: max(70, size.height / 2 - 48))
            let own = context.mySeat?.seat
            let capacity = min(9, max(2, game.capacity))
            let bubbles = extras.lastActions(stage: hand?.stage ?? "")
            let blinds = extras.blinds
            let winning = hand?.winningCardIDs ?? []
            let point = { (seat: Int, scale: CGFloat) -> CGPoint in
                let unit = HoldemSeatLayout.point(capacity: capacity, seat: seat, ownSeat: own)
                return CGPoint(x: center.x + radius.width * scale * unit.x, y: center.y + radius.height * scale * unit.y)
            }
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 0.1, green: 0.42, blue: 0.27), Color(red: 0.04, green: 0.25, blue: 0.16)],
                                         center: .center, startRadius: 10, endRadius: max(size.width, size.height) / 2))
                    .overlay(Ellipse().strokeBorder(Color(red: 0.36, green: 0.22, blue: 0.12), lineWidth: 10))
                    .frame(width: max(0, radius.width * 2 - 10), height: max(0, radius.height * 2 - 10))
                    .position(center)
                    .accessibilityHidden(true)

                centre(extras, width: radius.width * 1.45).position(center)

                // This street's bets in front of the seats.
                if let hand, !hand.ended {
                    ForEach(hand.seats.filter { $0.streetBet > 0 }) { player in
                        if let seat = game.seat(of: player.userId) {
                            GameChipView(amount: player.streetBet, compact: true)
                                .position(point(seat.seat, 0.62))
                                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                        }
                    }
                }

                ForEach(HoldemSeatLayout.order(capacity: capacity, ownSeat: own), id: \.self) { number in
                    Group {
                        if let seat = game.seats.first(where: { $0.seat == number }) {
                            HoldemSeatChip(seat: seat, player: hand?.player(seat.userId), hand: hand, game: game, chat: context.chat, me: me,
                                           bubble: bubbles[seat.userId], dealer: hand?.buttonUserID == seat.userId,
                                           smallBlind: !settled && blinds.small == seat.userId, bigBlind: !settled && blinds.big == seat.userId,
                                           mucked: extras.mucked.contains(seat.userId), winning: winning)
                        } else {
                            emptySeat(number)
                        }
                    }
                    .position(point(number, 1))
                }
            }
            // Sizes are tied to the oval's geometry; text in the bottom panel keeps scaling with Dynamic Type.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: hand?.seats.map(\.streetBet))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: extras.log.count)
        }
    }

    private func centre(_ extras: HoldemViewExtras, width: CGFloat) -> some View {
        let board = hand?.board ?? []
        let winning = hand?.winningCardIDs ?? []
        let cardWidth = min(38, max(26, (width - 16) / 5.4))
        return VStack(spacing: 6) {
            if let hand {
                Text(HoldemStreet.title(hand.stage) + (hand.ended && extras.runoutFrom != nil ? " · All-in, kalan kartlar açıldı" : ""))
                    .font(.caption2.bold()).foregroundStyle(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(game.status == .playing ? "El sürüyor" : "El dağıtılmadı").font(.caption2.bold()).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 4) {
                ForEach(board) { card in
                    GameCardView(card: card, width: cardWidth, dimmed: !winning.isEmpty && !winning.contains(card.id))
                        .overlay(RoundedRectangle(cornerRadius: cardWidth * 0.12).strokeBorder(Color.yellow, lineWidth: winning.contains(card.id) ? 2.5 : 0))
                        .transition(reduceMotion ? .opacity : .modifier(active: HoldemFlip(angle: -90), identity: HoldemFlip(angle: 0)))
                }
                ForEach(min(5, board.count)..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: cardWidth * 0.12)
                        .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: cardWidth, height: cardWidth * 1.4)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: board.map(\.id))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Ortadaki kartlar")
            if let hand {
                let pot = hand.potOrContributions
                HStack(spacing: 6) {
                    GameChipView(amount: pot)
                    Text("pot").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                .animation(reduceMotion ? nil : .easeOut, value: pot)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pot \(pot) sanal fiş")
                if hand.pots.count > 1 || hand.ended {
                    VStack(spacing: 2) {
                        ForEach(Array(hand.pots.enumerated()), id: \.offset) { index, pot in
                            Text(pot.label(index: index) { context.name(of: $0) })
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(pot.isSide ? Color.yellow.opacity(0.9) : Color.white.opacity(0.85))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Color.white.opacity(pot.isSide ? 0.4 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: width)
    }

    @ViewBuilder private func emptySeat(_ number: Int) -> some View {
        let seated = context.mySeat != nil
        Button {
            GameHaptics.tap()
            if let range = HoldemBuyIn.range(game.table.rules), range.lowerBound < range.upperBound {
                buyIn = HoldemBuyInTarget(seat: number, rebuy: false)
            } else {
                // A fixed buy-in: the service seats with the table's starting stack.
                context.move(.sit(seat: number))
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "plus.circle").font(.title3)
                Text("Boş koltuk").font(.caption2)
            }
            .foregroundStyle(Color.white.opacity(seated ? 0.35 : 0.85))
            .frame(width: 72, height: 56)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(seated || context.busy)
        .accessibilityLabel("Koltuk \(number + 1), boş")
        .accessibilityHint(seated ? "Zaten masadasın" : game.status == .playing ? "Oturursan sonraki elde oynarsın" : "Bu koltuğa otur")
    }

    // MARK: Bottom

    private func bottomPanel(_ extras: HoldemViewExtras) -> some View {
        let mine = hand?.player(me)
        let winning = hand?.winningCardIDs ?? []
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(mine)).font(.headline).lineLimit(2)
                    if let line = subline(mine, extras) {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let mine, !mine.cards.isEmpty {
                HStack(spacing: 10) {
                    ForEach(mine.cards) { card in
                        GameCardView(card: card, width: 64, dimmed: mine.folded || (!winning.isEmpty && !winning.contains(card.id)))
                            .overlay(RoundedRectangle(cornerRadius: 64 * 0.12).strokeBorder(Color.yellow, lineWidth: winning.contains(card.id) ? 3 : 0))
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.4), value: mine.cards.map(\.id))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Senin kartların")
            } else if context.spectator {
                Label("İzleyicisin · gizli kartlar gösterilmez", systemImage: "eye").font(.footnote).foregroundStyle(.secondary)
            }

            if let hand, context.myTurn, game.status == .playing, !hand.ended { actionBar(hand) }

            if let own = context.mySeat, HoldemBuyIn.canRebuy(chips: own.chips, rules: game.table.rules, status: game.status),
               let range = HoldemBuyIn.range(game.table.rules) {
                Button {
                    GameHaptics.tap()
                    if range.lowerBound < range.upperBound { buyIn = HoldemBuyInTarget(seat: own.seat, rebuy: true) }
                    else { context.move(.sit(seat: own.seat, buyIn: range.lowerBound)) }
                } label: {
                    Label(range.lowerBound < range.upperBound ? "Fiş al" : "Fiş al · \(range.lowerBound.formatted())", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(context.busy)
                .accessibilityHint("Yığının en düşük girişin altında; sonraki elden önce sanal fiş ekler.")
            }

            if !extras.log.isEmpty { handLog(extras) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.surface)
    }

    private func headline(_ mine: HoldemSeatView?) -> String {
        guard let hand else { return context.spectator ? "Masayı izliyorsun" : "El bekleniyor" }
        if hand.ended {
            if hand.splitPot { return "Pot paylaşıldı" }
            return hand.paidPlayers.count > 1 ? "Potlar dağıtıldı" : "El tamamlandı"
        }
        if let mine {
            if mine.folded { return "Bu eli bıraktın" }
            if mine.chips == 0 { return "Bütün fişlerin masada" }
        }
        if context.myTurn { return "Sıra sende" }
        if let turn = game.turnSeat { return "\(context.name(of: turn.userId)) bekleniyor" }
        return "El devam ediyor"
    }

    private func subline(_ mine: HoldemSeatView?, _ extras: HoldemViewExtras) -> String? {
        guard let hand else {
            if let own = context.mySeat { return "Yığının: \(own.chips.formatted()) fiş" }
            return nil
        }
        if hand.ended {
            var parts = hand.paidPlayers.map { paid in
                "\(context.name(of: paid.userId)) · \(paid.amount.formatted()) fiş" + (hand.showdown?[paid.userId].map { " · \($0.title)" } ?? "")
            }
            if hand.settlementReason == "uncontested" { parts.append("Herkes bıraktı, kartlar açılmadı") }
            return parts.isEmpty ? "Sonuç ayrıntısı bu yanıtta yok." : parts.joined(separator: " / ")
        }
        guard let mine else { return nil }
        return "Kalan fişin: \(mine.chips.formatted())" + (hand.ownHand.map { " · \($0.title)" } ?? "")
    }

    private func actionBar(_ hand: HoldemHandView) -> some View {
        let raise = hand.raise(for: me)
        let bar = HoldemActionBar(legalActions: game.table.legalActions, busy: context.busy, callAmount: hand.callAmount(me),
                                  stack: hand.player(me)?.chips ?? 0, canRaise: raise != nil)
        return HStack(spacing: 8) {
            Button(role: .destructive) { context.act(.fold) } label: {
                Text("Bırak").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(!bar.fold)
            Button {
                switch bar.middle {
                case .check: context.act(.check)
                case .call: context.act(.call)
                case .none: break
                }
            } label: {
                Text(bar.middleTitle).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(!bar.middleEnabled)
            Button {
                guard let raise else { return }
                GameHaptics.tap()
                raiseAmount = raise.clamp(raiseAmount == 0 ? raise.range.lowerBound : raiseAmount)
                raiseOpen = true
            } label: {
                Text(raise?.allInOnly == true ? "All-in" : "Artır").bold().frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Palette.canvas)
            .disabled(!bar.raise)
        }
        .font(.body.bold())
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func handLog(_ extras: HoldemViewExtras) -> some View {
        DisclosureGroup(isExpanded: $logOpen) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(extras.log.enumerated()), id: \.offset) { index, entry in
                        if index == 0 || extras.log[index - 1].street != entry.street {
                            Text(HoldemStreet.title(entry.street)).font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 4)
                        }
                        Text(entry.line(name: context.name(of: entry.userId))).font(.caption.monospacedDigit())
                    }
                    ForEach(extras.mucked, id: \.self) { userID in
                        Text("\(context.name(of: userID)) · Kartını açmadı").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        } label: {
            Text("Bu elin hamleleri · \(extras.log.count)").font(.footnote.bold())
        }
    }
}

// MARK: - Seat

/// A compact seat around the oval: avatar with a turn ring, name, stack, D/SB/BB markers, the last action bubble,
/// the cards (backs while hidden, faces at showdown) and a status line.
private struct HoldemSeatChip: View {
    let seat: GameSeat
    let player: HoldemSeatView?
    let hand: HoldemHandView?
    let game: GameState
    let chat: ChatController
    let me: String
    let bubble: HoldemLogEntry?
    let dealer: Bool
    let smallBlind: Bool
    let bigBlind: Bool
    let mucked: Bool
    let winning: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOwn: Bool { seat.userId == me }
    private var isTurn: Bool { game.status == .playing && game.turn == seat.seat }
    private var folded: Bool { player?.folded == true }
    private var stack: Int { player?.chips ?? seat.chips }
    private var status: String {
        HoldemSeatStatus.text(seat: seat, player: player, hand: hand, mucked: mucked ? [seat.userId] : [], me: me, turn: game.turn)
    }
    private var winner: Bool { (hand?.payouts[seat.userId] ?? 0) > 0 && hand?.ended == true }

    /// The line under the name: the stack (with blinds) unless something matters more (fold, all-in, result).
    private var showsStatus: Bool { !["Masada", "Sırada", "Sıra sende"].contains(status) }

    var body: some View {
        // About 64 × 76 pt so nine seats fit around a phone-sized oval; the bubble floats above without taking a row.
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if seat.isBotSeat {
                            Circle().fill(Palette.raised).overlay(Image(systemName: "cpu").font(.system(size: 12))).frame(width: 28, height: 28)
                        } else {
                            ChatAvatarView(chat: chat, userID: seat.userId, name: seat.name, size: 28)
                        }
                    }
                    .overlay(Circle().strokeBorder(isTurn ? Palette.accent : Color.clear, lineWidth: 3).padding(-3))
                    if dealer { marker("D", fill: Color.white, foreground: Color.black).offset(x: 8, y: -6) }
                }
                .opacity(seat.connected ? 1 : 0.5)
                cards
            }
            Text(isOwn ? "Sen" : seat.name).font(.caption2.bold()).lineLimit(1)
            if showsStatus {
                Text(status).font(.caption2)
                    .foregroundStyle(winner ? Color.yellow : Color.white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else {
                HStack(spacing: 2) {
                    Text(stack.formatted()).font(.caption2.monospacedDigit()).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                    if smallBlind { marker("SB", fill: Color.blue.opacity(0.8), foreground: Color.white) }
                    if bigBlind { marker("BB", fill: Color.orange.opacity(0.9), foreground: Color.white) }
                }
            }
        }
        .frame(maxWidth: 70)
        .padding(.horizontal, 3).padding(.vertical, 3)
        .background(Color.black.opacity(isTurn ? 0.5 : 0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isTurn ? Palette.accent : winner ? Color.yellow : Color.clear, lineWidth: 1.5))
        .opacity(folded ? 0.55 : 1)
        .overlay(alignment: .top) {
            if let bubble {
                Text(bubble.label).font(.caption2.bold()).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(bubbleColor(bubble), in: Capsule())
                    .foregroundStyle(Color.white)
                    .offset(y: -14)
                    .id("\(bubble.street)-\(bubble.action)-\(bubble.to)")
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: bubble)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Others' cards beside the avatar: backs while hidden, faces when the server reveals them at showdown. The
    /// viewer's own cards are big at the bottom of the screen instead.
    @ViewBuilder private var cards: some View {
        if let player, !isOwn, !folded, !player.cards.isEmpty || player.hiddenCardCount > 0 {
            HStack(spacing: -7) {
                if !player.cards.isEmpty {
                    ForEach(player.cards) { card in
                        GameCardView(card: card, width: 22, dimmed: !winning.isEmpty && !winning.contains(card.id))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.yellow, lineWidth: winning.contains(card.id) ? 1.5 : 0))
                    }
                } else {
                    ForEach(0..<min(2, player.hiddenCardCount), id: \.self) { _ in GameCardView(card: nil, faceDown: true, width: 16) }
                }
            }
        }
    }

    private func marker(_ text: String, fill: Color, foreground: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .heavy)).foregroundStyle(foreground)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(fill, in: Capsule())
            .accessibilityHidden(true)
    }

    private func bubbleColor(_ entry: HoldemLogEntry) -> Color {
        if entry.allIn && entry.action != "fold" && entry.action != "check" { return Color.red.opacity(0.85) }
        switch entry.action {
        case "fold": return Color.gray.opacity(0.8)
        case "raise": return Color.orange.opacity(0.9)
        case "call": return Color.blue.opacity(0.8)
        default: return Color.black.opacity(0.6)
        }
    }

    private var accessibilityText: String {
        var parts = [isOwn ? "Sen" : seat.name, "\(stack) fiş"]
        if seat.isBotSeat || seat.bot { parts.append("bot") }
        if dealer { parts.append("krupiye") }
        if smallBlind { parts.append("küçük kör") }
        if bigBlind { parts.append("büyük kör") }
        if let bubble { parts.append("son hamle \(bubble.label)") }
        if let player, !isOwn, !player.cards.isEmpty { parts.append(player.cards.map { "\($0.suit.title) \($0.rankLabel)" }.joined(separator: ", ")) }
        if status != "Masada" { parts.append(status) }
        if isTurn { parts.append("sıra onda") }
        return parts.joined(separator: ", ")
    }
}

/// A card turning face up as it lands on the board.
private struct HoldemFlip: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(angle == 0 ? 1 : 0.2)
    }
}

// MARK: - Raise sheet

/// Raise amount as a street total: slider and −/+ inside the server's range, presets (Min, ½ Pot, Pot, All-in)
/// already clamped. A short stack only sees All-in.
private struct HoldemRaiseSheet: View {
    let raise: HoldemRaise
    let step: Int
    @Binding var amount: Int
    let enabled: Bool
    let confirm: @MainActor (Int) -> Void

    private var value: Binding<Double> {
        Binding(get: { Double(raise.clamp(amount)) }, set: { amount = raise.clamp(Int($0.rounded())) })
    }
    private var total: Int { raise.allInOnly ? raise.allIn : raise.clamp(amount) }

    var body: some View {
        VStack(spacing: 14) {
            Text(raise.allInOnly ? "All-in" : "Artır").font(.headline)
            Text(total.formatted()).font(.largeTitle.monospacedDigit().bold())
                .accessibilityLabel("Bu turdaki toplam tutarın \(total) fiş")
            if raise.allInOnly {
                Text("Minimum artırma için yeterli fişin yok; yalnızca all-in olabilirsin.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                HStack(spacing: 10) {
                    Button { amount = raise.clamp(total - step) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                        .buttonStyle(.bordered).accessibilityLabel("Azalt")
                    Slider(value: value, in: Double(raise.range.lowerBound)...Double(raise.range.upperBound))
                        .accessibilityLabel("Artırma tutarı")
                        .accessibilityValue("\(total) fiş")
                    Button { amount = raise.clamp(total + step) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .buttonStyle(.bordered).accessibilityLabel("Arttır")
                }
                HStack(spacing: 6) {
                    ForEach(raise.presets) { preset in
                        Button { amount = preset.amount } label: {
                            VStack(spacing: 1) {
                                Text(preset.title).font(.caption.bold())
                                Text(preset.amount.formatted()).font(.caption2.monospacedDigit())
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(total == preset.amount ? Palette.accent : nil)
                        .accessibilityLabel("\(preset.title), \(preset.amount) fiş")
                    }
                }
                Text("En az \(raise.range.lowerBound.formatted()), en çok \(raise.range.upperBound.formatted()) · bu turdaki toplam tutarın")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button { confirm(total) } label: {
                Text(raise.confirmTitle(total)).bold().frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Palette.canvas)
            .disabled(!enabled)
        }
        .padding(20)
    }
}

// MARK: - Buy-in

private struct HoldemBuyInTarget: Identifiable {
    let seat: Int
    /// Topping up the own seat (stack below the minimum), not taking a free one.
    let rebuy: Bool
    var id: Int { seat }
}

/// Virtual chips for a free seat or a rebuy, inside the table's buy-in range (never real money).
private struct HoldemBuyInSheet: View {
    let target: HoldemBuyInTarget
    let range: ClosedRange<Int>
    let initial: Int
    let step: Int
    let chips: Int
    let playing: Bool
    let busy: Bool
    let confirm: @MainActor (Int) -> Void
    @State private var amount = 0

    private func clamp(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }
    private var value: Binding<Double> { Binding(get: { Double(clamp(amount)) }, set: { amount = clamp(Int($0.rounded())) }) }

    var body: some View {
        VStack(spacing: 14) {
            Label(target.rebuy ? "Fiş al" : "Koltuk \(target.seat + 1)", systemImage: "circle.hexagongrid.fill").font(.headline)
            Text("\(clamp(amount).formatted()) sanal fiş").font(.title.monospacedDigit().bold())
            HStack(spacing: 10) {
                Button { amount = clamp(clamp(amount) - step) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                    .buttonStyle(.bordered).accessibilityLabel("Azalt")
                Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound))
                    .accessibilityLabel("Giriş miktarı")
                    .accessibilityValue("\(clamp(amount)) sanal fiş")
                Button { amount = clamp(clamp(amount) + step) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .buttonStyle(.bordered).accessibilityLabel("Arttır")
            }
            Group {
                if target.rebuy {
                    Text("Yeni yığının \(min(range.upperBound, chips + clamp(amount)).formatted()) olur (en çok \(range.upperBound.formatted())).")
                } else {
                    Text("\(range.lowerBound.formatted()) – \(range.upperBound.formatted()) sanal fiş" + (playing ? " · Bu el dağıtıldı, sonraki elde oynayacaksın." : ""))
                }
            }
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { confirm(clamp(amount)) } label: {
                Text(target.rebuy ? "Fiş al" : "Otur").bold().frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Palette.canvas)
            .disabled(busy)
        }
        .padding(20)
        .onAppear { amount = clamp(target.rebuy ? range.lowerBound : initial) }
    }
}

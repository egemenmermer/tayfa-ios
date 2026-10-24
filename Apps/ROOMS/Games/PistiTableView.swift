import SwiftUI
import UIKit
import RoomsCore

/// Pişti table (`rooms-pisti-v1`), portrait: opponent(s) at the top (the partner across in 4 players), the pile in the
/// centre with its top card face up, your four cards at the bottom as large tappable cards, the deck, each side's
/// captured stack, a PİŞTİ! / VALE PİŞTİ! moment, the line for the last move, the deal summary and the match
/// progress. Everything is read through `GamesPisti.swift` (`PistiView`); moves go out as `GameMove.pistiPlay`.
/// The host already draws the header (seats, turn clock), banners, errors, leave and rematch.
struct PistiTableView: View {
    let context: GameTableContext
    var body: some View {
        if let view = context.game.pistiView {
            // A rematch is a new history entry: its event baseline, summary and moment start afresh.
            PistiBoard(context: context, view: view).id(context.game.history.count)
        } else {
            ContentUnavailableView {
                Label(context.game.table.spectatorAccess ? "Kartlar dağıtılıyor" : "Masa gizli", systemImage: "suit.diamond.fill")
            } description: {
                Text(context.game.table.spectatorAccess ? "Masa kurulunca kartlar burada görünür." : "Masayı görmek için izleyici olarak katıl ya da boş bir koltuğa otur.")
            }
        }
    }
}

// MARK: - Board

private struct PistiBoard: View {
    let context: GameTableContext
    let view: PistiView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracker = PistiEventTracker()
    @State private var moment: PistiTableEvent?
    @State private var sweep: PistiTableEvent?
    @State private var summaryOpen = false

    private var game: GameState { context.game }
    private var series: GameSeries? { game.table.series }
    private var finished: Bool { series?.finished == true || game.status == .finished }
    private var eventKey: String { "\(series?.rounds.count ?? 0):\(view.lastPlay?.seq ?? 0)" }
    private func name(_ round: Int) -> String { game.pistiName(round: round, me: context.me) }
    /// The deal that just ended (the next one is already dealt) and its points.
    private var previousDeal: (view: PistiView, points: [Int])? {
        guard !finished, let previous = series?.pistiPrevious, let points = series?.rounds.last?.points else { return nil }
        return (previous, points)
    }

    var body: some View {
        GeometryReader { proxy in
            // The felt scrolls (small phones, large Dynamic Type, spectator seat picker above); the hand stays pinned below it.
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 10) {
                        PistiMatchBar(context: context, view: view, series: series, finished: finished,
                                      onPrevious: previousDeal == nil ? nil : { summaryOpen.toggle() })
                        felt(width: proxy.size.width)
                        if finished { PistiMatchEnd(context: context, view: view, series: series) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                if !finished { handArea(width: proxy.size.width) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .overlay { if summaryOpen, let previous = previousDeal { summaryPanel(previous) } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summaryOpen)
        .onAppear { _ = tracker.observe(view, series: series) }
        .onChange(of: eventKey) { _, _ in if let event = tracker.observe(view, series: series) { handle(event) } }
        .task(id: moment?.id) {
            guard moment != nil else { return }
            try? await Task.sleep(for: .milliseconds(1800))
            if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { moment = nil } }
        }
        .task(id: sweep?.id) {
            guard sweep != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeIn(duration: 0.35)) { sweep = nil } }
        }
    }

    // MARK: Events

    private func handle(_ event: PistiTableEvent) {
        let mine = game.pistiSeat(round: event.round)?.userId == context.me
        if event.isPisti {
            moment = event
            if mine { UINotificationFeedbackGenerator().notificationOccurred(.success) } else { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
            GameSounds.play(.capture)
        } else {
            GameSounds.play(event.kind == .play ? .play : .capture)
        }
        if event.kind != .play { sweep = event }
        if event.dealEnded, !finished, previousDeal != nil { summaryOpen = true }
        let source = event.dealEnded ? (series?.pistiPrevious ?? view) : view
        AccessibilityNotification.Announcement(PistiNarration.lastLine(source, game: game, me: context.me)).post()
    }

    // MARK: Felt

    private func felt(width: CGFloat) -> some View {
        let cardWidth = min(72, max(52, (width - 24 - 40) / 5))
        let away = (view.homeSide + 1) % view.sideCount
        let line = PistiNarration.lastLine(view, game: game, me: context.me)
        return VStack(spacing: 8) {
            if let top = view.round(at: .top) { PistiSeatView(context: context, view: view, round: top) }
            HStack(alignment: .center, spacing: 6) {
                if let left = view.round(at: .left) { PistiSeatView(context: context, view: view, round: left).frame(maxWidth: 84) }
                PistiCenter(view: view, cardWidth: cardWidth, sweep: sweep, reduceMotion: reduceMotion)
                if let right = view.round(at: .right) { PistiSeatView(context: context, view: view, round: right).frame(maxWidth: 84) }
            }
            Text(line)
                .font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
            HStack(spacing: 8) {
                PistiCaptured(view: view, side: view.homeSide, name: game.pistiSideName(view, side: view.homeSide, me: context.me))
                if view.sideCount > 1 {
                    PistiCaptured(view: view, side: away, name: game.pistiSideName(view, side: away, me: context.me))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.33, blue: 0.22), Color(red: 0.04, green: 0.22, blue: 0.15)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12)))
        .overlay {
            if let moment {
                PistiMoment(event: moment, name: name(moment.round)).transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: moment?.id)
    }

    // MARK: Hand

    private func handArea(width: CGFloat) -> some View {
        let cards = view.handCards(canPlay: context.can("play"))
        let cardWidth = min(80, max(56, (width - 24 - 3 * 10) / 4))
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(turnLine).font(.subheadline.weight(.bold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if view.turn != nil { GameTurnClock(game: game, serverOffsetMs: context.serverOffsetMs) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(view.viewerToPlay ? Palette.accent.opacity(0.22) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            if context.spectator {
                Text("İzliyorsun. Kartlar oyunculara özel.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: cardWidth * 0.7)
            } else if cards.isEmpty {
                Text("Yeni kartlar dağıtılıyor.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: cardWidth * 0.7)
            } else {
                HStack(spacing: 10) {
                    ForEach(cards) { item in
                        Button { context.move(GameMove.pistiPlay(cardID: item.card.id)) } label: {
                            GameCardView(card: item.card, width: cardWidth, selected: item.takes, dimmed: !item.playable)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.playable)
                        .accessibilityHint(item.playable ? (item.takes ? "Çift dokun: oyna. Yerdeki kartları alır." : "Çift dokun: oyna.") : "")
                    }
                }
                .padding(.top, cardWidth * 0.2)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cards.map(\.takes))
            }
        }
    }

    private var turnLine: String {
        if context.spectator, let turn = view.turn { return "İzliyorsun · \(name(turn)) oynuyor" }
        if view.viewerToPlay { return "Sıra sende · bir kart at" }
        if let turn = view.turn { return "\(name(turn)) oynuyor" }
        return "El tamamlandı"
    }

    // MARK: Summary

    private func summaryPanel(_ previous: (view: PistiView, points: [Int])) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { summaryOpen = false }
            VStack(spacing: 12) {
                Text("El \(series?.rounds.count ?? 0) bitti").font(.headline)
                PistiSummaryGrid(game: game, me: context.me, view: previous.view, points: previous.points)
                Button("Kapat") { summaryOpen = false }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).frame(minHeight: 44)
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.separator))
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Match bar

/// Match target, hand number and each side's progress to the target.
private struct PistiMatchBar: View {
    let context: GameTableContext
    let view: PistiView
    let series: GameSeries?
    let finished: Bool
    let onPrevious: (() -> Void)?

    var body: some View {
        let hand = (series?.rounds.count ?? 0) + (finished ? 0 : 1)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Maç \(view.target) puan").font(.caption.weight(.bold))
                Text("El \(hand)").font(.caption).foregroundStyle(.secondary)
                if view.teams { Text("Eşli · karşılıklı").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let onPrevious {
                    Button("Önceki el özeti", action: onPrevious).font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
            }
            ForEach(view.standings(series: series)) { standing in
                let name = context.game.pistiSideName(view, side: standing.side, me: context.me)
                VStack(spacing: 3) {
                    HStack {
                        Text(name).font(.caption.weight(standing.own ? .bold : .regular)).lineLimit(1)
                        if standing.winner { Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow) }
                        Spacer(minLength: 4)
                        Text("\(standing.total) / \(standing.target)").font(.caption.monospacedDigit().bold())
                    }
                    ProgressView(value: standing.progress).tint(standing.own ? Palette.accent : Color.gray)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(standing.total) puan, hedef \(standing.target)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Seats

/// An opponent or partner: avatar with the turn ring, name, role and card count, and a small fan of card backs.
private struct PistiSeatView: View {
    let context: GameTableContext
    let view: PistiView
    let round: Int

    var body: some View {
        let count = view.handCount(round: round)
        let role: String? = view.isPartner(round: round) ? "Eşin" : view.teams ? "Takım \(view.side(ofRound: round) + 1)" : nil
        let isTurn = view.turn == round && view.result == nil
        VStack(spacing: 4) {
            if let seat = context.game.pistiSeat(round: round) {
                GameSeatBadge(seat: seat, game: context.game, chat: context.chat, me: context.me, size: 40)
            } else {
                Image(systemName: "person.crop.circle").font(.largeTitle).foregroundStyle(.secondary)
            }
            Text([role, "\(count) kart"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: -14) {
                ForEach(0..<min(count, 4), id: \.self) { _ in GameCardView(card: nil, faceDown: true, width: 24) }
            }.frame(height: 34)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isTurn ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context.game.pistiName(round: round, me: context.me)), \(role.map { $0 + ", " } ?? "")\(count) kart\(isTurn ? ", sıra onda" : "")")
    }
}

// MARK: - Centre: deck and pile

private struct PistiCenter: View {
    let view: PistiView
    let cardWidth: CGFloat
    let sweep: PistiTableEvent?
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            deck
            pile
        }
        .frame(maxWidth: .infinity)
    }

    private var deck: some View {
        let small = cardWidth * 0.62
        return VStack(spacing: 4) {
            ZStack {
                if view.deckCount > 0 {
                    ForEach(0..<min(5, Int((Double(view.deckCount) / 8).rounded(.up))), id: \.self) { i in
                        GameCardView(card: nil, faceDown: true, width: small).offset(x: CGFloat(i) * 1.5, y: -CGFloat(i) * 1.5)
                    }
                } else {
                    RoundedRectangle(cornerRadius: small * 0.12).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: small, height: small * 1.4)
                }
            }
            .frame(width: small + 10, height: small * 1.4 + 8)
            Text(view.deckCount > 0 ? "Deste \(view.deckCount)" : "Deste bitti").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(view.deckCount > 0 ? "Destede \(view.deckCount) kart" : "Deste bitti")
    }

    /// Layered backs hint the pile's thickness; only the top card is face up.
    private var pile: some View {
        let layers = min(max(0, view.tableCount - 1), 6)
        let slide = layers == 0 ? CGSize.zero : CGSize(width: CGFloat(layers) * 1.6, height: -CGFloat(layers) * 2)
        return VStack(spacing: 4) {
            ZStack {
                ForEach(0..<layers, id: \.self) { i in
                    GameCardView(card: nil, faceDown: true, width: cardWidth).offset(x: CGFloat(i) * 1.6, y: -CGFloat(i) * 2)
                }
                if let top = view.tableTop {
                    GameCardView(card: top, width: cardWidth)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .offset(slide)
                        .id(top.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(Self.travel(flyFrom)).combined(with: .opacity), removal: .opacity))
                } else {
                    RoundedRectangle(cornerRadius: cardWidth * 0.12).strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: cardWidth, height: cardWidth * 1.4)
                        .overlay(Text("Yer boş").font(.caption2).foregroundStyle(.white.opacity(0.7)))
                }
                if let sweep {
                    ZStack(alignment: .topTrailing) {
                        GameCardView(card: sweep.kind == .remainder ? nil : sweep.card, faceDown: sweep.kind == .remainder, width: cardWidth)
                        Text("\(sweep.count)").font(.caption.bold()).padding(5).background(Palette.accent, in: Circle()).foregroundStyle(Palette.canvas).offset(x: 8, y: -8)
                    }
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .offset(Self.travel(view.position(ofRound: sweep.round), far: true)).combined(with: .opacity)))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: view.tableTop?.id)
            .frame(width: cardWidth + 16, height: cardWidth * 1.4 + 16)
            Text(view.tableCount > 0 ? "Yerde \(view.tableCount) kart" : "Yer boş").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(view.tableTop.map { "Yerde \(view.tableCount) kart, üstte \($0.pistiName)" } ?? "Yer boş")
    }

    /// Where the top card was thrown from: the last play, when it stayed on the table.
    private var flyFrom: PistiPosition? {
        guard let play = view.lastPlay, !play.captured else { return nil }
        return view.position(ofRound: play.seat)
    }

    /// Offset of a seat from the centre of the pile: where a card comes from, or where the swept pile goes.
    private static func travel(_ position: PistiPosition?, far: Bool = false) -> CGSize {
        let d: CGFloat = far ? 170 : 110
        switch position {
        case .top?: return CGSize(width: 0, height: -d)
        case .left?: return CGSize(width: -d, height: 0)
        case .right?: return CGSize(width: d, height: 0)
        case .bottom?: return CGSize(width: 0, height: d)
        case nil: return .zero
        }
    }
}

// MARK: - Captured stacks

private struct PistiCaptured: View {
    let view: PistiView
    let side: Int
    let name: String

    var body: some View {
        let count = view.captured(side: side)
        let pisti = view.pistiCount(side: side)
        HStack(spacing: 8) {
            ZStack {
                ForEach(0..<min(5, Int((Double(count) / 6).rounded(.up))), id: \.self) { i in
                    GameCardView(card: nil, faceDown: true, width: 24).offset(x: CGFloat(i) * 2, y: -CGFloat(i) * 1.5)
                }
            }.frame(width: 34, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption2.weight(.semibold)).lineLimit(1)
                Text("\(count) kart" + (pisti > 0 ? " · \(pisti) pişti" : "")).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) kart aldı\(pisti > 0 ? ", \(pisti) pişti" : "")")
    }
}

// MARK: - PİŞTİ! moment

private struct PistiMoment: View {
    let event: PistiTableEvent
    let name: String
    var body: some View {
        let jack = event.kind == .jackPisti
        VStack(spacing: 4) {
            Text(jack ? "VALE PİŞTİ!" : "PİŞTİ!")
                .font(.system(size: 52, weight: .black, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
            Text("\(name) · +\(event.bonus)").font(.headline).foregroundStyle(.white)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(jack ? "\(name) vale pişti yaptı, artı 20" : "\(name) pişti yaptı, artı 10")
    }
}

// MARK: - Summary and match end

/// "Puan dökümü": cards, most cards, pişti, vale pişti and card points per side for one finished deal.
private struct PistiSummaryGrid: View {
    let game: GameState
    let me: String
    let view: PistiView
    let points: [Int]

    var body: some View {
        let rows = view.summary(points: points)
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Puan dökümü").font(.caption.bold()).gridColumnAlignment(.leading)
                ForEach(rows, id: \.side) { row in
                    Text(game.pistiSideName(view, side: row.side, me: me)).font(.caption.bold()).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
            line("Alınan kart", rows) { String($0.cards) }
            line("En çok kart", rows) { $0.mostCards ? "+\(PistiPoints.mostCards)" : "—" }
            line("Pişti (10)", rows) { $0.pisti > 0 ? "\($0.pisti) · +\($0.pisti * PistiPoints.pisti)" : "—" }
            line("Vale pişti (20)", rows) { $0.jackPisti > 0 ? "\($0.jackPisti) · +\($0.jackPisti * PistiPoints.jackPisti)" : "—" }
            line("As, vale, ♣2, ♦10", rows) { "+\($0.cardPoints)" }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Bu el").font(.subheadline.bold()).gridColumnAlignment(.leading)
                ForEach(rows, id: \.side) { row in Text(String(row.total)).font(.subheadline.monospacedDigit().bold()) }
            }
        }
        .font(.caption)
    }

    private func line(_ label: String, _ rows: [PistiSideSummary], _ value: @escaping (PistiSideSummary) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            ForEach(rows, id: \.side) { row in Text(value(row)).monospacedDigit() }
        }
    }
}

/// Shown instead of the hand once the match is over: the winner, the last deal and the per-deal ledger.
private struct PistiMatchEnd: View {
    let context: GameTableContext
    let view: PistiView
    let series: GameSeries?

    var body: some View {
        let standings = view.standings(series: series)
        let winners = standings.filter(\.winner)
        let rows = series?.rounds ?? []
        let last = view.result?.points ?? rows.last?.points ?? []
        VStack(alignment: .leading, spacing: 12) {
                Text(title(winners)).font(.headline)
                    .foregroundStyle(winners.contains { $0.own } ? Palette.accent : Color.primary)
                if !last.isEmpty {
                    Text("Son el").font(.caption.bold()).foregroundStyle(.secondary)
                    PistiSummaryGrid(game: context.game, me: context.me, view: view, points: last)
                }
                if !rows.isEmpty {
                    Text("Maç cetveli").font(.caption.bold()).foregroundStyle(.secondary)
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("El").gridColumnAlignment(.leading)
                            ForEach(standings) { standing in
                                Text(context.game.pistiSideName(view, side: standing.side, me: context.me)).lineLimit(1)
                            }
                        }.font(.caption.bold())
                        ForEach(rows.indices, id: \.self) { index in
                            GridRow {
                                Text("\(index + 1)").foregroundStyle(.secondary)
                                ForEach(standings) { standing in Text(String(view.sidePoints(rows[index].points, side: standing.side))).monospacedDigit() }
                            }.font(.caption)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Toplam").gridColumnAlignment(.leading)
                            ForEach(standings) { standing in Text(String(standing.total)).monospacedDigit() }
                        }.font(.caption.bold())
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func title(_ winners: [PistiStanding]) -> String {
        guard !winners.isEmpty else { return "El tamamlandı" }
        if winners.count > 1 { return "Maç berabere bitti" }
        let name = context.game.pistiSideName(view, side: winners[0].side, me: context.me)
        return winners[0].own && !view.teams ? "Maç bitti · sen kazandın" : "Maç bitti · \(name) kazandı"
    }
}

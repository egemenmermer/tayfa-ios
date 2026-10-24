import SwiftUI
import UIKit
import RoomsCore

/// Tavla table (`rooms-tavla-v1`), landscape: a wooden board drawn with shapes (24 points, bar, borne-off trays),
/// the viewer's side at the bottom (seat 1 sees it mirrored), tap or drag a checker onto a lit target, dice with a
/// short tumble, "Zar at" / "Geri al" / "Onayla" from `legalActions`, the opponent's last move as arrows, the
/// passed-turn banner, the match score and the round summary (Mars). Pure logic lives in RoomsCore `GamesTavla.swift`.
/// The host already shows the header (portrait), the slim bar with the turn clock (landscape), banners, leave and rematch.
struct TavlaTableView: View {
    let context: GameTableContext
    var body: some View {
        if let view = context.game.tavlaView {
            TavlaRoundView(context: context, view: view)
        } else if context.game.status == .playing && context.game.table.spectatorAccess {
            ProgressView("Tavla tahtası hazırlanıyor…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Tavla", systemImage: "dice")
            } description: {
                Text(context.game.table.spectatorAccess || context.mySeat != nil
                     ? "Oyun başlayınca tahta burada açılır. İlk eli açılış zarında büyük atan başlar."
                     : "Tahtayı görmek için izleyici olarak katıl ya da boş bir koltuğa otur.")
            }
        }
    }
}

// MARK: - Colours

private enum TavlaColors {
    static let frameLight = Color(red: 0.42, green: 0.25, blue: 0.13)
    static let frameDark = Color(red: 0.26, green: 0.14, blue: 0.07)
    static let field = Color(red: 0.93, green: 0.85, blue: 0.69)
    static let fieldShade = Color(red: 0.86, green: 0.76, blue: 0.58)
    static let pointA = Color(red: 0.40, green: 0.22, blue: 0.12)
    static let pointB = Color(red: 0.70, green: 0.27, blue: 0.19)
    static let target = Color(red: 0.25, green: 0.75, blue: 0.45)
    static let trail = Color(red: 0.98, green: 0.62, blue: 0.15)
    static func checker(_ seat: Int) -> Color { seat == 0 ? Color(red: 0.97, green: 0.94, blue: 0.86) : Color(red: 0.18, green: 0.13, blue: 0.11) }
    static func checkerRim(_ seat: Int) -> Color { seat == 0 ? Color(red: 0.62, green: 0.55, blue: 0.44) : Color(red: 0.55, green: 0.45, blue: 0.38) }
    static func seatName(_ seat: Int) -> String { seat == 0 ? "açık" : "koyu" }
}

// MARK: - Round

private struct TavlaRoundView: View {
    let context: GameTableContext
    let view: TavlaView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var picked: TavlaPlace?
    @State private var dragFrom: TavlaPlace?
    @State private var dragPoint: CGPoint?
    @State private var dragRefused = false
    @State private var tumble: Double = 0
    @State private var closedSummary: String?

    private var game: GameState { context.game }
    private var you: Int? { view.you }
    private var bottom: Int { view.bottomSeat }
    private var top: Int { view.topSeat }
    private var standing: TavlaMatchStanding { TavlaMatchStanding(view: view, series: game.table.series) }
    private var controls: TavlaControls { TavlaControls(legalActions: game.table.legalActions, busy: context.busy, phase: view.phase) }
    private var moving: Bool { !context.busy && view.viewerMoving(legalActions: game.table.legalActions) }
    private var selected: TavlaPlace? { moving ? view.selection(picked: picked) : nil }
    private var targets: [TavlaPlace] { selected.map { view.targets(from: $0) } ?? [] }
    private var sources: [TavlaPlace] { moving ? view.sources : [] }
    private var finished: TavlaView? { game.tavlaFinishedRound(view) }
    private var summaryKey: String { "\(standing.round)-\(finished?.result.map { "\($0.winner)\($0.points)" } ?? "")" }
    /// Selection resets whenever the position moves on.
    private var stepKey: String { "\(view.phase.rawValue):\(view.turn ?? -1):\(view.moves.count):\(standing.round)" }
    /// The dice tumble once per new roll (also an auto-passed one and the opening dice), never on first paint.
    private var rollKey: String {
        "\(standing.round)|\(view.opening.map { $0.map(String.init) ?? "-" })|\(view.dice ?? [])|\(view.lastTurn?.seat ?? -1):\(view.lastTurn?.dice ?? [])"
    }

    private func name(_ round: Int?) -> String {
        guard let round else { return "Oyuncu" }
        guard let seat = game.tavlaSeat(round: round) else { return "Oyuncu \(round + 1)" }
        return seat.userId == context.me ? "Sen" : seat.name
    }

    var body: some View {
        Group {
            if context.compactChrome {
                VStack(spacing: 6) {
                    scoreBar
                    HStack(alignment: .top, spacing: 10) {
                        boardStack.frame(maxWidth: .infinity, maxHeight: .infinity)
                        sideColumn.frame(width: 178)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        scoreBar
                        seatPanel(top, avatar: false)
                        boardStack
                        seatPanel(bottom, avatar: false)
                        diceRow
                        actionButtons
                        statusBlock
                    }.padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .onChange(of: stepKey) { _, _ in picked = nil; dragFrom = nil; dragPoint = nil }
        .onChange(of: rollKey) { _, _ in rolled() }
        .onChange(of: summaryKey) { _, _ in
            if let result = finished?.result, result.winner == you { GameHaptics.yourTurn() }
        }
        .onChange(of: view.passedTurn?.seat) { _, seat in if seat != nil { GameHaptics.refused() } }
    }

    private func rolled() {
        GameSounds.play(.dice)
        guard !reduceMotion else { return }
        Task { @MainActor in
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { tumble = 1 }
            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) { tumble = 0 }
        }
    }

    // MARK: Score and seats

    private var scoreBar: some View {
        let totals = standing.totals
        return HStack(spacing: 8) {
            Text(name(bottom)).font(.footnote).lineLimit(1)
            Text("\(totals[bottom]) – \(totals[top])").font(.headline.monospacedDigit())
            Text(name(top)).font(.footnote).lineLimit(1)
            Text("· \(TavlaMatchStanding.targetLabel(standing.matchTo))\(standing.round > 0 ? " · El \(standing.round)" : "")")
                .font(.footnote).foregroundStyle(.secondary)
            if standing.winner != nil {
                Label("Maç bitti", systemImage: "trophy.fill").font(.footnote.bold()).foregroundStyle(TavlaColors.trail)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Palette.surface, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Maç skoru \(standing.scoreLine(bottom: bottom)): \(name(bottom)) \(totals[bottom]), \(name(top)) \(totals[top])")
    }

    private func seatPanel(_ round: Int, avatar: Bool) -> some View {
        let turn = view.turn == round && view.phase != .over
        let seat = game.tavlaSeat(round: round)
        return HStack(spacing: 8) {
            if avatar, let seat {
                if seat.isBotSeat {
                    Circle().fill(Palette.raised).overlay(Image(systemName: "cpu").font(.caption)).frame(width: 30, height: 30)
                } else {
                    ChatAvatarView(chat: context.chat, userID: seat.userId, name: seat.name, size: 30)
                }
            }
            Circle().fill(TavlaColors.checker(round)).overlay(Circle().strokeBorder(TavlaColors.checkerRim(round), lineWidth: 1.5))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(round)).font(.caption.bold()).lineLimit(1)
                Text("Kalan \(view.pipCount(round)) · Toplanan \(view.borneOff(round))/15")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if turn { Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Palette.accent) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(turn ? Palette.accent : Color.clear, lineWidth: 2))
        .opacity(seat?.connected == false ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(round)), \(TavlaColors.seatName(round)) pullar, kalan \(view.pipCount(round)), toplanan \(view.borneOff(round))\(turn ? ", sıra onda" : "")")
    }

    // MARK: Side column, dice, buttons, status

    private var sideColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                seatPanel(top, avatar: true)
                diceRow
                actionButtons
                statusBlock
                seatPanel(bottom, avatar: true)
            }
        }
    }

    private var diceRow: some View {
        let faces = view.diceFaces
        return HStack(spacing: 6) {
            if !faces.isEmpty {
                ForEach(Array(faces.enumerated()), id: \.offset) { item in
                    TavlaDieView(value: item.element.value, used: item.element.used, owner: view.turn ?? bottom, size: faces.count > 2 ? 28 : 34)
                        .rotationEffect(.degrees(tumble * (item.offset.isMultiple(of: 2) ? 300 : -260)))
                        .scaleEffect(1 + tumble * 0.25)
                }
            } else if view.phase == .opening {
                ForEach([bottom, top], id: \.self) { round in
                    VStack(spacing: 2) {
                        if let value = view.opening.indices.contains(round) ? view.opening[round] : nil {
                            TavlaDieView(value: value, used: false, owner: round, size: 30).rotationEffect(.degrees(tumble * 300))
                        } else {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: 30, height: 30)
                        }
                        Text(name(round)).font(.caption2).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                }
            } else if let last = view.lastTurn, !last.dice.isEmpty {
                ForEach(Array(last.dice.enumerated()), id: \.offset) { item in
                    TavlaDieView(value: item.element, used: true, owner: last.seat, size: 26)
                }
            }
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diceAccessibility)
    }
    private var diceAccessibility: String {
        let faces = view.diceFaces
        if !faces.isEmpty {
            let left = faces.filter { !$0.used }.map { String($0.value) }
            return "Zarlar \(faces.map { String($0.value) }.joined(separator: " ")), oynanacak: \(left.isEmpty ? "yok" : left.joined(separator: " "))"
        }
        if view.phase == .opening {
            let rolls = [bottom, top].map { round in "\(name(round)) \(view.opening.indices.contains(round) ? view.opening[round].map(String.init) ?? "atmadı" : "atmadı")" }
            return "Açılış zarı: " + rolls.joined(separator: ", ")
        }
        return view.lastTurn.map { "Son atılan zar \($0.diceText)" } ?? "Zar atılmadı"
    }

    @ViewBuilder private var actionButtons: some View {
        if you != nil, context.mySeat != nil {
            let controls = controls
            VStack(spacing: 6) {
                Button { context.move(GameMove.tavlaRoll) } label: {
                    Label(controls.rollTitle, systemImage: "dice.fill").font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas)
                .disabled(!controls.roll)
                HStack(spacing: 6) {
                    Button { context.move(GameMove.tavlaUndo) } label: {
                        Label("Geri al", systemImage: "arrow.uturn.backward").font(.footnote.bold()).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).disabled(!controls.undo)
                    Button { context.move(GameMove.tavlaConfirm) } label: {
                        Label("Onayla", systemImage: "checkmark").font(.footnote.bold()).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).disabled(!controls.confirm)
                }
                .labelStyle(.titleOnly)
            }
        }
    }

    private var statusText: String {
        var text: String
        switch view.phase {
        case .over: text = standing.winner == nil ? "El bitti" : "Maç bitti"
        case .opening: text = view.turn == you ? "Açılış zarını at: büyük atan başlar." : "\(name(view.turn)) açılış zarını atıyor."
        case .roll: text = view.turn == you ? "Sıra sende: zar at." : "\(name(view.turn)) zar atacak."
        case .moving:
            if view.turn == you {
                text = view.legalMoves.isEmpty ? "Hamlen tamam: onayla ya da geri al."
                    : selected == nil ? "Oynayacağın pulu seç." : "Parlayan haneye oyna ya da başka pul seç."
            } else {
                text = "\(name(view.turn)) oynuyor."
            }
        case .unknown: text = "Tahta güncelleniyor."
        }
        if view.phase == .opening, let tie = view.openingTie { text = "Zarlar eşit geldi (\(tie)): yeniden atılıyor. " + text }
        return text
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText).font(.footnote).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
            if let passed = view.passedTurn {
                Label {
                    Text("Oynayacak hamle yok · \(name(passed.seat)) \(passed.diceText) attı, sıra geçti.")
                } icon: { Image(systemName: "nosign") }
                .font(.footnote.bold()).foregroundStyle(TavlaColors.trail)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(TavlaColors.trail.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if let last = view.lastTurn, !last.passed, last.seat != you, !view.opponentTrail.isEmpty {
                Text("\(name(last.seat)) \(last.diceText): \(last.moves.map { $0.text(seat: last.seat) }.joined(separator: " "))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: view.passedTurn?.seat)
    }

    // MARK: Board

    private var boardStack: some View {
        ZStack {
            GeometryReader { proxy in
                board(TavlaGeometry(size: proxy.size, you: you, bottomSeat: bottom))
            }
            .aspectRatio(1.6, contentMode: .fit)
            if let finished, let result = finished.result, closedSummary != summaryKey {
                summaryCard(result)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: summaryKey)
        .frame(maxWidth: .infinity)
    }

    private func board(_ geo: TavlaGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            // Wooden frame, two playing fields, the borne-off tray (split per side).
            RoundedRectangle(cornerRadius: geo.frame).fill(LinearGradient(colors: [TavlaColors.frameLight, TavlaColors.frameDark], startPoint: .top, endPoint: .bottom))
            ForEach([0, 6], id: \.self) { first in
                Rectangle().fill(LinearGradient(colors: [TavlaColors.field, TavlaColors.fieldShade], startPoint: .top, endPoint: .bottom))
                    .frame(width: geo.col * 6, height: geo.fieldHeight)
                    .position(x: geo.left(first) + geo.col * 3, y: geo.size.height / 2)
            }
            Rectangle().fill(TavlaColors.frameDark.opacity(0.9)).frame(width: geo.trayWidth, height: geo.fieldHeight)
                .position(x: geo.trayX, y: geo.size.height / 2)
            Rectangle().fill(TavlaColors.frameLight).frame(width: geo.trayWidth, height: 3).position(x: geo.trayX, y: geo.size.height / 2)

            Group {
                ForEach(0..<24, id: \.self) { index in pointView(index, geo) }
                barView(geo)
                trayView(geo, round: bottom, atBottom: true)
                trayView(geo, round: top, atBottom: false)
            }
            .accessibilityHidden(true)
            trailView(geo)
            accessibilityProxies(geo)
            if dragFrom != nil, let dragPoint {
                TavlaCheckerView(round: you ?? bottom, size: geo.checker * 1.1)
                    .shadow(radius: 6).position(dragPoint).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            if let place = geo.place(at: location) { tap(place) } else { picked = nil }
        }
        .simultaneousGesture(dragGesture(geo))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tavla tahtası")
    }

    private func pointView(_ index: Int, _ geo: TavlaGeometry) -> some View {
        let slot = TavlaBoard.slot(index, you: you)
        let point = view.points[index]
        let isTarget = targets.contains(.point(index))
        let isSelected = selected == .point(index)
        let isSource = sources.contains(.point(index))
        let down = slot.row == .top
        let x = geo.x(slot.col)
        let triangleY = down ? geo.top + geo.pointHeight / 2 : geo.bottomEdge - geo.pointHeight / 2
        let shown = min(point.count, 5)
        return ZStack {
            TavlaTriangle(pointsDown: down)
                .fill((slot.col + (down ? 0 : 1)).isMultiple(of: 2) ? TavlaColors.pointA : TavlaColors.pointB)
                .frame(width: geo.col * 0.94, height: geo.pointHeight)
                .position(x: x, y: triangleY)
            if isTarget {
                TavlaTriangle(pointsDown: down).fill(TavlaColors.target.opacity(0.55))
                    .frame(width: geo.col * 0.94, height: geo.pointHeight)
                    .position(x: x, y: triangleY)
                Circle().fill(TavlaColors.target).frame(width: geo.checker * 0.4, height: geo.checker * 0.4)
                    .position(x: x, y: geo.stackY(row: slot.row, at: min(point.count, 4)))
            }
            if let seat = point.seat {
                ForEach(0..<shown, id: \.self) { k in
                    let topChecker = k == shown - 1
                    TavlaCheckerView(round: seat, size: geo.checker,
                                     ring: topChecker ? (isSelected ? Palette.accent : isSource ? TavlaColors.target : nil) : nil,
                                     badge: topChecker && point.count > 5 ? point.count : nil)
                        .opacity(dragFrom == .point(index) && topChecker ? 0.35 : 1)
                        .position(x: x, y: geo.stackY(row: slot.row, at: k))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: point)
    }

    private func barView(_ geo: TavlaGeometry) -> some View {
        let selectedBar = selected == .bar
        let sourceBar = sources.contains(.bar)
        return ZStack {
            Rectangle().fill(LinearGradient(colors: [TavlaColors.frameDark, TavlaColors.frameLight, TavlaColors.frameDark], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.barWidth, height: geo.size.height)
                .position(x: geo.barX, y: geo.size.height / 2)
            ForEach([bottom, top], id: \.self) { round in
                let count = view.onBar(round)
                let shown = min(count, 3)
                let atBottom = round == bottom
                ForEach(0..<shown, id: \.self) { k in
                    TavlaCheckerView(round: round, size: geo.checker,
                                     ring: atBottom && k == shown - 1 ? (selectedBar ? Palette.accent : sourceBar ? TavlaColors.target : nil) : nil,
                                     badge: k == shown - 1 && count > 1 ? count : nil)
                        .position(x: geo.barX, y: geo.size.height / 2 + (atBottom ? 1 : -1) * geo.checker * (0.8 + CGFloat(k) * 0.9))
                }
            }
        }
    }

    private func trayView(_ geo: TavlaGeometry, round: Int, atBottom: Bool) -> some View {
        let count = view.borneOff(round)
        let isTarget = atBottom && targets.contains(.off)
        let slab = max(2, (geo.fieldHeight / 2 - 8) / 15 - 1)
        let half = geo.fieldHeight / 2
        return ZStack {
            if isTarget {
                RoundedRectangle(cornerRadius: 4).fill(TavlaColors.target.opacity(0.5))
                    .frame(width: geo.trayWidth - 4, height: half - 4)
                    .position(x: geo.trayX, y: atBottom ? geo.bottomEdge - half / 2 : geo.top + half / 2)
            }
            ForEach(0..<count, id: \.self) { k in
                RoundedRectangle(cornerRadius: 1.5).fill(TavlaColors.checker(round))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(TavlaColors.checkerRim(round), lineWidth: 0.5))
                    .frame(width: geo.trayWidth - 8, height: slab)
                    .position(x: geo.trayX, y: atBottom ? geo.bottomEdge - 3 - slab / 2 - CGFloat(k) * (slab + 1) : geo.top + 3 + slab / 2 + CGFloat(k) * (slab + 1))
            }
            if count > 0 {
                Text("\(count)").font(.caption2.bold().monospacedDigit()).foregroundStyle(.white)
                    .position(x: geo.trayX, y: geo.size.height / 2 + (atBottom ? 12 : -12))
            }
        }
    }

    /// VoiceOver elements framed on each point, the bar and the trays (the drawn layers fill the whole board).
    private func accessibilityProxies(_ geo: TavlaGeometry) -> some View {
        let half = geo.fieldHeight / 2
        return ZStack {
            ForEach(0..<24, id: \.self) { index in
                let slot = TavlaBoard.slot(index, you: you)
                let point = view.points[index]
                let isTarget = targets.contains(.point(index))
                let isSource = sources.contains(.point(index))
                let pieces = point.count == 0 ? "boş" : "\(point.count) \(point.seat.map(TavlaColors.seatName) ?? "") pul"
                Color.clear
                    .frame(width: geo.col, height: half)
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel("\(TavlaBoard.pointNumber(index, seat: bottom)). hane, \(pieces)")
                    .accessibilityValue(selected == .point(index) ? "seçili" : isTarget ? "oynanabilir hedef" : isSource ? "oynanabilir pul" : "")
                    .accessibilityAddTraits(isTarget || isSource ? .isButton : [])
                    .accessibilityAction { tap(.point(index)) }
                    .position(x: geo.x(slot.col), y: slot.row == .top ? geo.top + half / 2 : geo.bottomEdge - half / 2)
            }
            Color.clear
                .frame(width: geo.barWidth, height: geo.fieldHeight)
                .accessibilityElement()
                .accessibilityLabel("Bar: \(name(bottom)) \(view.onBar(bottom)), \(name(top)) \(view.onBar(top)) kırık pul")
                .accessibilityValue(selected == .bar ? "seçili" : sources.contains(.bar) ? "oynanabilir pul" : "")
                .accessibilityAddTraits(sources.contains(.bar) ? .isButton : [])
                .accessibilityAction { tap(.bar) }
                .position(x: geo.barX, y: geo.size.height / 2)
            ForEach([bottom, top], id: \.self) { round in
                let atBottom = round == bottom
                let isTarget = atBottom && targets.contains(.off)
                Color.clear
                    .frame(width: geo.trayWidth, height: half)
                    .accessibilityElement()
                    .accessibilityLabel("\(name(round)) toplanan pul: \(view.borneOff(round))")
                    .accessibilityValue(isTarget ? "oynanabilir hedef: topla" : "")
                    .accessibilityAddTraits(isTarget ? .isButton : [])
                    .accessibilityAction { if isTarget { tap(.off) } }
                    .position(x: geo.trayX, y: atBottom ? geo.bottomEdge - half / 2 : geo.top + half / 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// The opponent's moves as arrows, with a ghost where each checker left from, until the viewer rolls.
    @ViewBuilder private func trailView(_ geo: TavlaGeometry) -> some View {
        let trail = view.opponentTrail
        if let seat = view.trailSeat, !trail.isEmpty {
            ZStack {
                ForEach(Array(trail.enumerated()), id: \.offset) { item in
                    let from = geo.center(of: item.element.from, seat: seat, view: view)
                    let to = geo.center(of: item.element.to, seat: seat, view: view)
                    TavlaArrow(from: from, to: to, head: geo.checker * 0.35)
                        .stroke(TavlaColors.trail, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                    Circle().strokeBorder(TavlaColors.trail, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                        .background(Circle().fill(TavlaColors.checker(seat).opacity(0.3)))
                        .frame(width: geo.checker * 0.9, height: geo.checker * 0.9)
                        .position(from)
                    if item.element.hit {
                        Image(systemName: "bolt.fill").font(.system(size: geo.checker * 0.4)).foregroundStyle(TavlaColors.trail).position(to)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name(seat)) son hamlesi: \(trail.map { $0.text(seat: seat) }.joined(separator: " "))")
        }
    }

    private func summaryCard(_ result: TavlaRoundResult) -> some View {
        let totals = standing.totals
        return VStack(spacing: 6) {
            Image(systemName: "trophy.fill").font(.title2).foregroundStyle(TavlaColors.trail)
            Text(standing.winner.map { "Maçı \(name($0)) kazandı" } ?? "Eli \(name(result.winner)) kazandı")
                .font(.headline).multilineTextAlignment(.center)
            Text(result.mars ? "Mars! (2 puan)" : "Normal oyun (1 puan)")
                .font(result.mars ? .subheadline.bold() : .subheadline)
                .foregroundStyle(result.mars ? TavlaColors.trail : Color.primary)
            Text("Maç: \(name(bottom)) \(totals[bottom]) – \(totals[top]) \(name(top)) · \(TavlaMatchStanding.targetLabel(standing.matchTo))")
                .font(.footnote.monospacedDigit()).multilineTextAlignment(.center)
            if standing.winner == nil { Text("Sonraki el açılış zarıyla başlar.").font(.caption).foregroundStyle(.secondary) }
            Button("Tahtayı göster") { closedSummary = summaryKey }.font(.footnote).frame(minHeight: 44)
        }
        .padding(14).frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Input

    private func tap(_ place: TavlaPlace) {
        guard moving else { picked = nil; return }
        switch view.tap(place, selected: selected) {
        case .select(let source): picked = source; GameHaptics.tap()
        case .deselect: picked = nil
        case .move(let from, let to): send(from: from, to: to)
        }
    }
    private func send(from: TavlaPlace, to: TavlaPlace) {
        if view.hits(from: from, to: to) { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        picked = nil
        // The server infers the die (bear-off prefers the exact one), as on the desktop.
        context.move(GameMove.tavlaMove(from: from.move, to: to.move))
    }
    private func dragGesture(_ geo: TavlaGeometry) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard moving, !dragRefused else { return }
                if dragFrom == nil {
                    guard let start = geo.place(at: value.startLocation), sources.contains(start) else { dragRefused = true; return }
                    dragFrom = start
                    picked = start
                }
                dragPoint = value.location
            }
            .onEnded { value in
                let from = dragFrom
                dragFrom = nil; dragPoint = nil; dragRefused = false
                guard let from, let to = geo.place(at: value.location), to != from else { return }
                if view.targets(from: from).contains(to) { send(from: from, to: to) }
            }
    }
}

// MARK: - Geometry

/// Board layout in points: frame, 12 columns with the bar between columns 5 and 6, the borne-off tray on the right.
private struct TavlaGeometry {
    let size: CGSize
    let you: Int?
    let bottomSeat: Int
    var frame: CGFloat { max(6, size.width * 0.022) }
    var barWidth: CGFloat { size.width * 0.06 }
    var trayWidth: CGFloat { size.width * 0.07 }
    var col: CGFloat { max(1, (size.width - frame * 3 - barWidth - trayWidth) / 12) }
    var top: CGFloat { frame }
    var bottomEdge: CGFloat { size.height - frame }
    var fieldHeight: CGFloat { max(1, size.height - frame * 2) }
    var pointHeight: CGFloat { fieldHeight * 0.42 }
    var checker: CGFloat { max(8, min(col * 0.9, fieldHeight * 0.48 / 5)) }
    var barX: CGFloat { frame + col * 6 + barWidth / 2 }
    var trayX: CGFloat { size.width - frame - trayWidth / 2 }
    /// Left edge of the half that starts at column `first` (0 or 6).
    func left(_ first: Int) -> CGFloat { frame + CGFloat(first) * col + (first >= 6 ? barWidth : 0) }
    /// Centre x of a column.
    func x(_ column: Int) -> CGFloat { frame + (CGFloat(column) + 0.5) * col + (column >= 6 ? barWidth : 0) }
    /// Centre y of the k-th checker from the edge (past five they share the fifth spot; a badge shows the count).
    func stackY(row: TavlaBoard.Row, at k: Int) -> CGFloat {
        let offset = checker * (0.5 + CGFloat(min(k, 4)))
        return row == .top ? top + offset : bottomEdge - offset
    }
    /// What a touch at `location` is on: a point, the bar or the tray.
    func place(at location: CGPoint) -> TavlaPlace? {
        guard location.y >= 0, location.y <= size.height, location.x >= 0 else { return nil }
        if location.x >= size.width - frame * 1.5 - trayWidth { return .off }
        if abs(location.x - barX) <= barWidth / 2 { return .bar }
        let fieldX = location.x - frame - (location.x > barX ? barWidth : 0)
        let column = Int((fieldX / col).rounded(.down))
        guard (0...11).contains(column) else { return nil }
        return .point(TavlaBoard.index(row: location.y < size.height / 2 ? .top : .bottom, col: column, you: you))
    }
    /// Where an arrow for `seat` starts or ends.
    func center(of place: TavlaPlace, seat: Int, view: TavlaView) -> CGPoint {
        switch place {
        case .point(let index):
            let slot = TavlaBoard.slot(index, you: you)
            let count = view.points.indices.contains(index) ? max(1, view.points[index].count) : 1
            return CGPoint(x: x(slot.col), y: stackY(row: slot.row, at: min(count, 5) - 1))
        case .bar: return CGPoint(x: barX, y: size.height / 2 + (seat == bottomSeat ? checker : -checker))
        case .off: return CGPoint(x: trayX, y: seat == bottomSeat ? size.height * 0.75 : size.height * 0.25)
        }
    }
}

// MARK: - Pieces

private struct TavlaTriangle: Shape {
    let pointsDown: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsDown {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// A line with an arrowhead, in the board's coordinates.
private struct TavlaArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    let head: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + cos(angle + side) * head, y: to.y + sin(angle + side) * head))
        }
        return path
    }
}

private struct TavlaCheckerView: View {
    let round: Int
    let size: CGFloat
    var ring: Color? = nil
    var badge: Int? = nil
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [TavlaColors.checker(round).opacity(0.85), TavlaColors.checker(round)], center: .topLeading, startRadius: 0, endRadius: size))
            Circle().strokeBorder(TavlaColors.checkerRim(round), lineWidth: max(1, size * 0.06))
            Circle().inset(by: size * 0.22).strokeBorder(TavlaColors.checkerRim(round).opacity(0.7), lineWidth: max(0.5, size * 0.04))
            if let badge {
                Text("\(badge)").font(.system(size: size * 0.45, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(round == 0 ? Color.black : Color.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(ring ?? Color.clear, lineWidth: 3).padding(-2))
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
    }
}

private struct TavlaDieView: View {
    let value: Int
    let used: Bool
    let owner: Int
    let size: CGFloat
    /// Pip positions on a 3×3 grid for 1…6.
    private var pips: [(Int, Int)] {
        switch value {
        case 1: [(1, 1)]
        case 2: [(0, 0), (2, 2)]
        case 3: [(0, 0), (1, 1), (2, 2)]
        case 4: [(0, 0), (2, 0), (0, 2), (2, 2)]
        case 5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
        default: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)]
        }
    }
    var body: some View {
        let face = owner == 0 ? Color(red: 0.98, green: 0.97, blue: 0.93) : Color(red: 0.2, green: 0.15, blue: 0.13)
        let pip = owner == 0 ? Color.black : Color.white
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.2).fill(face)
            RoundedRectangle(cornerRadius: size * 0.2).strokeBorder(Color.black.opacity(0.3), lineWidth: 1)
            ForEach(Array(pips.enumerated()), id: \.offset) { item in
                Circle().fill(pip).frame(width: size * 0.18, height: size * 0.18)
                    .position(x: size * (0.25 + 0.25 * CGFloat(item.element.0)), y: size * (0.25 + 0.25 * CGFloat(item.element.1)))
            }
        }
        .frame(width: size, height: size)
        .opacity(used ? 0.35 : 1)
        .accessibilityLabel("Zar \(value)\(used ? ", oynandı" : "")")
    }
}

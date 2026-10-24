import SwiftUI
import UIKit
import RoomsCore

/// Classic Okey table (`rooms-okey-v1`), landscape: the left/top/right players around the felt with each discard pile in
/// the corner between its owner and the next player, the middle stack (tap to draw) and the gösterge in the centre, the
/// left neighbour's top tile takeable on a draw, and your 2×15 wooden ıstaka at the bottom (long-press to drag and
/// reorder; the order is kept per round), "Seri diz" / "Çift diz", drag a tile onto your corner to throw it or onto the
/// middle to finish, tap-select + "At", "Bitir" only when the rack really finishes, "Göstergeyi göster" when legal, and
/// the round summary with the winner's open rack. Logic lives in RoomsCore `GamesOkey.swift`; moves go out as
/// `GameMove.okey*`. The host already draws the slim landscape bar (turn clock, leave, rematch), banners and errors.
struct OkeyTableView: View {
    let context: GameTableContext
    var body: some View {
        if let view = context.game.okeyClassic {
            // A new round is a new history entry: its rack order, selection, log and summary start afresh.
            OkeyBoard(context: context, view: view).id(context.game.history.count)
        } else {
            ContentUnavailableView {
                Label(context.game.table.spectatorAccess ? "Taşlar dağıtılıyor" : "Masa gizli", systemImage: "square.grid.3x2.fill")
            } description: {
                Text(context.game.table.spectatorAccess ? "Masa kurulunca ıstakan burada görünür." : "Masayı görmek için izleyici olarak katıl ya da boş bir koltuğa otur.")
            }
        }
    }
}

// MARK: - Board

private struct OkeyBoard: View {
    let context: GameTableContext
    let view: OkeyClassicView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arranged: OkeyClassicRack.Layout?
    @State private var selected: String?
    @State private var finisher: String?
    @State private var notice: String?
    @State private var log: [String] = []
    @State private var summaryOpen = true
    @State private var dropTarget: OkeyDropKind?
    private let store = OkeyClassicRackStore()

    private var game: GameState { context.game }
    private var hand: [OkeyTile] { view.hand ?? [] }
    private var handIDs: [String] { hand.map(\.id) }
    private var layout: OkeyClassicRack.Layout { OkeyClassicRack.reconcile(arranged, ids: handIDs) }
    private var rackKey: String { game.okeyRackKey(me: context.me) }
    private var controls: OkeyClassicControls {
        OkeyClassicControls(view: view, legalActions: game.table.legalActions, busy: context.busy, selected: selected, finisher: finisher)
    }
    private var finisherKey: String { "\(handIDs.joined(separator: ",")):\(view.stage.rawValue):\(view.myTurn)" }
    private var ended: Bool { view.ended || game.status == .finished }
    private var showsRack: Bool { !view.spectator && !ended }
    private func name(_ round: Int) -> String { game.okeyName(round: round, me: context.me) }
    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85) }

    var body: some View {
        GeometryReader { proxy in
            let size = OkeySizes(proxy.size, rack: showsRack)
            VStack(spacing: 6) {
                felt(size).frame(height: size.feltHeight)
                if showsRack { rackArea(size) } else { bottomStrip }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .overlay { if ended && summaryOpen { summary } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summaryOpen)
        .onAppear {
            arranged = store.load(rackKey)
            finisher = OkeyClassicControls.finisher(view)
            if let last = view.lastAction { log = [line(last)] }
        }
        .onChange(of: handIDs) { _, ids in
            // Keep a drawn tile where it landed and forget thrown ones, so the rack never jumps.
            let next = OkeyClassicRack.reconcile(arranged, ids: ids)
            arranged = next
            store.save(next, for: rackKey)
            if let current = selected, !ids.contains(current) { selected = nil }
        }
        .onChange(of: finisherKey) { _, _ in finisher = OkeyClassicControls.finisher(view) }
        .onChange(of: view.lastAction?.key) { _, _ in
            guard let last = view.lastAction else { return }
            withAnimation(animation) { log = Array(([line(last)] + log).prefix(3)) }
            GameSounds.play(last.kind == .finish ? .win : .tile)
            if last.seat != view.viewerSeat { AccessibilityNotification.Announcement(line(last)).post() }
        }
        .onChange(of: view.myTurn) { _, mine in
            notice = nil
            guard mine else { return }
            GameHaptics.yourTurn()
            GameSounds.play(.turn)
            AccessibilityNotification.Announcement("Sıra sende").post()
        }
        .onChange(of: view.stage) { _, _ in notice = nil }
    }

    private func line(_ action: OkeyClassicLastAction) -> String {
        OkeyClassicText.describe(action, name: name(action.seat), mine: action.seat == view.viewerSeat, okey: view.okey)
    }

    // MARK: Felt

    private func felt(_ size: OkeySizes) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.36, blue: 0.24), Color(red: 0.04, green: 0.25, blue: 0.17)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(red: 0.42, green: 0.26, blue: 0.12), lineWidth: 4))
            // Corner piles: pile i lies between round index i and the next player.
            ForEach(0..<OkeyClassicView.players, id: \.self) { round in
                pile(round: round, size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(view.place(of: round).pileCorner))
                    .padding(8)
            }
            // Side players, inward of the corner piles so the two never overlap on a short felt.
            ForEach(sideRounds, id: \.self) { round in
                let place = view.place(of: round)
                seat(round: round, size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place == .left ? .leading : .trailing)
                    .padding(place == .left ? .leading : .trailing, size.feltTile * 1.5 + 28)
            }
            VStack(spacing: 4) {
                if let top = roundAt(.top) { seat(round: top, size: size) }
                Spacer(minLength: 0)
                middle(size)
                Spacer(minLength: 0)
                // A spectator sees the bottom player too (their rack stays hidden).
                if view.spectator, let bottom = roundAt(.bottom) { seat(round: bottom, size: size) }
            }
            .padding(.vertical, 6)
        }
    }

    private func roundAt(_ place: OkeyClassicPlace) -> Int? { (0..<OkeyClassicView.players).first { view.place(of: $0) == place } }
    private var sideRounds: [Int] { [OkeyClassicPlace.left, .right].compactMap(roundAt) }

    private func alignment(_ corner: OkeyClassicCorner) -> Alignment {
        switch corner {
        case .bottomRight: .bottomTrailing
        case .topRight: .topTrailing
        case .topLeft: .topLeading
        case .bottomLeft: .bottomLeading
        }
    }

    private func removeAction(_ seat: GameSeat) -> (() -> Void)? {
        guard game.canRemove(seat, viewer: context.me, roomHost: false) else { return nil }
        let send = context.send
        let number = seat.seat
        return { send(.removeSeat(seat: number)) }
    }

    private func seat(round: Int, size: OkeySizes) -> some View {
        let info = view.seat(round)
        let playing = view.turn == round && !ended
        let count = info?.tileCount ?? 0
        return HStack(spacing: 6) {
            if let seat = game.okeySeat(round: round) {
                GameSeatBadge(seat: seat, game: game, chat: context.chat, me: context.me, size: size.avatar, onRemove: removeAction(seat))
            } else {
                Circle().fill(Color.white.opacity(0.12)).frame(width: size.avatar, height: size.avatar)
                    .overlay(Image(systemName: "person.fill.questionmark").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) taş").font(.caption2.monospacedDigit().bold()).foregroundStyle(.white.opacity(0.85))
                if info?.showedIndicator == true {
                    Label("Gösterge", systemImage: "eye.fill").font(.caption2).foregroundStyle(.yellow)
                }
                if playing { Text("Sırada").font(.caption2.bold()).foregroundStyle(Palette.accent) }
                // A few face-down tiles hint the rack without spending height.
                HStack(spacing: -size.feltTile * 0.3) {
                    ForEach(0..<min(count, 6), id: \.self) { _ in GameTileView(tile: nil, faceDown: true, width: size.feltTile * 0.42) }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(5)
        .background(playing ? Palette.accent.opacity(0.24) : Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(playing ? Palette.accent : Color.clear, lineWidth: 2))
        .animation(animation, value: playing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.okeySeat(round: round) == nil ? "Boş koltuk" : name(round)), \(count) taş\(playing ? ", sıra onda" : "")\(info?.showedIndicator == true ? ", göstergeyi gösterdi" : "")")
    }

    private func pile(round: Int, size: OkeySizes) -> some View {
        let pile = view.seat(round)?.discards ?? []
        let top = pile.last
        let own = round == view.viewerSeat
        let takeable = round == view.leftSeat && controls.takeLeft
        let lastThrown = view.lastAction?.kind == .discard && view.lastAction?.tile?.id == top?.id
        let corner = RoundedRectangle(cornerRadius: size.feltTile * 0.16)
        return VStack(spacing: 2) {
            Text(own ? "Attığın" : "\(name(round)) attı").font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                .frame(maxWidth: size.feltTile * 2.4)
            ZStack {
                if pile.count > 1 { GameTileView(tile: nil, faceDown: true, width: size.feltTile).offset(x: -3, y: -3) }
                if let top {
                    GameTileView(tile: top, width: size.feltTile, selected: takeable, isOkey: top.isJoker)
                        .overlay(corner.strokeBorder(lastThrown ? Color.yellow : Color.clear, lineWidth: 2))
                        .id(top.id)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                } else {
                    corner.strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: size.feltTile, height: size.feltTile * 1.45)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { if takeable { draw(fromDiscard: true) } }
            if takeable { Text("Al").font(.caption2.bold()).foregroundStyle(.yellow) }
        }
        .padding(4)
        .background(own && dropTarget == .discard ? Color.white.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .modifier(OkeyDropZone(enabled: own && showsRack, onTarget: { target(.discard, $0) }, onDrop: { throwTile($0, finish: false) }))
        .animation(animation, value: top?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pileLabel(round: round, top: top, count: pile.count, own: own, takeable: takeable))
        .accessibilityAddTraits(takeable ? .isButton : [])
        .accessibilityAction { if takeable { draw(fromDiscard: true) } }
    }

    private func pileLabel(round: Int, top: OkeyTile?, count: Int, own: Bool, takeable: Bool) -> String {
        let owner = own ? "Attığın taşlar" : "\(name(round)) attığı taşlar"
        guard let top else { return "\(owner), boş" }
        return "\(owner), üstte \(OkeyClassicText.tileName(top, okey: view.okey)), \(count) taş\(takeable ? ", almak için dokun" : "")"
    }

    private func target(_ kind: OkeyDropKind, _ on: Bool) {
        if on { dropTarget = kind } else if dropTarget == kind { dropTarget = nil }
    }

    private func middle(_ size: OkeySizes) -> some View {
        VStack(spacing: 3) {
            Text("El \(game.history.count + (ended ? 0 : 1)) · \(view.scoring.title) · Okey: \(view.okey.title)")
                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            HStack(spacing: 14) {
                Button { draw(fromDiscard: false) } label: {
                    ZStack(alignment: .bottomTrailing) {
                        GameTileView(tile: nil, faceDown: true, width: size.feltTile * 1.1)
                            .overlay(RoundedRectangle(cornerRadius: size.feltTile * 0.18).strokeBorder(controls.drawStock ? Color.yellow : Color.clear, lineWidth: 2.5))
                        Text("\(view.stockCount)").font(.caption2.monospacedDigit().bold()).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.black.opacity(0.7), in: Capsule()).foregroundStyle(.white).offset(x: 6, y: 4)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!controls.drawStock)
                .accessibilityLabel("Ortadan taş çek, \(view.stockCount) taş kaldı")
                if let indicator = view.indicator {
                    VStack(spacing: 1) {
                        GameTileView(tile: indicator, width: size.feltTile)
                        Text("Gösterge").font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Gösterge \(OkeyClassicText.tileName(indicator, okey: view.okey)), okey \(view.okey.title)")
                }
            }
            .padding(4)
            .background(dropTarget == .finish ? Color.white.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .modifier(OkeyDropZone(enabled: showsRack, onTarget: { target(.finish, $0) }, onDrop: { throwTile($0, finish: true) }))
            // The opponent's last move stays visible; a taller felt shows a little history.
            ForEach(Array(log.prefix(size.logLines).enumerated()), id: \.offset) { index, text in
                Text(text).font(index == 0 ? .caption.bold() : .caption2).foregroundStyle(.white.opacity(index == 0 ? 1 : 0.6)).lineLimit(1)
            }
        }
        .frame(maxWidth: size.middleWidth)
        .accessibilityElement(children: .contain)
    }

    // MARK: Rack

    private func rackArea(_ size: OkeySizes) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(promptTitle).font(.subheadline.bold()).lineLimit(1)
                    Text(notice ?? promptLine).font(.caption).foregroundStyle(notice == nil ? Color.secondary : Color.orange).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if view.myTurn { GameTurnClock(game: game, serverOffsetMs: context.serverOffsetMs) }
                if controls.showIndicator {
                    Button("Göstergeyi göster", systemImage: "eye") { context.move(GameMove.okeyShowIndicator) }
                        .buttonStyle(.bordered).tint(.yellow).frame(minHeight: 44)
                }
                Button("Seri diz") { arrange(OkeyClassicRack.arrangeRuns(hand, okey: view.okey)) }
                    .buttonStyle(.bordered).frame(minHeight: 44).accessibilityHint("Perleri yan yana dizer")
                Button("Çift diz") { arrange(OkeyClassicRack.arrangePairs(hand, okey: view.okey)) }
                    .buttonStyle(.bordered).frame(minHeight: 44).accessibilityHint("Aynı taşları yan yana dizer")
            }
            HStack(alignment: .center, spacing: 8) {
                rack(size)
                actionButtons.frame(width: OkeySizes.actionsWidth)
            }
        }
    }

    private var promptTitle: String {
        guard view.myTurn else { return view.turn.map { "\(name($0)) oynuyor" } ?? "Istakan · \(hand.count) taş" }
        return view.stage == .draw ? "Sıra sende · Taş çek" : "Sıra sende · Taş at"
    }
    private var promptLine: String {
        guard view.myTurn else { return "Istakanı dizebilirsin: taşı basılı tutup sürükle." }
        if view.stage == .draw { return "Ortadan çek ya da soldakinin attığını al." }
        if let id = finisher, let tile = hand.first(where: { $0.id == id }) { return "Bitirebilirsin: \(OkeyClassicText.tileName(tile, okey: view.okey))" }
        return "Bir taş seç ve at, ya da sürükleyip köşene bırak."
    }

    private func rack(_ size: OkeySizes) -> some View {
        let cells = layout
        let byID = Dictionary(hand.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<OkeyClassicRack.columns, id: \.self) { column in
                        let cell = row * OkeyClassicRack.columns + column
                        rackCell(cell: cell, tile: cells[cell].flatMap { byID[$0] }, size: size)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.4, blue: 0.2), Color(red: 0.45, green: 0.27, blue: 0.12)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(view.myTurn ? Palette.accent : Color.black.opacity(0.3), lineWidth: view.myTurn ? 2.5 : 1))
        .animation(animation, value: cells)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Istaka, \(hand.count) taş")
    }

    @ViewBuilder private func rackCell(cell: Int, tile: OkeyTile?, size: OkeySizes) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.rackTile * 0.16)
        Group {
            if let tile {
                GameTileView(tile: tile, width: size.rackTile, selected: selected == tile.id, isOkey: tile.isJoker)
                    .overlay(shape.strokeBorder(finisher == tile.id && view.myTurn ? Color.green : Color.clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(animation) { selected = selected == tile.id ? nil : tile.id } }
                    .draggable(tile.id) { GameTileView(tile: tile, width: size.rackTile * 1.15, isOkey: tile.isJoker) }
                    .accessibilityAddTraits(selected == tile.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint("Seçmek için dokun; taşımak ya da atmak için eylemler")
                    .accessibilityActions { tileActions(tile, cell: cell) }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            } else {
                shape.fill(Color.black.opacity(0.12))
                    .frame(width: size.rackTile, height: size.rackTile * 1.45)
                    .contentShape(Rectangle())
                    .onTapGesture { if let current = selected { arrange(OkeyClassicRack.move(layout, id: current, to: cell)) } }
                    .accessibilityLabel("Seçili taşı buraya taşı")
                    .accessibilityHidden(selected == nil)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, handIDs.contains(id) else { return false }
            arrange(OkeyClassicRack.move(layout, id: id, to: cell))
            return true
        }
    }

    /// VoiceOver path for everything a drag does.
    @ViewBuilder private func tileActions(_ tile: OkeyTile, cell: Int) -> some View {
        let column = cell % OkeyClassicRack.columns
        if context.can("discard") { Button("At") { throwTile(tile.id, finish: false) } }
        if context.can("finish") && OkeyClassicRules.canFinish(hand, with: tile.id, okey: view.okey) { Button("Bitir") { throwTile(tile.id, finish: true) } }
        if column > 0 { Button("Sola taşı") { arrange(OkeyClassicRack.move(layout, id: tile.id, to: cell - 1)) } }
        if column < OkeyClassicRack.columns - 1 { Button("Sağa taşı") { arrange(OkeyClassicRack.move(layout, id: tile.id, to: cell + 1)) } }
        Button(cell < OkeyClassicRack.columns ? "Alt sıraya taşı" : "Üst sıraya taşı") {
            arrange(OkeyClassicRack.move(layout, id: tile.id, to: (cell + OkeyClassicRack.columns) % OkeyClassicRack.cells))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            if view.stage == .draw || !view.myTurn {
                Button { draw(fromDiscard: false) } label: { Label("Taş çek", systemImage: "square.stack.3d.down.right").frame(maxWidth: .infinity, minHeight: 40) }
                    .buttonStyle(.borderedProminent).disabled(!controls.drawStock)
                Button { draw(fromDiscard: true) } label: { Label("Öncekini al", systemImage: "arrow.down.left").frame(maxWidth: .infinity, minHeight: 40) }
                    .buttonStyle(.bordered).disabled(!controls.takeLeft)
            } else {
                Button { if let current = selected { throwTile(current, finish: false) } } label: {
                    Label("At", systemImage: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).disabled(!controls.discard)
                .accessibilityHint(selected == nil ? "Önce bir taş seç" : "Seçili taşı köşene atar")
                Button { if let id = controls.finishTileID { throwTile(id, finish: true) } } label: {
                    Label("Bitir", systemImage: "checkmark.seal.fill").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(controls.finishTileID == nil)
                .accessibilityHint(controls.finishTileID == nil ? "Istaka henüz bitmiyor" : "Eli bitirir")
            }
        }
        .labelStyle(.titleAndIcon).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.8)
    }

    /// Spectators and the finished round: who plays now, or the way back to the summary.
    private var bottomStrip: some View {
        HStack(spacing: 10) {
            if ended {
                Text(OkeyClassicText.endReason(view, name: name)).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                Button("El sonucu", systemImage: "list.number") { summaryOpen = true }.buttonStyle(.bordered).frame(minHeight: 44)
            } else {
                Label("İzliyorsun", systemImage: "eye").font(.subheadline.bold())
                Text(view.turn.map { "\(name($0)) oynuyor" } ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                GameTurnClock(game: game, serverOffsetMs: context.serverOffsetMs)
            }
        }
        .padding(.horizontal, 6).frame(minHeight: 44)
    }

    // MARK: Moves

    private func arrange(_ next: OkeyClassicRack.Layout) {
        withAnimation(animation) { arranged = next }
        store.save(next, for: rackKey)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func draw(fromDiscard: Bool) {
        guard fromDiscard ? controls.takeLeft : controls.drawStock else { return }
        context.move(GameMove.okeyDraw(fromDiscard: fromDiscard))
    }
    /// Throw onto your corner (`finish` false) or into the middle to finish; the server still checks both.
    private func throwTile(_ id: String, finish: Bool) {
        guard handIDs.contains(id), !context.busy else { return }
        if finish {
            guard context.can("finish") else { return }
            guard OkeyClassicRules.canFinish(hand, with: id, okey: view.okey) else {
                notice = "Bu taşı atınca el bitmiyor."
                GameHaptics.refused()
                return
            }
            context.move(GameMove.okeyFinish(tileID: id))
        } else {
            guard context.can("discard") else { return }
            context.move(GameMove.okeyDiscard(tileID: id))
        }
        selected = nil
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(OkeyClassicText.endReason(view, name: name)).font(.headline)
                Spacer()
                Button("Masayı gör") { summaryOpen = false }.buttonStyle(.bordered).frame(minHeight: 44)
            }
            if let shown = view.indicatorShown { Text("\(name(shown.seat)) göstergeyi gösterdi").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let finish = view.finish { openRack(finish) }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow {
                            Text("Oyuncu")
                            Text("Bu el")
                            Text(view.scoring == .countdown ? "Kalan puan" : "Toplam")
                        }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(game.okeySummary(view, me: context.me)) { row in
                            GridRow {
                                Label(row.name, systemImage: row.winner ? "crown.fill" : "person")
                                    .foregroundStyle(row.winner ? Color.yellow : Color.primary)
                                Text(row.points.map(OkeyClassicText.signed) ?? "—").monospacedDigit()
                                Text(row.total.map(String.init) ?? "—").monospacedDigit()
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Text(game.canDeal ? "Yeni eli üstteki çubuktan başlatabilirsin." : "Masa sahibi yeni eli başlatınca taşlar dağıtılır.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// The winner lays the finished rack open: each set, then the finishing tile.
    private func openRack(_ finish: OkeyClassicFinish) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(finish.melds.enumerated()), id: \.offset) { _, meld in
                    HStack(spacing: 1) { ForEach(meld) { GameTileView(tile: $0, width: 26, isOkey: $0.isJoker) } }
                }
                VStack(spacing: 2) {
                    Text("Bitiren taş").font(.caption2).foregroundStyle(.secondary)
                    GameTileView(tile: finish.discard, width: 26, isOkey: finish.discard.isJoker)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(finish.seat)) ıstakası: "
            + finish.melds.map { $0.map { OkeyClassicText.tileName($0, okey: view.okey) }.joined(separator: ", ") }.joined(separator: "; ")
            + ". Bitiren taş: \(OkeyClassicText.tileName(finish.discard, okey: view.okey))")
    }
}

// MARK: - Helpers

private enum OkeyDropKind { case discard, finish }

/// Accepts a dragged rack tile id when enabled.
private struct OkeyDropZone: ViewModifier {
    let enabled: Bool
    let onTarget: (Bool) -> Void
    let onDrop: (String) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                onDrop(id)
                return true
            } isTargeted: { onTarget($0) }
        } else {
            content
        }
    }
}

/// Tile and area sizes from the space the host leaves (landscape phone: roughly 720×300 pt).
private struct OkeySizes {
    static let actionsWidth: CGFloat = 132
    let rackTile: CGFloat
    let feltTile: CGFloat
    let feltHeight: CGFloat
    let avatar: CGFloat
    let middleWidth: CGFloat
    let logLines: Int
    init(_ size: CGSize, rack: Bool) {
        let width = max(320, size.width - 20), height = max(240, size.height - 12)
        if rack {
            // 15 columns beside the action column; the rack (header 44 + two rows) takes at most half the height.
            let byWidth = (width - Self.actionsWidth - 8 - 12) / CGFloat(OkeyClassicRack.columns) - 2
            let byHeight = (height * 0.5 - 44 - 18) / 2 / 1.45
            rackTile = max(22, min(46, byWidth, byHeight))
            feltHeight = max(140, height - (44 + 18 + rackTile * 1.45 * 2) - 10)
        } else {
            rackTile = 30
            feltHeight = max(160, height - 50)
        }
        feltTile = max(22, min(36, (feltHeight - 40) / 4.2))
        avatar = max(24, min(38, feltHeight / 5.5))
        middleWidth = max(200, width * 0.42)
        logLines = feltHeight > 200 ? 3 : 1
    }
}

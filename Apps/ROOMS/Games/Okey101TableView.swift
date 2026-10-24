import SwiftUI
import RoomsCore

/// 101 Okey table (landscape). Mirrors the desktop `games/okey101/OkeyTable.tsx`: opponents around the felt
/// (counter-clockwise, the next player on the right) with their opened melds, a discard pile in each corner (the left
/// player's is the one you may take), the stock and the gösterge, your two-shelf ıstaka (long-press drag, Seri/Çift diz,
/// order kept per round), the opening builder with the server's okey readings, işleme, discard, gösterge and the
/// round summary. Rules, previews and the rack model live in RoomsCore `GamesOkey101.swift`; the server decides.
/// The host already shows the slim bar (back, turn clock, deal/rematch, leave), banners and errors.
struct Okey101TableView: View {
    let context: GameTableContext
    var body: some View {
        if let hand = context.game.okey101 {
            Okey101Table(context: context, hand: hand)
        } else {
            Okey101Idle(context: context)
        }
    }
}

// MARK: - Before the first hand / without access

private struct Okey101Idle: View {
    let context: GameTableContext
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let last = context.game.okey101LastRound {
                    Okey101SummaryCard(info: last, game: context.game, me: context.me, name: historyName, onClose: nil)
                } else {
                    Label(context.game.table.spectatorAccess || context.mySeat != nil
                          ? "Dört koltuk dolunca masa sahibi eli başlatır. Boş koltukları botlar doldurabilir."
                          : "Eli görmek için izleyici olarak katıl ya da boş bir koltuğa otur.", systemImage: "square.grid.3x2")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                }
            }.padding(12)
        }
    }
    /// The finished round's own seats (players may have left since).
    private func historyName(_ position: Int) -> String {
        guard let seat = context.game.history.last?.seats?.first(where: { $0.position == position }) else { return "Koltuk \(position + 1)" }
        return seat.userId == context.me ? "Sen" : seat.name
    }
}

// MARK: - Table

private struct Okey101Table: View {
    let context: GameTableContext
    let hand: Okey101HandView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout = Okey101Rack.empty
    @State private var layoutKey = ""
    @State private var selected: [String] = []
    @State private var drafts: [Okey101Draft] = []
    @State private var pairsMode = false
    @State private var builderOpen = false
    @State private var picked: String?
    @State private var log: [String] = []
    @State private var previousLog: [Okey101PenaltyEntry] = []
    @State private var summaryClosedFor: String?
    private let store = Okey101RackStore()

    private var game: GameState { context.game }
    private var me: String { context.me }
    private var base: Int { context.myPosition ?? 0 }
    private var turn: Int? { game.okey101TurnPosition }
    private var myTurn: Bool { context.myPosition != nil && turn == context.myPosition }
    private var ended: Bool { hand.stage == "ended" || game.status == .finished }
    private var roundKey: String {
        Okey101RackStore.key(ownerID: game.ownerId, round: game.history.count, userID: me, indicatorID: hand.indicator.id)
    }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82) }

    var body: some View {
        let info = game.okey101Info ?? Okey101TableInfo()
        let controls = Okey101Controls(game: game, me: me, busy: context.busy)
        let tiles = game.myOkeyTiles(me)
        GeometryReader { proxy in
            let tileWidth = min(44, max(22, (proxy.size.width - 170) / CGFloat(Okey101Rack.columns) - 3))
            VStack(spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    opponent(.left, info: info, vertical: true)
                    VStack(spacing: 4) {
                        opponent(.top, info: info, vertical: false)
                        felt(info: info, controls: controls, tiles: tiles)
                        moveLog
                    }
                    opponent(.right, info: info, vertical: true)
                }
                .frame(maxHeight: .infinity)
                if context.mySeat != nil && !ended {
                    if builderOpen && myTurn && hand.stage == "discard" {
                        builder(info: info, controls: controls, tiles: tiles)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    rackSection(info: info, controls: controls, tiles: tiles, tileWidth: tileWidth)
                } else if context.spectator {
                    Label("İzliyorsun · oyuncuların taşları gizli", systemImage: "eye").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            .overlay {
                if ended && summaryClosedFor != roundKey {
                    Okey101SummaryCard(info: info, game: game, me: me, name: name) { summaryClosedFor = roundKey }
                        .padding(12)
                        .transition(.opacity)
                }
            }
        }
        .animation(motion, value: builderOpen)
        .onAppear { syncRack(tiles.map(\.id)); previousLog = info.penaltyLog; pairsMode = hand.openedMode(atPosition: context.myPosition) == "pairs" }
        .onChange(of: tiles.map(\.id)) { _, ids in
            syncRack(ids)
            selected.removeAll { !ids.contains($0) }
            drafts.removeAll { draft in draft.ids.contains { !ids.contains($0) } }
        }
        .onChange(of: hand) { old, new in record(from: old, to: new) }
        .onChange(of: "\(hand.stage)|\(turn ?? -1)") { _, _ in
            if hand.stage == "draw" || !myTurn { drafts = []; builderOpen = false; picked = nil }
            if let mode = hand.openedMode(atPosition: context.myPosition) { pairsMode = mode == "pairs" }
        }
        .onChange(of: roundKey) { _, _ in selected = []; drafts = []; picked = nil; log = []; builderOpen = false }
    }

    // MARK: Names, seats

    private func name(_ position: Int) -> String {
        guard let seat = game.seat(atPosition: position) else { return "Koltuk \(position + 1)" }
        return seat.userId == me ? "Sen" : seat.name
    }
    private func count(_ position: Int) -> Int { hand.hands.first { $0.seat == position }?.count ?? 0 }
    private func openedText(_ position: Int) -> String {
        switch hand.openedMode(atPosition: position) {
        case "pairs": "Çift açtı"
        case .some: "Açtı"
        case .none: "Açmadı"
        }
    }

    @ViewBuilder private func opponent(_ place: Okey101Place, info: Okey101TableInfo, vertical: Bool) -> some View {
        let position = place.position(base: context.myPosition)
        let playing = turn == position && !ended
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 8))
        stack {
            if let seat = game.seat(atPosition: position) {
                GameSeatBadge(seat: seat, game: game, chat: context.chat, me: me, size: 32)
            } else {
                Image(systemName: "person.crop.circle.dashed").font(.title2).foregroundStyle(.secondary)
            }
            VStack(spacing: 1) {
                Text("\(count(position)) taş").font(.caption2.monospacedDigit().bold())
                Text(openedText(position)).font(.caption2).foregroundStyle(hand.openedMode(atPosition: position) == nil ? Color.secondary : Palette.accent)
            }
            if playing { GameTurnClock(game: game, serverOffsetMs: context.serverOffsetMs) }
        }
        .frame(minWidth: vertical ? 74 : nil)
        .padding(6)
        .background(playing ? Palette.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name(position)), \(count(position)) taş, \(openedText(position))\(playing ? ", sıra onda" : "")")
    }

    // MARK: Felt

    private func felt(info: Okey101TableInfo, controls: Okey101Controls, tiles: [OkeyTile]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.08, green: 0.36, blue: 0.24))
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color(red: 0.42, green: 0.27, blue: 0.13), lineWidth: 5)
            HStack(spacing: 10) {
                centerPile(info: info, controls: controls)
                meldArea(controls: controls, tiles: tiles)
            }
            .padding(.horizontal, 74).padding(.vertical, 8)
            pile(.top, controls: controls).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            pile(.right, controls: controls).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            pile(.left, controls: controls).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            pile(.bottom, controls: controls).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centerPile(info: Okey101TableInfo, controls: Okey101Controls) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                Button { draw() } label: {
                    ZStack {
                        GameTileView(tile: nil, faceDown: true, width: 30)
                        Text("\(hand.remainingStock)").font(.caption.monospacedDigit().bold()).foregroundStyle(Color.black.opacity(0.7))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(controls.drawStock ? Color.yellow : Color.clear, lineWidth: 2))
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).disabled(!controls.drawStock)
                .accessibilityLabel("Kapalı taş çek, \(hand.remainingStock) taş")
                VStack(spacing: 2) {
                    GameTileView(tile: hand.indicator, width: 30)
                    Text("Gösterge").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Gösterge \(hand.indicator.color.title) \(hand.indicator.value), okey \(hand.indicator.color.title) \(hand.jokerValue)")
            }
            Text(badgeLine(info)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)).lineLimit(2).multilineTextAlignment(.center)
        }
    }
    private func badgeLine(_ info: Okey101TableInfo) -> String {
        ([info.folding ? "Katlamalı" : "Katlamasız", info.teams ? "Eşli" : "Tekli", "Açılış \(info.openingThreshold)", "\(info.requiredPairs) çift",
          "El \(game.history.count + (ended ? 0 : 1))"] + info.house.badges).joined(separator: " · ")
    }

    /// The pile in the corner after `place`'s owner; the left player's pile is takeable in your draw turn.
    private func pile(_ place: Okey101Place, controls: Okey101Controls) -> some View {
        let position = place.position(base: context.myPosition)
        let top = hand.discards.indices.contains(position) ? hand.discards[position].last : nil
        let takeable = place == .left && controls.takeSide && top != nil
        let mine = place == .bottom && context.mySeat != nil
        let last = hand.stage == "draw" && turn.map { ($0 + 3) % 4 } == position
        return VStack(spacing: 2) {
            Text(mine ? "Attığın" : "\(name(position)) attı").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if let top {
                Button { if takeable { takeSide(top) } } label: {
                    GameTileView(tile: top, width: 30)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(takeable ? Color.yellow : last ? Color.white.opacity(0.8) : Color.clear, lineWidth: 2))
                        .frame(minWidth: 44, minHeight: 46)
                }
                .buttonStyle(.plain).disabled(!takeable)
                .accessibilityLabel("\(mine ? "Attığın" : name(position) + " attı"): \(top.okey101Label)")
                .accessibilityHint(takeable ? "Bu taşı al; bu el kullanmalısın" : "")
            } else {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .frame(width: 30, height: 43)
                    .overlay(Text(mine && controls.discard ? "At" : "—").font(.caption2).foregroundStyle(.white.opacity(0.6)))
            }
            if takeable { Text("Al").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow) }
        }
        .padding(6)
        .dropDestination(for: String.self) { items, _ in
            guard mine, controls.discard, let id = items.first, game.myOkeyTiles(me).contains(where: { $0.id == id }), !draftIDs.contains(id) else { return false }
            discard(id); return true
        }
    }

    /// Opened melds grouped by owner (top, left, right, you), each meld a target for işleme.
    private func meldArea(controls: Okey101Controls, tiles: [OkeyTile]) -> some View {
        let owners = [Okey101Place.top, .left, .right, .bottom].map { $0.position(base: context.myPosition) }
            .filter { owner in hand.melds.contains { $0.owner == owner } }
        return Group {
            if owners.isEmpty {
                Text("Henüz per açılmadı.").font(.caption).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(owners, id: \.self) { owner in
                            HStack(alignment: .center, spacing: 6) {
                                Text("\(name(owner)) · \(hand.melds.first { $0.owner == owner }?.pairs == true ? "Çift" : "Seri")")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).frame(width: 64, alignment: .leading).lineLimit(1)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(Array(hand.melds.enumerated()).filter { $0.element.owner == owner }, id: \.offset) { index, meld in
                                            meldView(index: index, meld: meld, controls: controls, tiles: tiles)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func meldView(index: Int, meld: OkeyMeld, controls: Okey101Controls, tiles: [OkeyTile]) -> some View {
        let takes = controls.process && !meld.pairs
        let selection = Okey101Opening.rackOrder(selected, layout: layout)
        let canSend = takes && !selection.isEmpty && selection.count < tiles.count && !selection.contains(where: draftIDs.contains)
        let jokers = meld.tiles.filter(\.isJoker)
        return Button { if canSend { process(index, selection) } } label: {
            HStack(spacing: 1) {
                ForEach(meld.tiles) { tile in GameTileView(tile: tile, width: 18) }
            }
            .padding(3)
            .background(canSend ? Color.yellow.opacity(0.35) : Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .contextMenu {
            if takes && !jokers.isEmpty {
                ForEach(jokers) { joker in
                    let natural = selection.count == 1 ? tiles.first { $0.id == selection[0] && !$0.isJoker && $0.color == joker.color && $0.value == joker.value } : nil
                    Button("Okeyi değiştir · \(joker.color.title) \(joker.value)", systemImage: "arrow.triangle.swap") {
                        if let natural { process(index, [natural.id], replacing: joker.id) }
                    }.disabled(natural == nil)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard takes, let id = items.first, tiles.contains(where: { $0.id == id }), tiles.count > 1, !draftIDs.contains(id) else { return false }
            process(index, [id]); return true
        }
        .accessibilityLabel("Per \(index + 1): \(meld.tiles.map(\.okey101Label).joined(separator: ", "))")
        .accessibilityHint(canSend ? "Seçili taşları bu pere işle" : takes ? "İşlemek için ıstakadan taş seç" : "")
    }

    @ViewBuilder private var moveLog: some View {
        if !log.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(log.prefix(2).enumerated()), id: \.offset) { index, line in
                    Text(line).font(.caption2).foregroundStyle(index == 0 ? Color.primary : Color.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Son hamleler: \(log.prefix(2).joined(separator: ". "))")
        }
    }

    // MARK: Opening builder

    private var draftIDs: Set<String> { Set(drafts.flatMap(\.ids)) }

    private func builder(info: Okey101TableInfo, controls: Okey101Controls, tiles: [OkeyTile]) -> some View {
        let opened = hand.openedMode(atPosition: context.myPosition)
        let check = Okey101Opening.evaluate(drafts: drafts, hand: tiles, pairs: pairsMode, opened: opened, info: info)
        let canOpen = pairsMode ? controls.openPairs : controls.openRuns
        let wrap = info.house.wrapAround
        let selectionOK = pairsMode ? selected.count == 2 : selected.count >= 3
        let rackSets = Okey101Rack.validBlocks(layout, hand: tiles, excluding: draftIDs, pairs: pairsMode, wrapAround: wrap)
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                modeButton("Seri", pairs: false, enabled: opened == nil || opened == "runs")
                modeButton("Çift", pairs: true, enabled: opened == nil || opened == "pairs")
            }
            .background(Palette.raised, in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                        draftChip(index: index, draft: draft, resolved: check.resolved.indices.contains(index) ? check.resolved[index] : nil, tiles: tiles, wrap: wrap)
                    }
                    Button(pairsMode ? "Seçimi çift yap" : "Seçimi seri yap") {
                        drafts.append(Okey101Opening.draft(selected, hand: tiles, layout: layout, pairs: pairsMode, wrapAround: wrap)); selected = []
                    }
                    .buttonStyle(.bordered).font(.caption.bold()).frame(minHeight: 44)
                    .disabled(!canOpen || !selectionOK || selected.contains(where: draftIDs.contains))
                    Button("Istakadaki dizileri al") {
                        drafts += rackSets.map { Okey101Opening.draft($0, hand: tiles, layout: layout, pairs: pairsMode, wrapAround: wrap) }
                    }
                    .buttonStyle(.bordered).font(.caption.bold()).frame(minHeight: 44)
                    .disabled(!canOpen || rackSets.isEmpty)
                }
            }
            Text(check.line).font(.caption2.bold()).foregroundStyle(check.ready ? Color.green : drafts.isEmpty ? Color.secondary : Color.orange)
                .frame(maxWidth: 150, alignment: .trailing).lineLimit(2).multilineTextAlignment(.trailing)
                .accessibilityAddTraits(.updatesFrequently)
            Button(pairsMode ? "Çift aç" : "Seri aç") { open() }
                .buttonStyle(.borderedProminent).font(.footnote.bold()).frame(minHeight: 44)
                .disabled(!canOpen || !check.ready)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func modeButton(_ title: String, pairs: Bool, enabled: Bool) -> some View {
        Button(title) { pairsMode = pairs; drafts = []; selected = [] }
            .font(.caption.bold()).padding(.horizontal, 12).frame(minHeight: 44)
            .background(pairsMode == pairs ? Palette.accent.opacity(0.35) : Color.clear, in: Capsule())
            .disabled(!enabled)
            .accessibilityAddTraits(pairsMode == pairs ? .isSelected : [])
    }
    private func draftChip(index: Int, draft: Okey101Draft, resolved: [OkeyTile]?, tiles: [OkeyTile], wrap: Bool) -> some View {
        let raw = draft.ids.compactMap { id in tiles.first { $0.id == id } }
        let ambiguous = !pairsMode && Okey101Preview.isAmbiguous(raw, wrapAround: wrap)
        return HStack(spacing: 4) {
            HStack(spacing: 1) { ForEach(resolved ?? raw) { tile in GameTileView(tile: tile, width: 18) } }
            if ambiguous {
                Menu {
                    Button("Sıralı") { setKind(index, .run) }
                    Button("Aynı sayı") { setKind(index, .group) }
                } label: {
                    Label(draft.kind == .group ? "Aynı sayı" : "Sıralı", systemImage: "chevron.up.chevron.down").font(.caption2.bold())
                }
                .accessibilityLabel("Okey nasıl okunsun? Per \(index + 1): \(draft.kind == .group ? "Aynı sayı" : "Sıralı")")
            }
            Button { drafts.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44) }
                .accessibilityLabel("Grup \(index + 1) kaldır")
        }
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(resolved == nil ? Color.orange : Color.green.opacity(0.7)))
    }
    private func setKind(_ index: Int, _ kind: OkeyMeldKind) { if drafts.indices.contains(index) { drafts[index].kind = kind } }

    // MARK: Rack

    private func rackSection(info: Okey101TableInfo, controls: Okey101Controls, tiles: [OkeyTile], tileWidth: CGFloat) -> some View {
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let warning = Okey101Controls.pickupWarning(picked: picked, game: game, me: me)
        return HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Istakan · \(tiles.count) taş").font(.caption.bold())
                    Button("Seri diz") { arrange(Okey101Rack.arrangeRuns(tiles, wrapAround: info.house.wrapAround)) }
                        .buttonStyle(.bordered).font(.caption.bold()).frame(minHeight: 40)
                    Button("Çift diz") { arrange(Okey101Rack.arrangePairs(tiles)) }
                        .buttonStyle(.bordered).font(.caption.bold()).frame(minHeight: 40)
                    if controls.gosterge {
                        Button("Göstergeyi göster") { context.act(.gosterge) }
                            .buttonStyle(.bordered).tint(.yellow).font(.caption.bold()).frame(minHeight: 40)
                            .accessibilityHint("Göstergenin eşini gösterip 101 puan düşürürsün")
                    }
                    if controls.undoPick {
                        Button(controls.undoCostsPenalty ? "Geri bırak, kapalı çek (+101)" : "Geri bırak, kapalı çek") { context.act(.draw) }
                            .buttonStyle(.bordered).tint(.orange).font(.caption.bold()).frame(minHeight: 40)
                    }
                    Text(statusText(warning: warning)).font(.caption2).foregroundStyle(warning ? Color.orange : Color.secondary).lineLimit(2)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<Okey101Rack.columns, id: \.self) { column in
                                cell(row * Okey101Rack.columns + column, byID: byID, width: tileWidth, controls: controls)
                            }
                        }
                    }
                }
                .padding(5)
                .background(LinearGradient(colors: [Color(red: 0.62, green: 0.42, blue: 0.22), Color(red: 0.45, green: 0.29, blue: 0.14)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8))
                .animation(motion, value: layout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Istaka")
            }
            actions(controls: controls, tiles: tiles)
        }
    }

    private func statusText(warning: Bool) -> String {
        if warning { return "Yandan aldığın taşı bu el kullan; kullanmazsan +101 yazılır." }
        if let mode = hand.openedMode(atPosition: context.myPosition) { return mode == "pairs" ? "Çift açtın" : "Seri açtın" }
        if myTurn && hand.stage == "draw" { return "Ortadan çek ya da soldakinin attığını al." }
        return "Henüz açmadın · Taşı basılı tutup sürükleyerek diz."
    }

    @ViewBuilder private func cell(_ index: Int, byID: [String: OkeyTile], width: CGFloat, controls: Okey101Controls) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.16)
        if let id = layout[index], let tile = byID[id] {
            let inDraft = draftIDs.contains(id)
            GameTileView(tile: tile, width: width, selected: selected.contains(id) || inDraft, dimmed: inDraft)
                .overlay(alignment: .top) {
                    if id == picked { Circle().fill(Color.orange).frame(width: 6, height: 6).offset(y: -4) }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !inDraft { toggle(id) } }
                .draggable(id) { GameTileView(tile: tile, width: width, selected: true) }
                .dropDestination(for: String.self) { items, _ in moveDropped(items, to: index, byID: byID) }
                .accessibilityAddTraits(selected.contains(id) ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(inDraft ? "Açılış grubunda" : "Seçmek için dokun")
                .accessibilityAction(named: "At") { if controls.discard && !inDraft { discard(id) } }
        } else {
            shape.fill(Color.black.opacity(0.16))
                .frame(width: width, height: width * 1.45)
                .contentShape(Rectangle())
                .onTapGesture { if selected.count == 1 { layoutMove(selected[0], to: index); selected = [] } }
                .dropDestination(for: String.self) { items, _ in moveDropped(items, to: index, byID: byID) }
                .accessibilityLabel(selected.count == 1 ? "Boş yer · seçili taşı buraya taşı" : "Boş yer")
                .accessibilityHidden(selected.count != 1)
        }
    }
    private func moveDropped(_ items: [String], to index: Int, byID: [String: OkeyTile]) -> Bool {
        guard let id = items.first, byID[id] != nil else { return false }
        layoutMove(id, to: index); return true
    }

    private func actions(controls: Okey101Controls, tiles: [OkeyTile]) -> some View {
        let one = selected.count == 1 && !draftIDs.contains(selected[0])
        return VStack(spacing: 6) {
            Text(myTurn ? (hand.stage == "draw" ? "Taş çek" : "Taş at") : turn.map { "\(name($0)) oynuyor" } ?? "—")
                .font(.caption.bold()).lineLimit(1)
            if hand.stage == "draw" {
                Button("Kapalı taş çek") { draw() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44).disabled(!controls.drawStock)
                Button("Önceki taşı al") { if let top = hand.takeableDiscard(forPosition: base) { takeSide(top) } }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44).disabled(!controls.takeSide)
            } else {
                Button(tiles.count == 1 ? "Bitir · Son taşı at" : "Seçili taşı at") { if one { discard(selected[0]) } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44).disabled(!controls.discard || !one)
                Button(builderOpen ? "Açılışı kapat" : hand.openedMode(atPosition: context.myPosition) == nil ? "Açılış hazırla" : "Per aç") { builderOpen.toggle() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(!(controls.openRuns || controls.openPairs))
            }
        }
        .font(.footnote.bold())
        .frame(width: 150)
    }

    // MARK: Moves

    private func toggle(_ id: String) {
        if let index = selected.firstIndex(of: id) { selected.remove(at: index) } else { selected.append(id) }
        GameHaptics.tap()
    }
    private func draw() { picked = nil; context.act(.draw) }
    private func takeSide(_ top: OkeyTile) { picked = top.id; context.act(.takeDiscard) }
    private func discard(_ id: String) {
        selected.removeAll { $0 == id }
        GameSounds.play(.tile)
        context.act(.discard(tileID: id))
    }
    private func process(_ meld: Int, _ ids: [String], replacing joker: String? = nil) {
        selected = []
        context.act(.process(meld: meld, tileIDs: ids, replacingJoker: joker))
    }
    private func open() {
        let melds = drafts.map(\.ids)
        if pairsMode { context.act(.openPairs(melds)) } else { context.act(.open(melds: melds, kinds: Okey101Opening.kinds(drafts, pairs: false))) }
        selected = []
    }

    private func layoutMove(_ id: String, to index: Int) { arrange(Okey101Rack.move(layout, id: id, to: index)) }
    private func arrange(_ next: Okey101Rack.Layout) {
        layout = next
        store.save(roundKey, layout: next)
        GameSounds.play(.tile)
    }
    /// Keep the player's order for this round; new tiles go to the first free cell, gone ones leave.
    private func syncRack(_ ids: [String]) {
        let key = roundKey
        let saved = layoutKey == key ? layout : store.load(key)
        layout = Okey101Rack.reconcile(saved, ids: ids)
        layoutKey = key
        store.save(key, layout: layout)
    }
    private func record(from old: Okey101HandView, to new: Okey101HandView) {
        let newLog = game.okey101Info?.penaltyLog ?? []
        defer { previousLog = newLog }
        guard old.indicator.id == new.indicator.id else { log = []; return }
        let lines = Okey101MoveLog.describe(before: old, beforeLog: previousLog, after: new, afterLog: newLog, name: name)
        guard !lines.isEmpty else { return }
        log = Array((lines.reversed() + log).prefix(5))
    }
}

// MARK: - Round summary

private struct Okey101SummaryCard: View {
    let info: Okey101TableInfo
    let game: GameState
    let me: String
    let name: (Int) -> String
    let onClose: (() -> Void)?
    var body: some View {
        let totals = game.okey101Totals
        let seats = game.history.last?.seats
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Okey101Summary.endingLine(info, name: name)).font(.headline)
                    if let multiplier = Okey101Summary.multiplierLine(info) {
                        Text(multiplier).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(Color.orange.opacity(0.3), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if let onClose {
                        Button("Masaya dön", action: onClose).buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
                Text(Okey101Summary.ruleLine(info)).font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Oyuncu"); Text("Durum"); Text("Ceza"); Text("Puan"); Text("Toplam")
                    }.font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Okey101Summary.rows(info)) { row in
                        let user = seats?.first { $0.position == row.position }?.userId ?? game.seat(atPosition: row.position)?.userId
                        GridRow {
                            Text(name(row.position)).bold(row.winner)
                            Text(row.status)
                            Text(row.penalty == 0 ? "—" : Okey101Summary.signed(row.penalty)).foregroundStyle(row.penalty < 0 ? Color.green : row.penalty > 0 ? Color.orange : Color.secondary)
                            Text(row.score.map(String.init) ?? "—").monospacedDigit().bold()
                            Text(user.flatMap { totals[$0] }.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                    }
                }
                if !info.penaltyLog.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cezalar ve bonuslar").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(Array(info.penaltyLog.enumerated()), id: \.offset) { _, entry in
                            Text("\(name(entry.seat)) · \(entry.reasonTitle) · \(Okey101Summary.signed(entry.amount))")
                                .font(.caption).foregroundStyle(entry.amount < 0 ? Color.green : Color.orange)
                        }
                    }
                }
                Text("Puanı düşük olan önde. Yeni eli masa sahibi üst çubuktan başlatır.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("El sonucu")
    }
}

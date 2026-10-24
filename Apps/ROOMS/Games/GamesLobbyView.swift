import SwiftUI
import RoomsCore

/// Kıraathane for one voice room (desktop `games/shared/Lobby.tsx`): the room's table (one per room), the
/// catalog of games, and table setup with each game's options. Opening the table pushes `GameTableHost`.
/// Closing this screen never touches the voice connection.
struct GamesLobbyView: View {
    @ObservedObject var watch: WatchTogetherModel
    let chat: ChatController
    let roomName: String
    @Environment(\.dismiss) private var dismiss
    @State private var creating: GameKind?
    @State private var tableOpen = false

    private var room: ActivityRoom? { watch.room }
    private var game: GameState? { room?.game }
    /// Another activity (cinema, watch party, screen) holds the room.
    private var otherActivity: ActivityPrimary? { room?.primary.flatMap { $0.isGame || game != nil ? nil : $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let failure = watch.failure, !tableOpen { Notice(text: failure) }
                    tableSection
                    catalog
                    Text("Oyun penceresini kapatmak ses bağlantını kesmez.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .background(Palette.rail.ignoresSafeArea())
            .navigationTitle("Oyunlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
            .navigationDestination(isPresented: $tableOpen) { GameTableHost(watch: watch, chat: chat) }
            .sheet(item: $creating) { kind in
                GameCreateSheet(kind: kind, replacing: otherActivity, canReplace: watch.canEnd) { setup, replacing in
                    try await watch.send(.game(.create(setup, replacing: replacing)))
                    creating = nil; tableOpen = true
                }
            }
        }
        .task { watch.start() }
        .onChange(of: game == nil) { _, closed in if closed { tableOpen = false } }
    }

    // MARK: The room's table

    @ViewBuilder private var tableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ODANIN MASASI").font(.caption.bold()).foregroundStyle(.secondary)
            if room == nil {
                HStack(spacing: 10) {
                    if watch.failure == nil { ProgressView() }
                    Text(watch.failure == nil ? "Masalar getiriliyor…" : "Oyun hizmeti bağlantısı bekleniyor.").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            } else if let game {
                Button { tableOpen = true } label: { tableCard(game) }.buttonStyle(.plain)
                    .accessibilityHint("Masayı açar")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Açık oyun masası yok").font(.subheadline.bold())
                    Text(otherActivity.map { "Bu odada \($0.title) etkinliği açık." } ?? "Bir oyun seçerek \(roomName) odasında masa kurabilirsin.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private func tableCard(_ game: GameState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(game.kind)).font(.title2).foregroundStyle(Palette.accent).frame(width: 44, height: 44)
                .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.table.tableName ?? game.kind.title).font(.headline).lineLimit(1)
                Text("\(game.kind.title) · \(game.seats.count)/\(game.capacity) koltuk · \(statusText(game))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: -8) {
                    ForEach(game.orderedSeats.prefix(6)) { seat in
                        ChatAvatarView(chat: chat, userID: seat.userId, name: seat.name, size: 22).overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(game.seat(of: watch.me) == nil ? "Masaya git" : "Masaya dön").font(.footnote.bold()).foregroundStyle(Palette.accent)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private func statusText(_ game: GameState) -> String {
        switch game.status {
        case .waiting: "Oyuncular bekleniyor"
        case .playing: game.isMyTurn(watch.me) ? "Sıra sende" : "Oyun sürüyor"
        case .finished: "El tamamlandı"
        case .unknown: "Güncelleniyor"
        }
    }

    // MARK: Catalog

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OYUNLAR").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(GameKind.allCases, id: \.rawValue) { kind in
                    Button { creating = kind } label: { catalogCard(kind) }.buttonStyle(.plain)
                        .disabled(!canCreate)
                        .accessibilityHint(createBlockReason ?? "Masa kurar")
                }
            }
            if let reason = createBlockReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func catalogCard(_ kind: GameKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon(kind)).font(.title3).foregroundStyle(Palette.accent)
            Text(kind.title).font(.headline).lineLimit(1)
            Text(kind.playersLine).font(.caption.bold()).foregroundStyle(.secondary)
            Text(kind.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .opacity(canCreate ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private var canCreate: Bool { createBlockReason == nil }
    /// Why no table can be set up right now (one table per room; another activity needs its host to end it).
    private var createBlockReason: String? {
        guard let room else { return "Etkinlik bağlantısı bekleniyor." }
        if game != nil { return "Bu odada zaten bir masa var. Yeni oyun için önce masa kapanmalı." }
        if !room.canStart(watch.me) { return "Bu odada etkinlik başlatma iznin yok." }
        if otherActivity != nil && !watch.canEnd { return "Açık etkinliği yalnızca hostu kapatabilir. Kapatıldığında masa açabilirsin." }
        return nil
    }
    private func icon(_ kind: GameKind) -> String {
        switch kind {
        case .holdem: "suit.spade.fill"
        case .blackjack: "suit.club.fill"
        case .batak: "suit.heart.fill"
        case .pisti: "suit.diamond.fill"
        case .okey101, .okey: "rectangle.grid.3x2.fill"
        case .tavla: "dice.fill"
        case .unknown: "questionmark.square"
        }
    }
}

// MARK: - Seats

/// Free seats with "Otur" (and "Bot ekle" for the owner), shown between hands and to anyone not seated.
/// Hold'em with a buy-in range sits through the table's buy-in sheet (`game.sit {seat, buyIn}`), like its empty seats.
struct GameSeatPicker: View {
    @ObservedObject var watch: WatchTogetherModel
    let chat: ChatController
    let game: GameState
    let roomHost: Bool
    @State private var buyIn: HoldemBuyInTarget?
    private var seated: Bool { game.seat(of: watch.me) != nil }
    private func sit(_ number: Int) {
        GameHaptics.tap()
        if game.kind == .holdem, let range = HoldemBuyIn.range(game.table.rules), range.lowerBound < range.upperBound {
            buyIn = HoldemBuyInTarget(seat: number, rebuy: false)
        } else {
            // Other games, or a fixed Hold'em buy-in: the service seats with the table's starting stack.
            watch.run(.game(.sit(seat: number)))
        }
    }
    var body: some View {
        seats.sheet(item: $buyIn) { target in
            if let range = HoldemBuyIn.range(game.table.rules) {
                HoldemBuyInSheet(target: target, range: range, initial: HoldemBuyIn.initial(game.table.rules) ?? range.lowerBound,
                                 step: max(1, game.table.rules?.bigBlind ?? 20), chips: 0, playing: game.status == .playing, busy: watch.busy) { amount in
                    buyIn = nil
                    GameHaptics.tap()
                    watch.run(.game(.sit(seat: target.seat, buyIn: amount)))
                }
                .presentationDetents([.height(340)])
            }
        }
    }
    @ViewBuilder private var seats: some View {
        let free = game.freeSeats
        if !free.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Boş koltuklar").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(free, id: \.self) { number in
                            VStack(spacing: 6) {
                                Text("Koltuk \(number + 1)").font(.caption.bold())
                                Button("Otur") { sit(number) }
                                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).font(.footnote.bold())
                                    .disabled(seated || watch.busy)
                                if game.isOwner(watch.me) {
                                    Button("Bot ekle") { watch.run(.game(.addBot(seat: number))) }.buttonStyle(.bordered).font(.footnote).disabled(watch.busy)
                                }
                            }.padding(10).frame(minWidth: 96).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if seated { Text("Zaten masadasın.").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Table setup

/// The options every game's `game.create` can carry, with the service defaults.
struct GameSetupDraft {
    var holdemCapacity = HoldemTableRules.standard.capacity
    var muckLosers = false
    var blackjack = BlackjackTableOptions.standard
    var batakVariant = BatakVariant.ihaleli
    var batakRules = BatakHouseRules.standard
    var folding = false
    var teams = false
    var pisti = PistiTableOptions()
    var okey = OkeyTableOptions()
    var tavla = TavlaTableOptions()

    func setup(_ kind: GameKind) -> GameSetup? {
        switch kind {
        case .holdem:
            var rules = HoldemTableRules.standard
            rules.capacity = min(9, max(2, holdemCapacity))
            return .holdem(rules, muckLosers: muckLosers)
        case .blackjack: return .blackjack(blackjack)
        case .batak: return .batak(batakVariant, rules: batakRules)
        case .okey101: return .okey101(folding: folding, teams: teams)
        case .pisti: return .pisti(pisti)
        case .okey: return .okey(okey)
        case .tavla: return .tavla(tavla)
        case .unknown: return nil
        }
    }
}

/// Per-game table rules, then "Masa kur". When another activity holds the room, its host confirms ending it.
struct GameCreateSheet: View {
    let kind: GameKind
    let replacing: ActivityPrimary?
    let canReplace: Bool
    let create: @MainActor (GameSetup, GameReplacement?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GameSetupDraft()
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(kind.detail).font(.footnote).foregroundStyle(.secondary) } header: { Text(kind.playersLine) }
                options
                if let replacing {
                    Section {
                        Text(canReplace ? "Masa kurulunca odadaki \(replacing.title) etkinliği herkes için biter." : "Açık etkinliği yalnızca hostu kapatabilir.")
                            .font(.footnote).foregroundStyle(canReplace ? Color.orange : Color.secondary)
                    }
                }
                if let failure { Section { Text(failure).font(.footnote).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden).background(Palette.rail)
            .navigationTitle("\(kind.title) masası")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() }
                    else { Button(replacing == nil ? "Masa kur" : "Bitir ve kur") { submit() }.bold().disabled(draft.setup(kind) == nil || (replacing != nil && !canReplace)) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var options: some View {
        switch kind {
        case .holdem:
            Section("Masa kuralları") {
                Stepper("Koltuk: \(draft.holdemCapacity)", value: $draft.holdemCapacity, in: 2...9)
                LabeledContent("Kör bahisler", value: "\(HoldemTableRules.standard.smallBlind) / \(HoldemTableRules.standard.bigBlind)")
                LabeledContent("Masaya giriş", value: "\(HoldemTableRules.standard.initialChips) sanal fiş")
                Toggle("Kaybeden eller gizlensin", isOn: $draft.muckLosers)
            }
        case .blackjack:
            Section("Masa kuralları") {
                Toggle("Sigorta", isOn: $draft.blackjack.insurance)
                Text(draft.blackjack.insurance ? "Krupiye As gösterince her oyuncuya sorulur, 2:1 öder." : "Sigorta sorulmaz.").font(.caption).foregroundStyle(.secondary)
                Toggle("Teslim", isOn: $draft.blackjack.surrender)
                Text(draft.blackjack.surrender ? "İlk iki kartta el bırakılır, bahsin yarısı geri gelir." : "El sonuna kadar oynanır.").font(.caption).foregroundStyle(.secondary)
            }
        case .batak:
            Section("Batak türü") {
                Picker("Tür", selection: $draft.batakVariant) {
                    ForEach(BatakVariant.allCases, id: \.self) { variant in Text("\(variant.title) · \(variant.players) oyuncu").tag(variant) }
                }.pickerStyle(.inline).labelsHidden()
            }
            Section("Masa kuralları") {
                Toggle("Koz kırılmadan koz açılmaz", isOn: $draft.batakRules.noTrumpLeadUntilBroken)
                Toggle("Savunma batağı", isOn: $draft.batakRules.defenderBatakPenalty).disabled(draft.batakVariant == .kozMaca)
                Toggle("İhale kadar yaz", isOn: $draft.batakRules.writeContract).disabled(draft.batakVariant == .kozMaca)
                if draft.batakVariant == .kozMaca { Text("Koz Maça her oyuncunun kendi tahminiyle yazılır.").font(.caption).foregroundStyle(.secondary) }
            }
        case .okey101:
            Section("Masa kuralları") {
                Toggle("Katlamalı", isOn: $draft.folding)
                Text(draft.folding ? "Önceki açılış toplamını geç." : "Açılış en az 101.").font(.caption).foregroundStyle(.secondary)
                Toggle("Eşli", isOn: $draft.teams)
                Text(draft.teams ? "2 + 2 oyuncu, eşler karşılıklı." : "4 oyuncu, herkes kendi için.").font(.caption).foregroundStyle(.secondary)
            }
        case .pisti:
            Section("Maç") {
                Picker("Maç hedefi", selection: $draft.pisti.target) {
                    ForEach(PistiTableOptions.targets, id: \.self) { target in Text("\(target) puan").tag(target) }
                }.pickerStyle(.segmented)
                Toggle("Vale desteye döner", isOn: $draft.pisti.reshuffleJackTop)
                Text(draft.pisti.reshuffleJackTop ? "Açılışta üstteki kart vale çıkarsa desteye karışır." : "Açılıştaki vale ilk alana gider.").font(.caption).foregroundStyle(.secondary)
            }
        case .okey:
            Section("Puan") {
                Picker("Puan türü", selection: $draft.okey.scoring) {
                    ForEach(OkeyScoring.allCases, id: \.self) { scoring in Text(scoring.title).tag(scoring) }
                }.pickerStyle(.segmented)
                Text(draft.okey.scoring == .countdown ? "Herkes 20 ile başlar, bitiren diğerlerinden düşer." : "Düz puan tablosu: bitiren 1 puan alır.").font(.caption).foregroundStyle(.secondary)
            }
        case .tavla:
            Section("Maç") {
                Picker("Maç uzunluğu", selection: $draft.tavla.matchTo) {
                    ForEach(TavlaTableOptions.targets, id: \.self) { target in Text("\(target) puan").tag(target) }
                }.pickerStyle(.segmented)
                Toggle("Başlayan yeniden atar", isOn: $draft.tavla.starterRerolls)
                Text(draft.tavla.starterRerolls ? "Büyük atan iki zarı yeniden atar." : "Büyük atan iki açılış zarını oynar.").font(.caption).foregroundStyle(.secondary)
            }
        case .unknown:
            Section { Text("Bu oyun bu sürümde kurulamıyor.").font(.footnote) }
        }
    }

    private func submit() {
        guard let setup = draft.setup(kind) else { return }
        let replacement = replacing.flatMap { GameReplacement($0) }
        if replacing != nil && replacement == nil { failure = "Odadaki etkinlik okunamadı. Yeniden dene."; return }
        working = true; failure = nil
        Task {
            defer { working = false }
            do { GameHaptics.tap(); try await create(setup, replacement) }
            catch { failure = error.localizedDescription; GameHaptics.refused() }
        }
    }
}

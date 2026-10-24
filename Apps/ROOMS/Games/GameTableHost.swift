import SwiftUI
import RoomsCore

/// The room's table: shared header (game, seats with avatars, turn clock), spectator and recovery banners,
/// the server's error text, the seat picker between hands, and leave/rematch as `legalActions` allow. The
/// table itself is the per-game view `GameTableHost.table(_:)` routes to.
struct GameTableHost: View {
    @ObservedObject var watch: WatchTogetherModel
    let chat: ChatController
    @State private var confirmLeave = false

    private var game: GameState? { watch.room?.game }
    private var me: String { watch.me }
    /// The room's activity host may free seats like the table owner (desktop `SeatControlsContext`).
    private var roomHost: Bool { watch.room?.primary?.hostUserId == me }

    var body: some View {
        Group {
            if let game {
                let context = GameTableContext(game: game, me: me, chat: chat, serverOffsetMs: watch.serverOffsetMs, busy: watch.busy) { command in watch.run(.game(command)) }
                VStack(spacing: 0) {
                    header(game)
                    banners(game)
                    Self.table(context).frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer(game)
                }
                .onChange(of: game.isMyTurn(me)) { _, mine in if mine { GameHaptics.yourTurn(); GameSounds.play(.turn) } }
                .onChange(of: watch.failure) { _, failure in if failure != nil { GameHaptics.refused() } }
                .onAppear { if game.kind.prefersLandscape { GameOrientation.request(.landscape) } }
                .onDisappear { if game.kind.prefersLandscape { GameOrientation.request(.portrait) } }
            } else {
                ContentUnavailableView("Masa kapandı", systemImage: "suit.club", description: Text("Bu odada açık oyun masası yok. Oyunlardan yeni bir masa kurabilirsin."))
            }
        }
        .background(Palette.rail.ignoresSafeArea())
        .navigationTitle(game.map { $0.table.tableName ?? $0.kind.title } ?? "Masa")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Masadan kalkılsın mı?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Masadan kalk", role: .destructive) { watch.run(.game(.leave)) }
        } message: {
            Text(game?.status == .playing ? "El sürüyor; elini bir bot bitirir." : "Koltuğun boşalır.")
        }
    }

    /// Routes a table to its game's view. Each per-game track replaces only its own view file.
    @MainActor @ViewBuilder static func table(_ context: GameTableContext) -> some View {
        switch context.game.kind {
        case .holdem: HoldemTableView(context: context)
        case .blackjack: BlackjackTableView(context: context)
        case .batak: BatakTableView(context: context)
        case .okey101: Okey101TableView(context: context)
        case .pisti: PistiTableView(context: context)
        case .okey: OkeyTableView(context: context)
        case .tavla: TavlaTableView(context: context)
        case .unknown: GameComingSoon(kind: context.game.kind)
        }
    }

    // MARK: Header

    private func header(_ game: GameState) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.kind.title).font(.headline).lineLimit(1)
                    Text(statusLine(game)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GameTurnClock(game: game, serverOffsetMs: watch.serverOffsetMs)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(game.orderedSeats) { seat in
                        GameSeatBadge(seat: seat, game: game, chat: chat, me: me, size: 36,
                                      onRemove: game.canRemove(seat, viewer: me, roomHost: roomHost) ? { watch.run(.game(.removeSeat(seat: seat.seat))) } : nil)
                    }
                }.padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(Palette.surface)
    }
    private func statusLine(_ game: GameState) -> String {
        if let series = game.table.series, series.finished { return "Maç bitti" }
        switch game.status {
        case .waiting: return game.seats.isEmpty ? "Masa hazır. Boş bir koltuğa otur." : "Oyuncular bekleniyor · \(game.seats.count)/\(game.capacity)"
        case .playing:
            if game.isMyTurn(me) { return "Sıra sende" }
            if let turn = game.turnSeat { return "Sıra \(turn.userId == me ? "sende" : turn.name + "’de")" }
            return "Oyun sürüyor"
        case .finished: return "El tamamlandı"
        case .unknown: return "Masa güncelleniyor"
        }
    }

    // MARK: Banners

    @ViewBuilder private func banners(_ game: GameState) -> some View {
        VStack(spacing: 8) {
            if let failure = watch.failure { Notice(text: failure) }
            if let recovery = game.table.ownRecovery, let own = game.seat(of: me) {
                if recovery.canRequestReturn {
                    HStack(spacing: 10) {
                        Text("Bağlantın koptuğu için yerine bot oynuyor.").font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Masaya geri dön") { watch.run(.game(.sit(seat: own.seat))) }.buttonStyle(.borderedProminent).font(.footnote.bold()).disabled(watch.busy)
                    }.padding(12).background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                } else if recovery.pendingReturn {
                    Notice(text: "Kontrol sende; bot sıradaki hamleden sonra çekilir.")
                }
            }
            if game.seat(of: me) == nil {
                if game.table.watching {
                    Label("İzleyicisin. Boş bir koltuğa oturarak oyuna katılabilirsin.", systemImage: "eye").font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                } else if !game.table.spectatorAccess {
                    Notice(text: "Eli görmek için izleyici olarak katıl ya da boş bir koltuğa otur.")
                }
            }
            if game.status != .playing || game.seat(of: me) == nil, game.table.capacity != nil {
                GameSeatPicker(watch: watch, chat: chat, game: game, roomHost: roomHost)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    // MARK: Footer

    private func footer(_ game: GameState) -> some View {
        let seated = game.seat(of: me) != nil
        return HStack(spacing: 10) {
            if seated || game.table.watching {
                Button(seated ? "Masadan kalk" : "İzlemeyi bırak", role: .destructive) {
                    if seated { confirmLeave = true } else { watch.run(.game(.watch(false))) }
                }.buttonStyle(.bordered).frame(minHeight: 44)
            } else if game.table.capacity != nil {
                Button("İzle") { watch.run(.game(.watch(true))) }.buttonStyle(.bordered).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
            if game.canDeal {
                Button(dealTitle(game)) { GameHaptics.tap(); watch.run(.game(.action(.start))) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).frame(minHeight: 44)
            } else if game.status != .playing, seated {
                Text(game.isOwner(me) ? "Başlamak için koltukları doldurun" : "Masa sahibi başlatınca oyun açılır")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .disabled(watch.busy)
        .padding(.horizontal, 14).padding(.vertical, 10).background(Palette.surface)
    }
    private func dealTitle(_ game: GameState) -> String {
        if game.table.series?.finished == true { return "Rövanş" }
        if game.status == .waiting && game.history.isEmpty { return "Oyunu başlat" }
        return "Yeni el"
    }
}

import SwiftUI
import UIKit
import RoomsCore

// Shared pieces every Kıraathane table view uses. Per-game views get one `GameTableContext` from
// `GameTableHost` and draw only their own table; the header, seats, turn clock, banners, leave and
// rematch live in the host.

// MARK: - Context

/// What the host hands each per-game table view (`XTableView(context:)`).
struct GameTableContext {
    /// The table as projected for this viewer.
    let game: GameState
    /// The viewer's user id.
    let me: String
    /// Avatars and names.
    let chat: ChatController
    /// Server clock minus local clock (ms), for the turn deadline.
    let serverOffsetMs: Double
    /// A command is in flight; disable moves meanwhile.
    let busy: Bool
    /// Landscape phone: the host shows only a slim bar (no seat strip, no status line); draw the seats in the table.
    let compactChrome: Bool
    /// Sends one table command; a refusal shows up as the host's error text.
    let send: @MainActor (GameCommand) -> Void

    var mySeat: GameSeat? { game.seat(of: me) }
    /// Batak/101/Okey position of the viewer (index into `game.orderedSeats`).
    var myPosition: Int? { game.position(of: me) }
    var myTurn: Bool { game.isMyTurn(me) }
    /// Not seated: watching (or no access to the hand).
    var spectator: Bool { mySeat == nil }
    /// The server allows this action now (`view.legalActions`).
    func can(_ action: GameActionKind) -> Bool { !busy && game.can(action) }
    func can(_ name: String) -> Bool { !busy && game.can(name) }
    /// Built-in flat action (Hold'em, Blackjack, Batak, 101).
    @MainActor func act(_ action: GameAction) { GameHaptics.tap(); send(.action(action)) }
    /// Registry-game action with payload (Pişti, Okey, Tavla); see `GameMove`.
    @MainActor func move(_ command: GameCommand) { GameHaptics.tap(); send(command) }
    func name(of userID: String) -> String { userID == me ? "Sen" : game.seats.first { $0.userId == userID }?.name ?? "Oyuncu" }
}

// MARK: - Feedback

/// Haptics for table moments; quiet no-ops where the device has no Taptic Engine.
@MainActor enum GameHaptics {
    static func yourTurn() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func refused() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Table sound cues (`GameCue`, desktop `games/shared/sounds.ts` names). `RoomMedia` installs the player: synthesized
/// `GameCueTone`s inside the voice room's audio session, gated by "Oyun sesleri", the effects level and deafen.
@MainActor enum GameSounds {
    /// Replaceable hook; nil plays nothing.
    static var player: (@MainActor (GameCue) -> Void)?
    static func play(_ cue: GameCue) { player?(cue) }
}

/// Tile racks and the Tavla board ask for landscape; leaving the table goes back to portrait
/// (the same supported-geometry request `FullScreenStreamView` uses).
@MainActor enum GameOrientation {
    static func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
}

// MARK: - Cards, tiles, chips

/// A playing card face (or back). Width drives every other size; height is 1.4×.
struct GameCardView: View {
    let card: PlayingCard?
    var faceDown = false
    var width: CGFloat = 44
    var selected = false
    /// Not playable now (greyed, still visible).
    var dimmed = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.12)
        ZStack {
            if let card, !faceDown {
                shape.fill(Color.white)
                VStack(spacing: 0) {
                    Text(card.rankLabel).font(.system(size: width * 0.36, weight: .bold, design: .rounded))
                    Text(card.suit.symbol).font(.system(size: width * 0.34))
                }.foregroundStyle(card.suit.red ? Color.red : Color.black)
            } else {
                shape.fill(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.inset(by: width * 0.08).strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: width, height: width * 1.4)
        .overlay(shape.strokeBorder(selected ? Palette.accent : Color.black.opacity(0.25), lineWidth: selected ? 3 : 0.5))
        .offset(y: selected ? -width * 0.18 : 0)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.map { faceDown ? "Kapalı kart" : "\($0.suit.title) \($0.rankLabel)" } ?? "Kapalı kart")
    }
}

/// An Okey/101 tile. `isOkey` marks the real okey (wildcard) with a star.
struct GameTileView: View {
    let tile: OkeyTile?
    var faceDown = false
    var width: CGFloat = 34
    var selected = false
    var dimmed = false
    var isOkey = false
    static func color(_ color: OkeyColor) -> Color {
        switch color {
        case .red: Color(red: 0.86, green: 0.18, blue: 0.2)
        case .yellow: Color(red: 0.85, green: 0.6, blue: 0.05)
        case .blue: Color(red: 0.12, green: 0.42, blue: 0.85)
        case .black: Color(red: 0.12, green: 0.12, blue: 0.14)
        }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.16)
        ZStack {
            shape.fill(faceDown || tile == nil ? Color(white: 0.82) : Color(red: 0.98, green: 0.96, blue: 0.9))
            if let tile, !faceDown {
                VStack(spacing: 1) {
                    if tile.isFalseJoker { Image(systemName: "star.circle").font(.system(size: width * 0.5)) }
                    else { Text(String(tile.value)).font(.system(size: width * 0.5, weight: .heavy, design: .rounded)) }
                    if isOkey || tile.isJoker { Image(systemName: "star.fill").font(.system(size: width * 0.22)) }
                }.foregroundStyle(Self.color(tile.color))
            }
        }
        .frame(width: width, height: width * 1.45)
        .overlay(shape.strokeBorder(selected ? Palette.accent : Color.black.opacity(0.2), lineWidth: selected ? 3 : 0.5))
        .offset(y: selected ? -width * 0.2 : 0)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.map { faceDown ? "Kapalı taş" : $0.isFalseJoker ? "Sahte okey" : "\($0.color.title) \($0.value)\(isOkey || $0.isJoker ? ", okey" : "")" } ?? "Kapalı taş")
    }
}

/// A virtual chip stack amount (Hold'em pots and bets, Blackjack bets). Never real money.
struct GameChipView: View {
    let amount: Int
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.orange).overlay(Circle().inset(by: 3).strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                .frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
            Text(amount.formatted()).font((compact ? Font.caption2 : .caption).monospacedDigit().bold())
        }
        .padding(.horizontal, 7).padding(.vertical, 3).background(Color.black.opacity(0.35), in: Capsule())
        .accessibilityElement(children: .ignore).accessibilityLabel("\(amount) sanal fiş")
    }
}

// MARK: - Seats and clock

/// Seconds left on the turn, red under 10; nothing when no deadline is running.
struct GameTurnClock: View {
    let game: GameState
    let serverOffsetMs: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let left = game.turnSecondsLeft(nowMs: context.date.timeIntervalSince1970 * 1000, serverOffsetMs: serverOffsetMs) {
                let seconds = Int(left.rounded(.up))
                Label("\(seconds) sn", systemImage: "timer").font(.caption.monospacedDigit().bold())
                    .foregroundStyle(seconds <= 10 ? Color.red : Color.secondary)
                    .accessibilityLabel("Sıranın bitmesine \(seconds) saniye")
            }
        }
    }
}

/// One seat: avatar (or bot badge), name, chips for chip games, turn ring and an away mark.
/// `onRemove` adds "Koltuğu boşalt" (owner or room host, bot or away seat; see `GameState.canRemove`).
struct GameSeatBadge: View {
    let seat: GameSeat
    let game: GameState
    let chat: ChatController
    let me: String
    var size: CGFloat = 40
    var onRemove: (() -> Void)?
    private var isTurn: Bool { game.turn == seat.seat && game.status == .playing }
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if seat.isBotSeat {
                    Circle().fill(Palette.raised).overlay(Image(systemName: "cpu").font(.system(size: size * 0.42))).frame(width: size, height: size)
                } else {
                    ChatAvatarView(chat: chat, userID: seat.userId, name: seat.name, size: size)
                }
                if seat.bot && !seat.isBotSeat { Text("BOT").font(.system(size: 8, weight: .heavy)).padding(2).background(Palette.accent, in: Capsule()) }
            }
            .overlay(Circle().strokeBorder(isTurn ? Palette.accent : Color.clear, lineWidth: 3).padding(-3))
            .opacity(seat.connected ? 1 : 0.45)
            Text(seat.userId == me ? "Sen" : seat.name).font(.caption2.bold()).lineLimit(1).frame(maxWidth: size + 28)
            if game.kind.usesChips { Text(seat.chips.formatted()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            else if !seat.connected { Text("Bağlantı yok").font(.caption2).foregroundStyle(.secondary) }
        }
        .contextMenu { if let onRemove { Button("Koltuğu boşalt", systemImage: "person.fill.xmark", role: .destructive, action: onRemove) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(seat.userId == me ? "Sen" : seat.name)\(seat.isBotSeat ? ", bot" : "")\(isTurn ? ", sıra onda" : "")\(seat.connected ? "" : ", bağlantısı kesildi")")
    }
}

// MARK: - Placeholder

/// What every per-game view shows until its track lands.
struct GameComingSoon: View {
    let kind: GameKind
    var body: some View {
        ContentUnavailableView {
            Label("Bu masa yakında", systemImage: "suit.club.fill")
        } description: {
            Text(kind.known ? "\(kind.title) masası iPhone’da yakında oynanabilecek. Şimdilik masaya oturup izleyebilir, oyunu masaüstünden oynayabilirsin."
                            : "Bu oyun bu sürümde oynanamıyor. Uygulamayı güncelle.")
        }
    }
}

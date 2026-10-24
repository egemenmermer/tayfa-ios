import SwiftUI
import RoomsCore

/// 101 Okey table. Owned by its per-game track: draw the table from `context.game.okey101`; landscape rack.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct Okey101TableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

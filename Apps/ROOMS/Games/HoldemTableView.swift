import SwiftUI
import RoomsCore

/// Texas Hold’em table. Owned by its per-game track: draw the table from `context.game.holdem` (typed hand view).
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct HoldemTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

import SwiftUI
import RoomsCore

/// Pişti table. Owned by its per-game track: draw the table from `context.game.view(as:)` with a Pişti view type in RoomsCore; moves via `GameMove.pistiPlay`.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct PistiTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

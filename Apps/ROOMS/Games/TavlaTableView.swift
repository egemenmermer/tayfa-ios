import SwiftUI
import RoomsCore

/// Tavla table. Owned by its per-game track: draw the table from `context.game.view(as:)`; moves via `GameMove.tavla*`; match score in `context.game.table.series`; landscape board.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct TavlaTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

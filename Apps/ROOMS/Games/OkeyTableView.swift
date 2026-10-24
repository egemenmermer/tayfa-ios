import SwiftUI
import RoomsCore

/// Okey (classic) table. Owned by its per-game track: draw the table from `context.game.view(as:)`; moves via `GameMove.okey*`; landscape rack.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct OkeyTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

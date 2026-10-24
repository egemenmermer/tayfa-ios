import SwiftUI
import RoomsCore

/// Batak table. Owned by its per-game track: draw the table from `context.game.batak`; positions via `context.myPosition`.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct BatakTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

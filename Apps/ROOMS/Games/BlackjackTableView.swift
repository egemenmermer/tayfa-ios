import SwiftUI
import RoomsCore

/// Blackjack table. Owned by its per-game track: draw the table from `context.game.blackjack`.
/// The host already shows the header (seats, turn clock), banners, errors, leave and rematch.
struct BlackjackTableView: View {
    let context: GameTableContext
    var body: some View { GameComingSoon(kind: context.game.kind) }
}

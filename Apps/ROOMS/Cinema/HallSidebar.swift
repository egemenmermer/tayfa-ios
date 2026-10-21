import SwiftUI
import RoomsCore

/// The permanent "Sinema" entry above the community's channels (desktop `HallSidebarRow`). While the
/// hall plays it shows what is on and who is watching, like a voice room shows who is talking.
struct HallSidebarRow: View {
    @ObservedObject var hub: CinemaHub
    @ObservedObject var chat: ChatController
    let community: String
    var body: some View {
        if let hallID = hub.hallID(community: community) {
            // Members who cannot see the hall channel cannot use the hall either.
            if chat.channels.contains(where: { $0.id == hallID }), let activity = hub.activity(hallID: hallID) {
                HallPlayingRow(hub: hub, activity: activity, chat: chat, community: community, hallID: hallID)
            }
        } else if hub.isOwner(community: community) {
            HStack(spacing: 9) {
                Image(systemName: "popcorn").font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sinema").font(.subheadline)
                    Text("Sinema salonu masaüstünden kurulur").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(minHeight: 46).accessibilityElement(children: .combine)
        }
    }
}
private struct HallPlayingRow: View {
    @ObservedObject var hub: CinemaHub
    @ObservedObject var activity: WatchTogetherModel
    @ObservedObject var chat: ChatController
    let community: String
    let hallID: String
    var body: some View {
        let current = HallRecipes.progress(activity.room).current
        let viewers = activity.room?.primary != nil ? activity.room?.participants ?? [] : []
        let open = hub.hall?.id == hallID
        let onAir = open ? hub.hall?.onAir(current?.media.ref)?.title : nil
        let detail = current.map { [$0.media.title, onAir].compactMap { $0 }.joined(separator: " · ") }
        Button { hub.open(community: community) } label: {
            HStack(spacing: 9) {
                Image(systemName: "popcorn.fill").font(.subheadline).foregroundStyle(current != nil || open ? Palette.accent : .secondary)
                    .overlay(alignment: .topTrailing) { if current?.media.isLive == true { HallLiveDot().offset(x: 4, y: -3) } }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sinema").font(.subheadline.weight(current != nil ? .semibold : .regular))
                    if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                HallViewerStack(chat: chat, viewers: viewers)
            }
            .foregroundStyle(.primary).padding(.horizontal, 10).frame(minHeight: open ? 42 : 46)
            .background(open ? Palette.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9)).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "Sinema: \($0). \(HallRecipes.viewerLabel(viewers.count))." } ?? "Sinema salonu")
        .accessibilityHint("Topluluğun sinema salonunu açar")
        .onAppear { hub.watchRow(hallID, visible: true) }
        .onDisappear { hub.watchRow(hallID, visible: false) }
    }
}

/// Presents the open hall over the app, and keeps it in a corner while minimized.
struct HallPresentation: ViewModifier {
    @ObservedObject var hub: CinemaHub
    @ObservedObject var model: RoomsModel
    /// The shell's mini player waits until the cover has gone, so one screen shows the stream at a time.
    @State private var coverGone = true
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let hall = hub.hall, !hub.expanded, coverGone {
                    HallShellMini(hub: hub, hall: hall).padding(.trailing, 12).padding(.bottom, bottomInset)
                }
            }
            .fullScreenCover(isPresented: Binding(get: { hub.expanded && hub.hall != nil }, set: { if !$0 { hub.minimize() } }), onDismiss: {
                coverGone = true
                if let id = model.conversationPath.last { model.chat.setConversationVisible(true, channelID: id) }
            }) {
                if let hall = hub.hall { CinemaHallView(hub: hub, hall: hall, chat: model.chat, model: model) }
            }
            .onChange(of: hub.expanded) { _, expanded in
                // The conversation under the cover is hidden; it must not mark messages read.
                if expanded { coverGone = false; model.chat.setConversationVisible(false) }
            }
    }
    /// Above the tab bar and voice dock, or above a conversation's composer.
    private var bottomInset: CGFloat {
        let voice: CGFloat = model.active != nil ? 66 : 0
        return (model.conversationPath.isEmpty ? 84 : 124) + voice
    }
}
private struct HallShellMini: View {
    @ObservedObject var hub: CinemaHub
    @ObservedObject var hall: HallModel
    var body: some View {
        if hall.current != nil {
            HallMiniPlayer(hall: hall, onExpand: { hub.expanded = true }, onClose: { hub.close() })
        } else {
            HStack(spacing: 0) {
                Button { hub.expanded = true } label: {
                    Label("Sinema salonu açık", systemImage: "popcorn.fill").font(.caption.weight(.semibold)).padding(.leading, 14).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityHint("Salonu büyütür")
                Button { hub.close() } label: { Image(systemName: "xmark").font(.caption).frame(width: 40, height: 44) }.buttonStyle(.plain).accessibilityLabel("Salondan çık")
            }
            .background(Palette.raised, in: Capsule()).overlay(Capsule().strokeBorder(Palette.accent.opacity(0.4)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
    }
}

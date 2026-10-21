import SwiftUI
import LiveKit
import RoomsCore

struct VoiceDockView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    var body: some View {
        if let room = model.active {
            HStack(spacing: 4) {
                Button { model.roomExpanded = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let notice = model.roomNotice { Text(notice).font(.caption2).foregroundStyle(Palette.accent).lineLimit(2) }
                        else { Label { Text(model.busy ? "Bağlanıyor…" : media.connected ? "Ses bağlantısı açık" : "Bağlantı kesildi") } icon: { Image(systemName: media.connected ? "wifi" : "exclamationmark.circle").padding(.trailing, -1) }.font(.caption2).foregroundStyle(media.connected ? Color.green : Color.secondary).lineLimit(1) }
                        Text(room.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(room.name) odasını aç. \(media.status)")
                RoomIconControl(label: media.muted ? "Mikrofonu aç" : "Mikrofonu kapat", icon: media.muted ? "mic.slash" : "mic", selected: !media.muted) { Task { await media.toggleMicrophone() } }.disabled(!media.connected || media.microphoneBusy || media.audioInterrupted || media.audioNeedsResume)
                RoomIconControl(label: media.camera.isOn ? "Kamerayı kapat" : "Kamerayı aç", icon: media.camera.isOn ? "video.fill" : "video.slash", selected: media.camera.isOn) { Task { await media.toggleCamera() } }.disabled(!media.connected || media.camera.busy || media.audioInterrupted)
                if media.canChooseReceiver {
                    RoomIconControl(label: media.speakerPreferred ? "Ahizeye geç" : "Hoparlöre geç", icon: media.speakerPreferred ? "speaker.wave.3.fill" : "iphone", selected: media.speakerPreferred) { media.setSpeakerPreferred(!media.speakerPreferred) }
                        .disabled(!media.connected || media.audioInterrupted)
                }
                RoomIconControl(label: "Odadan ayrıl", icon: "phone.down.fill", destructive: true) { model.leave() }
            }.padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6).background(Palette.raised, in: RoundedRectangle(cornerRadius: 15))
        }
    }
}
struct RoomIconControl: View {
    let label: String
    let icon: String
    var selected = false
    var destructive = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize = 19
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: min(iconSize, 28), weight: .semibold)).frame(width: 44, height: 46).contentShape(Rectangle()) }
            .buttonStyle(RoomControlStyle(selected: selected, destructive: destructive))
            .accessibilityLabel(label).accessibilityValue(selected ? "Açık" : "")
    }
}
struct RoomBottomControls: View {
    @ObservedObject var media: RoomMedia
    let settings: () -> Void
    let leave: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            RoomIconControl(label: media.camera.isOn ? "Kamerayı kapat" : "Kamerayı aç", icon: media.camera.isOn ? "video.fill" : "video.slash", selected: media.camera.isOn) { Task { await media.toggleCamera() } }.disabled(!media.connected || media.camera.busy || media.audioInterrupted)
            RoomIconControl(label: media.muted ? "Mikrofonu aç" : "Mikrofonu kapat", icon: media.muted ? "mic.slash" : "mic", selected: !media.muted) { Task { await media.toggleMicrophone() } }.disabled(!media.connected || media.microphoneBusy || media.audioInterrupted || media.audioNeedsResume)
            RoomIconControl(label: media.hearingMuted ? "Oda sesini aç" : "Oda sesini kapat", icon: media.hearingMuted ? "headphones.slash" : "headphones", selected: !media.hearingMuted) { media.toggleHearing() }.disabled(!media.connected)
            RoomIconControl(label: media.sharingScreen ? "Ekran paylaşımını durdur" : "Ekranımı paylaş", icon: media.sharingScreen ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", selected: media.sharingScreen) {
                if media.sharingScreen { media.stopScreenShare() } else { media.startScreenShare() }
            }.disabled(!media.connected || media.screenShareBusy)
            RoomIconControl(label: "Ses ayarları", icon: "slider.horizontal.3", action: settings)
            RoomIconControl(label: "Odadan ayrıl", icon: "phone.down.fill", destructive: true, action: leave)
        }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.separator))
    }
}
struct VoiceRoomPreview: View {
    @ObservedObject var model: RoomsModel
    let room: VoiceRoom
    @Environment(\.dismiss) private var dismiss
    private var occupants: [Directory.Occupant] { model.occupants(room.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.accent); Text(room.name).font(.title3.bold()).lineLimit(2); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Önizlemeyi kapat") }
            Text(room.community).font(.subheadline).foregroundStyle(.secondary)
            if occupants.isEmpty { VStack(spacing: 8) { Text("Oda şu an sakin.").font(.headline); Text("İlk gelen sen olabilirsin.").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 24) }
            else {
                ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 22) { ForEach(Array(occupants.prefix(20)), id: \.id) { person in VStack(spacing: 10) { ChatAvatarView(chat: model.chat, userID: person.id, name: person.name, size: 48); Text(person.name).font(.caption).lineLimit(2).frame(width: 66) } } }.padding(.vertical, 8) }
            }
            if occupants.contains(where: { $0.screen == true }) { Label("Odada ekran paylaşımı var", systemImage: "rectangle.on.rectangle").font(.subheadline).foregroundStyle(Palette.accent).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)) }
            Button { model.join(room) } label: { Label(model.active == nil ? "Odaya katıl" : "Bu odaya geç", systemImage: "headphones").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.borderedProminent).foregroundStyle(Palette.canvas).disabled(model.busy || model.calls.voiceBlockReason != nil)
            if let reason = model.calls.voiceBlockReason { Text(reason).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            else { Text(model.media.joinsWithMicrophone ? "Mikrofonun en son bıraktığın gibi açık başlayacak; kamera kapalı." : "Mikrofon ve kamera kapalı başlayacaksın.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            if let active = model.active, active.id != room.id { Text("Önce \(active.name) odasından ayrılırsın.").font(.caption).foregroundStyle(.secondary) }
        }.padding(22).padding(.top, 12).presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(Palette.surface)
    }
}

struct VoiceRoomScreen: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var page = 0
    @State private var strip = true
    @State private var expanded = false
    @State private var settings = false
    @State private var dj = false
    @State private var person: RoomPerson?
    @State private var focusedID: String?
    @State private var pendingPeer: String?
    @State private var watch: WatchTogetherModel?
    @State private var polls = false
    @State private var whiteboard = false
    private var shownPeople: [RoomPerson] {
        if let focusedID { return media.people.filter { $0.id == focusedID } }
        return Array(media.people.dropFirst(page * 6).prefix(6))
    }
    private var pages: Int { max(1, (media.people.count + 5) / 6) }
    private var visibleIDs: Set<String> { focusedID == nil && media.selection.id != nil && !strip ? [] : Set(shownPeople.map(\.id)) }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    notices
                    if focusedID != nil { cameraGrid }
                    else if media.selection.id != nil {
                        if expanded { Color.black.aspectRatio(16 / 9, contentMode: .fit) }
                        else { ScreenSurface(media: media).id(media.selection.id).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)) }
                        streamControls
                        if media.streams.count > 1 { screenCatalog }
                        if strip { if expanded { Color.clear.frame(height: 84) } else { cameraStrip } }
                        Button(strip ? "Kamera şeridini gizle" : "Kamera şeridini göster") { strip.toggle() }.font(.caption).frame(minHeight: 44)
                    } else {
                        cameraGrid
                        screenCatalog
                    }
                    pagination
                }.padding(.horizontal, 14).padding(.vertical, 16)
            }
            VStack(spacing: 10) {
                Label(model.busy ? "Odaya bağlanılıyor…" : media.status, systemImage: media.connected ? "wifi" : "network").font(.caption2).foregroundStyle(media.connected ? Color.green : Color.secondary).lineLimit(2)
                RoomBottomControls(media: media, settings: { settings = true }) { model.leave() }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        }.background(Palette.rail.ignoresSafeArea())
            .sheet(isPresented: $dj) { DJPanelView(model: model, media: media).presentationDetents([.large]) }
            .sheet(isPresented: $settings, onDismiss: openPendingPeer) { RoomAudioSettingsView(media: media, onMessagePeer: { pendingPeer = $0; settings = false }, chat: chat) }
            .sheet(item: $person, onDismiss: openPendingPeer) { selected in ParticipantAudioView(media: media, person: selected, onMessage: { pendingPeer = selected.id; person = nil }, chat: chat, moderation: model.voiceModeration(for: selected)) }
            .sheet(isPresented: $polls) { if let watch { PollsView(watch: watch) } }
            .fullScreenCover(isPresented: $whiteboard) { if let watch { WhiteboardView(watch: watch, media: media, roomName: model.active?.name ?? "Oda") } }
            .task(id: model.active?.id) { watch?.stop(); watch = model.active.flatMap { model.watchTogether(roomID: $0.id) }; watch?.start() }
            .onDisappear { if !whiteboard { watch?.stop() } }
            .fullScreenCover(isPresented: $expanded) { FullScreenStreamView(model: model, media: media, cameraPeople: strip ? shownPeople : [], onCameraFocus: { focusedID = $0; expanded = false }) { expanded = false } }
            .onAppear { updateCameraSubscriptions() }
            .onChange(of: visibleIDs) { _, _ in updateCameraSubscriptions() }
            .onChange(of: media.people.map(\.id)) { _, ids in if page >= pages { page = 0 }; if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }; updateCameraSubscriptions() }
            .onChange(of: media.selection.id) { _, id in if id == nil { expanded = false }; focusedID = nil; updateCameraSubscriptions() }
            .onChange(of: model.active?.id) { _, id in page = 0; focusedID = nil; expanded = false; if id == nil { dismiss() } }
            .onChange(of: model.roomExpanded) { _, expanded in if !expanded { dismiss() } }
            .accessibilityAction(.escape) { model.roomExpanded = false }
    }
    private var header: some View {
        HStack(spacing: 6) {
            Button { model.roomExpanded = false } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Odayı küçült")
            VStack(alignment: .leading, spacing: 4) { Text(model.active?.name ?? "Ses odası").font(.headline).lineLimit(2); Text((model.active?.community ?? "") + " · \(media.people.count) kişi").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
            activitiesMenu.disabled(!media.connected || watch == nil)
            RoomIconControl(label: "DJ", icon: "music.note") { dj = true }.disabled(!media.connected)
            if media.camera.isOn { RoomIconControl(label: "Ön veya arka kamerayı değiştir", icon: "arrow.triangle.2.circlepath.camera") { Task { await media.switchCamera() } }.disabled(media.camera.busy) }
            Button { let id = model.active?.id; model.openMessages(channelID: id) } label: { Image(systemName: "bubble.left").frame(width: 44, height: 44) }.accessibilityLabel("Oda sohbetini aç")
        }.padding(.horizontal, 8).padding(.vertical, 7)
            .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { if $0.translation.height > 60 && abs($0.translation.width) < $0.translation.height { model.roomExpanded = false } })
    }
    /// Room activities, like desktop's "Uygulamalar ve etkinlikler". Films live in the Sinema hall.
    private var activitiesMenu: some View {
        Menu {
            Button("Anketler", systemImage: "chart.bar.doc.horizontal") { polls = true }
            Button("Beyaz tahta", systemImage: "scribble.variable") { whiteboard = true }
        } label: {
            Image(systemName: "square.grid.2x2").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.primary).frame(width: 44, height: 46).contentShape(Rectangle())
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
        }.accessibilityLabel("Etkinlikler: anketler ve beyaz tahta")
    }
    @ViewBuilder private var notices: some View {
        if let notice = model.roomNotice { Notice(text: notice) }
        if let error = model.error ?? media.error { Notice(text: error) }
        if let cameraError = media.camera.error {
            Notice(text: cameraError)
            if cameraError.contains("Kamera izni yok") { Button("iPhone ayarlarını aç") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.footnote).frame(minHeight: 44) }
        }
        if let notice = media.audioNotice { Notice(text: notice) }
        if media.audioNeedsResume && !media.audioInterrupted { Button("Sesi sürdür") { media.resumeAudio() }.frame(minHeight: 44).buttonStyle(.bordered) }
        if !media.connected && !model.busy { Button("Tekrar katıl") { if let active = model.active { model.join(active) } }.buttonStyle(.bordered).frame(minHeight: 44) }
        if media.sharingScreen {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ekranını paylaşıyorsun. Bildirimler ve şifreler de görünebilir.").font(.footnote)
                    if let me = media.people.first(where: \.local) { Text(media.viewerSummary(of: me.id, named: true)).font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Durdur", role: .destructive) { media.stopScreenShare() }.font(.footnote.bold()).frame(minHeight: 44)
            }.padding(12).background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        if media.selection.state == .ended { Notice(text: "Ekran paylaşımı sona erdi. Odada konuşmaya devam edebilirsin.") }
        if media.selection.state == .failed { Notice(text: "Yayın açılamadı. Listeden tekrar seç.") }
    }
    private var cameraGrid: some View {
        VStack(spacing: 12) {
            if shownPeople.isEmpty && !model.busy { Text("Katılımcılar burada görünecek.").foregroundStyle(.secondary).padding(36) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: dynamicType.isAccessibilitySize || focusedID != nil ? 1 : 2), spacing: 9) {
                ForEach(shownPeople) { participant in CameraParticipantTile(media: media, chat: chat, person: participant) { tapParticipant(participant) }.aspectRatio(focusedID == nil ? 1 : 4 / 3, contentMode: .fit).contextMenu { Button("Profil ve kişisel ses", systemImage: "person.crop.circle") { person = participant } } }
            }
            if focusedID != nil { Button("Tüm katılımcılara dön") { focusedID = nil }.font(.footnote).frame(minHeight: 44) }
        }
    }
    private var cameraStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(shownPeople) { participant in CameraParticipantTile(media: media, chat: chat, person: participant, compact: true) { tapParticipant(participant) }.frame(width: 112, height: 82) } } }.frame(height: 84)
    }
    private var screenCatalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EKRAN YAYINLARI").font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 12)
            if media.streams.isEmpty { Text("Henüz ekran paylaşan yok.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(media.streams) { screen in
                Button { focusedID = nil; media.watch(screen.id) } label: {
                    HStack(spacing: 10) { Image(systemName: "rectangle.on.rectangle"); VStack(alignment: .leading, spacing: 2) { Text(screen.name).lineLimit(2); Text(media.viewerSummary(of: screen.participantID)).font(.caption2).foregroundStyle(.secondary) }; Spacer(minLength: 0); Text("Yayını izle").font(.caption.bold()); Image(systemName: "chevron.right").font(.caption) }.padding(13).frame(minHeight: 48).foregroundStyle(Palette.accent).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(!media.connected)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var streamControls: some View {
        VStack(spacing: 8) {
            HStack { VStack(alignment: .leading, spacing: 2) { Label(media.selectedStream?.name ?? "Ekran yayını", systemImage: "rectangle.on.rectangle").font(.caption).lineLimit(1); if let presenter = media.selectedStream?.participantID { Text(media.viewerSummary(of: presenter)).font(.caption2).foregroundStyle(.secondary) } }; Spacer(minLength: 0); RoomIconControl(label: "Yayını tam ekran izle", icon: "arrow.up.left.and.arrow.down.right") { expanded = true }; RoomIconControl(label: "İzlemeyi kapat", icon: "xmark") { media.watch(nil) } }
            if media.selectedStream?.hasAudio == true { HStack(spacing: 12) { RoomIconControl(label: media.screenMuted ? "Yayın sesini aç" : "Yayın sesini kapat", icon: media.screenMuted ? "speaker.slash" : "speaker.wave.2", selected: !media.screenMuted) { media.setScreenAudio(muted: !media.screenMuted) }; Slider(value: Binding(get: { media.screenVolume }, set: { media.setScreenAudio(volume: $0) }), in: 0...1).accessibilityLabel("Yayın sesi") } }
        }
    }
    @ViewBuilder private var pagination: some View {
        if pages > 1 && focusedID == nil {
            HStack { Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(page == 0).accessibilityLabel("Önceki katılımcılar"); Text("\(page + 1) / \(pages)").font(.caption).foregroundStyle(.secondary); Button { page = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(page == pages - 1).accessibilityLabel("Sonraki katılımcılar") }.frame(maxWidth: .infinity)
        }
    }
    private func updateCameraSubscriptions() { media.setVisibleCameras(visibleIDs) }
    private func tapParticipant(_ participant: RoomPerson) { if media.cameras.contains(where: { $0.id == participant.id }) { focusedID = focusedID == participant.id ? nil : participant.id } else { person = participant } }
    private func openPendingPeer() { if let peer = pendingPeer { pendingPeer = nil; model.openDirectMessage(peer) } }
}

struct CameraParticipantTile: View {
    @ObservedObject var media: RoomMedia
    @ObservedObject var chat: ChatController
    let person: RoomPerson
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Palette.raised
                if let feed = media.cameras.first(where: { $0.id == person.id }), let track = feed.track {
                    // Your own camera shows as others see it, never mirrored.
                    SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .off)
                        .allowsHitTesting(false)
                } else { ChatAvatarView(chat: chat, userID: person.id, name: person.name, size: compact ? 32 : 58) }
                VStack { HStack { Spacer(); if person.deafened || person.muted { HStack(spacing: 5) { Image(systemName: "mic.slash"); if person.deafened { Image(systemName: "headphones.slash") } }.font(.caption2).padding(7).background(.black.opacity(0.45), in: Capsule()).accessibilityElement(children: .ignore).accessibilityLabel(person.deafened ? "Mikrofon kapalı, sağırlaştırdı" : "Mikrofon kapalı") } }; Spacer(); HStack { Text(person.name + (person.local ? " (sen)" : "")).font(compact ? .caption2 : .caption).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6)); Spacer(minLength: 0) } }.padding(8)
            }.foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 16))
                .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 16).strokeBorder(person.speaking ? Color.green : Color.white.opacity(0.04), lineWidth: person.speaking ? 2 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(person.name + (person.speaking ? ", konuşuyor" : "") + (person.muted ? ", mikrofon kapalı" : "") + (media.cameras.contains(where: { $0.id == person.id }) ? ", kamerayı büyüt" : ", katılımcı ayarları"))
    }
}

struct ScreenSurface: View {
    @ObservedObject var media: RoomMedia
    @State private var owner = UUID()
    var body: some View {
        let id = media.selection.id
        ZStack {
            Color.black
            if let video = media.video { SwiftUIVideoView(video, layoutMode: .fit, isRendering: Binding(get: { media.screenRendering }, set: { media.markRendering($0, id: id, owner: owner) })).allowsHitTesting(false) }
            if !media.screenRendering { ProgressView(media.connected ? "Yayın açılıyor…" : media.status).font(.caption).foregroundStyle(.white).tint(.white).padding(12) }
        }.onAppear { media.claimRenderer(owner) }.onDisappear { media.releaseRenderer(owner) }.accessibilityLabel("\(media.selectedStream?.name ?? "Katılımcı") ekran yayını")
    }
}
struct MiniPlayerFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
struct MiniStreamPlayer: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var placement = CGSize.zero
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            let width = min(196, max(164, geometry.size.width * 0.45)), height = width * 9 / 16 + 44
            let baseX = max(8, geometry.size.width - width - 12), maxY = max(8, geometry.size.height - height - (model.conversationPath.isEmpty ? 90 : 145))
            let x = min(baseX, max(8, baseX + placement.width + drag.width)), y = min(maxY, max(8, 70 + placement.height + drag.height))
            VStack(spacing: 0) {
                Button { model.roomExpanded = true } label: { ScreenSurface(media: media).id(media.selection.id).frame(height: width * 9 / 16) }.buttonStyle(.plain).accessibilityLabel("Yayını büyüt")
                HStack(spacing: 0) { Text(media.selectedStream?.name ?? "Yayın").font(.caption2).lineLimit(1).padding(.leading, 8); Spacer(minLength: 0); if media.selectedStream?.hasAudio == true { Button { media.setScreenAudio(muted: !media.screenMuted) } label: { Image(systemName: media.screenMuted ? "speaker.slash" : "speaker.wave.2").font(.caption).frame(width: 44, height: 44) }.accessibilityLabel(media.screenMuted ? "Yayın sesini aç" : "Yayın sesini kapat") }; Button { media.watch(nil) } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44) }.accessibilityLabel("İzlemeyi kapat") }.frame(height: 44).background(Palette.raised)
            }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.accent.opacity(0.4)))
                .background { GeometryReader { item in Color.clear.preference(key: MiniPlayerFrameKey.self, value: item.frame(in: .global)) } }
                .offset(x: x, y: y)
                .simultaneousGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                    let endX = min(baseX, max(8, baseX + placement.width + value.translation.width)), endY = min(maxY, max(8, 70 + placement.height + value.translation.height))
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0)) { placement = CGSize(width: (endX + width / 2 < geometry.size.width / 2 ? 8 : baseX) - baseX, height: endY - 70) }
                })
                .accessibilityAction(named: "Diğer köşeye taşı") { placement.width = x < geometry.size.width / 2 - width / 2 ? 0 : 8 - baseX }
        }
    }
}

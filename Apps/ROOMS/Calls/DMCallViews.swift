import SwiftUI
import LiveKit
import RoomsCore

/// The full call screen (desktop `DmCallRuntime` stage): incoming, outgoing, connecting and connected.
struct DMCallScreen: View {
    @ObservedObject var calls: DMCallModel
    @ObservedObject var media: RoomMedia
    @ObservedObject var model: RoomsModel
    var body: some View {
        ZStack {
            Palette.rail.ignoresSafeArea()
            if let call = calls.call, let me = calls.me {
                content(call, me: me)
            } else {
                ProgressView().tint(.white)
            }
        }.preferredColorScheme(.dark).tint(Palette.accent)
            .onChange(of: calls.connected, initial: true) { _, _ in updateCameras() }
            .onChange(of: calls.call?.id) { _, _ in updateCameras() }
            .onDisappear { media.setVisibleCameras([]) }
    }
    private func content(_ call: DMCallSession, me: String) -> some View {
        let incoming = call.incoming(for: me), peer = call.peer(for: me)
        let peerFeed = calls.connected ? media.cameras.first(where: { $0.id == peer.id && $0.track != nil }) : nil
        let ownFeed = calls.connected ? media.cameras.first(where: { $0.local && $0.track != nil }) : nil
        return VStack(spacing: 18) {
            HStack {
                if !(call.ringing && incoming) {
                    Button { calls.expanded = false } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Görüşmeyi küçült")
                }
                Spacer()
                Text("ÖZEL GÖRÜŞME").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Palette.raised
                    if let feed = peerFeed, let track = feed.track { SwiftUIVideoView(track, layoutMode: .fill).allowsHitTesting(false) }
                    else {
                        VStack(spacing: 14) {
                            ChatAvatarView(chat: model.chat, userID: peer.id, name: peer.name, size: 96)
                            Text(peer.name).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                            Text(peerState(call, incoming: incoming, peerID: peer.id)).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(20)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 22))
                if let feed = ownFeed, let track = feed.track {
                    SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .off).allowsHitTesting(false)
                        .frame(width: 104, height: 140).clipShape(RoundedRectangle(cornerRadius: 14)).padding(10)
                        .accessibilityLabel("Kameran")
                }
            }.frame(maxHeight: .infinity)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(status(call, incoming: incoming)).font(.subheadline.weight(.semibold)).foregroundStyle(calls.connected && media.connected ? Color.green : Color.secondary)
                    if calls.connected, let accepted = call.acceptedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsed(since: accepted, now: context.date)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                Text("Özel \(call.mode == .video ? "görüntülü" : "sesli") görüşme · yalnızca sen ve \(peer.name)").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.active != nil, call.ringing, incoming { Text("Kabul edince bulunduğun ses odasından çıkarsın.").font(.caption).foregroundStyle(.secondary) }
                if call.ringing, !incoming { Text("Arama, karşı tarafta Tayfa açıkken çalar.").font(.caption).foregroundStyle(.secondary) }
                if let error = calls.error ?? (calls.connected ? media.error ?? media.camera.error : nil) { Notice(text: error) }
            }
            controls(call, incoming: incoming)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    @ViewBuilder private func controls(_ call: DMCallSession, incoming: Bool) -> some View {
        if call.ringing && incoming {
            VStack(spacing: 10) {
                Button { Task { await calls.accept(camera: false) } } label: { Label("Sesli kabul et", systemImage: "phone.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.borderedProminent).tint(.green).accessibilityIdentifier("call.accept")
                if call.mode == .video {
                    Button { Task { await calls.accept(camera: true) } } label: { Label("Kamerayla kabul et", systemImage: "video.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.bordered)
                }
                Button(role: .destructive) { Task { await calls.end(.reject) } } label: { Label("Reddet", systemImage: "phone.down.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.bordered)
            }.disabled(calls.busy)
        } else {
            VStack(spacing: 10) {
                if call.state == .accepted, !calls.connected, !calls.busy {
                    Button { Task { await calls.joinAccepted() } } label: { Text("Görüşmeye katıl").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent)
                }
                HStack(spacing: 9) {
                    if calls.connected {
                        RoomIconControl(label: media.muted ? "Mikrofonu aç" : "Mikrofonu kapat", icon: media.muted ? "mic.slash" : "mic", selected: !media.muted) { Task { await media.toggleMicrophone() } }
                            .disabled(!media.canToggleMicrophone)
                        RoomIconControl(label: media.hearingMuted ? "Sesi aç" : "Sesi kapat", icon: media.hearingMuted ? "headphones.slash" : "headphones", selected: !media.hearingMuted) { media.toggleHearing() }.disabled(!media.connected)
                        RoomIconControl(label: media.camera.isOn ? "Kamerayı kapat" : "Kamerayı aç", icon: media.camera.isOn ? "video.fill" : "video.slash", selected: media.camera.isOn) { Task { await media.toggleCamera() } }
                            .disabled(!media.connected || media.camera.busy || media.audioInterrupted)
                        if media.camera.isOn { RoomIconControl(label: "Ön veya arka kamerayı değiştir", icon: "arrow.triangle.2.circlepath.camera") { Task { await media.switchCamera() } }.disabled(media.camera.busy) }
                        if media.canChooseReceiver { RoomIconControl(label: media.speakerPreferred ? "Ahizeye geç" : "Hoparlöre geç", icon: media.speakerPreferred ? "speaker.wave.3.fill" : "iphone", selected: media.speakerPreferred) { media.setSpeakerPreferred(!media.speakerPreferred) }.disabled(!media.connected) }
                    }
                    RoomIconControl(label: call.ringing ? "Aramayı iptal et" : "Görüşmeyi bitir", icon: "phone.down.fill", destructive: true) { Task { await calls.end() } }
                        .disabled(calls.busy && !calls.connected && !call.ringing)
                }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
                if media.audioNeedsResume && !media.audioInterrupted && calls.connected { Button("Sesi sürdür") { media.resumeAudio() }.frame(minHeight: 44) }
            }
        }
    }
    private func status(_ call: DMCallSession, incoming: Bool) -> String {
        if call.ringing { return incoming ? "Gelen özel arama" : "Yanıt bekleniyor…" }
        if calls.connected && media.connected { return "Bağlı" }
        return calls.connected ? "Yeniden bağlanıyor…" : "Bağlanıyor…"
    }
    private func peerState(_ call: DMCallSession, incoming: Bool, peerID: String) -> String {
        if call.ringing { return status(call, incoming: incoming) }
        guard calls.connected, let person = media.people.first(where: { $0.id == peerID }) else { return "Bağlanması bekleniyor…" }
        return person.speaking ? "Konuşuyor" : person.muted ? "Mikrofon kapalı" : "Mikrofon açık"
    }
    private func elapsed(since acceptedAt: Double, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - acceptedAt / 1000))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func updateCameras() {
        guard calls.connected, let peer = calls.peer else { media.setVisibleCameras([]); return }
        media.setVisibleCameras([peer.id])
    }
}

/// An active call while the call screen is minimized, in the voice dock's place; or the last call notice.
struct DMCallDock: View {
    @ObservedObject var calls: DMCallModel
    @ObservedObject var media: RoomMedia
    var body: some View {
        if let call = calls.call, let peer = calls.peer, !calls.expanded {
            HStack(spacing: 4) {
                Button { calls.expanded = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(call.ringing ? (calls.incoming ? "Gelen özel arama" : "Yanıt bekleniyor…") : calls.connected && media.connected ? "Özel görüşme bağlı" : "Bağlanıyor…", systemImage: "phone.fill")
                            .font(.caption2).foregroundStyle(calls.connected && media.connected ? Color.green : Color.secondary).lineLimit(1)
                        Text(peer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(peer.name) ile görüşmeyi aç")
                if calls.connected {
                    RoomIconControl(label: media.muted ? "Mikrofonu aç" : "Mikrofonu kapat", icon: media.muted ? "mic.slash" : "mic", selected: !media.muted) { Task { await media.toggleMicrophone() } }
                        .disabled(!media.canToggleMicrophone)
                }
                RoomIconControl(label: call.ringing && calls.incoming ? "Reddet" : "Görüşmeyi bitir", icon: "phone.down.fill", destructive: true) { Task { await calls.end(call.ringing && calls.incoming ? .reject : .end) } }
            }.padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6).background(Palette.raised, in: RoundedRectangle(cornerRadius: 15))
        } else if calls.call == nil, let error = calls.error {
            HStack(spacing: 8) {
                Image(systemName: "phone.badge.waveform").foregroundStyle(.secondary)
                Text(error).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button { calls.error = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Bildirimi kapat")
            }.padding(.leading, 12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 15))
        }
    }
}

/// Call button for a DM conversation header; explains when a call cannot start.
struct DMCallButton: View {
    @ObservedObject var calls: DMCallModel
    let dmID: String
    let inVoiceRoom: Bool
    var body: some View {
        Menu {
            if let call = calls.call, call.dmId == dmID, call.active {
                Button("Görüşmeye dön", systemImage: "phone.fill") { calls.expanded = true }
            } else if let reason = calls.unavailableReason {
                Text(reason)
            } else {
                Button("Sesli ara", systemImage: "phone") { Task { await calls.start(dmID: dmID, mode: .audio) } }
                Button("Görüntülü ara", systemImage: "video") { Task { await calls.start(dmID: dmID, mode: .video) } }
                if inVoiceRoom { Text("Görüşme başlayınca ses odasından çıkarsın.") }
            }
        } label: { Image(systemName: "phone.fill") }
            .accessibilityLabel("Ara").accessibilityIdentifier("dm.call")
    }
}

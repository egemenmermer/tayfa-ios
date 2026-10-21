import SwiftUI
import LiveKit

/// Presentation changes only the renderer, never the room connection or track selection.
struct FullScreenStreamView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    let cameraPeople: [RoomPerson]
    let onCameraFocus: (String) -> Void
    let close: () -> Void
    @State private var safeInsets = UIEdgeInsets.zero
    @State private var showingVolume = false
    @State private var showingAudioSettings = false
    @State private var messagePeer: String?
    @State private var chrome = true
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .body) private var iconSize = 18

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                ScreenSurface(media: media).id(media.selection.id)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    // Tapping the picture fades the controls out and back in, like a video player.
                    .contentShape(Rectangle()).onTapGesture { chrome.toggle() }
                    .accessibilityIdentifier("stream.fullscreen.video")
                VStack(spacing: 0) {
                    if showsChrome {
                        ViewThatFits(in: .horizontal) {
                            header
                            VStack(alignment: .leading, spacing: 6) { headerActions; Text(media.selectedStream?.name ?? "Ekran yayını").font(.caption).foregroundStyle(.white).lineLimit(2) }
                        }.transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    if showsChrome, showingVolume, media.selectedStream?.hasAudio == true {
                        Slider(value: Binding(get: { media.screenVolume }, set: { media.setScreenAudio(volume: $0) }), in: 0...1)
                            .accessibilityLabel("Yayın sesi")
                            .accessibilityValue("Yüzde \(Int(media.screenVolume * 100))")
                            .frame(maxWidth: 280).padding(12)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 8)
                    }
                    if media.audioInterrupted || media.audioNeedsResume {
                        Text(media.audioInterrupted ? "Ses kesintisi · mikrofon kapalı" : "Ses ayarlarından sesi sürdür")
                            .font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.8))
                    }
                    if showsChrome, !cameraPeople.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 7) { ForEach(cameraPeople) { person in CameraParticipantTile(media: media, chat: model.chat, person: person, compact: true) { onCameraFocus(person.id); close() }.frame(width: 100, height: 72) } } }.frame(height: 74).padding(.bottom, 6)
                    }
                    if let cameraError = media.camera.error { Text(cameraError).font(.caption).foregroundStyle(.white).lineLimit(3).padding(8).background(.black.opacity(0.8)) }
                    if showsChrome { controls.transition(.opacity) }
                }
                // The video uses the complete display; only controls avoid the island/home indicator.
                .padding(.top, max(safeInsets.top, 12))
                .padding(.bottom, max(safeInsets.bottom, 12))
                .padding(.leading, max(safeInsets.left, 16))
                .padding(.trailing, max(safeInsets.right, 16))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeOut(duration: 0.18), value: showsChrome)
            .onChange(of: geometry.size) { _, _ in updateSafeInsets() }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled()
        .onAppear {
            updateSafeInsets()
            // Use the supported iOS geometry API; no UIDevice orientation KVC hacks.
            requestOrientation(.landscape)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in updateSafeInsets() }
        .onChange(of: media.selectedStream?.hasAudio) { _, hasAudio in if hasAudio != true { showingVolume = false } }
        .sheet(isPresented: $showingAudioSettings, onDismiss: {
            if let peer = messagePeer { messagePeer = nil; model.openDirectMessage(peer) }
        }) { RoomAudioSettingsView(media: media, onMessagePeer: { peer in messagePeer = peer; showingAudioSettings = false }, chat: model.chat) }
        .accessibilityAction(.escape, close)
        .onDisappear { requestOrientation(.portrait) }
    }

    /// Warnings stay on screen; VoiceOver users keep the controls since the picture has no visible tap target for them.
    private var showsChrome: Bool { chrome || voiceOver }

    private var header: some View {
        HStack(spacing: 12) {
            button("Normal görünüme dön", icon: "arrow.down.right.and.arrow.up.left", action: close)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.selectedStream?.name ?? "Ekran yayını").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let presenter = media.selectedStream?.participantID { Text(media.viewerSummary(of: presenter)).font(.caption2).opacity(0.75).lineLimit(1) }
            }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.75), in: Capsule())
            Spacer()
            button("Mesajlar", icon: "text.bubble") { close(); model.openMessages(channelID: model.active?.id) }
            button("Ses ayarları", icon: "slider.horizontal.3") { showingAudioSettings = true }
            button("İzlemeyi kapat", icon: "xmark") {
                media.watch(nil)
                close()
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            button("Normal görünüme dön", icon: "arrow.down.right.and.arrow.up.left", action: close)
            Spacer(minLength: 0)
            button("Mesajlar", icon: "text.bubble") { close(); model.openMessages(channelID: model.active?.id) }
            button("Ses ayarları", icon: "slider.horizontal.3") { showingAudioSettings = true }
            button("İzlemeyi kapat", icon: "xmark") { media.watch(nil); close() }
        }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            if media.selectedStream?.hasAudio == true { button(media.screenMuted ? "Yayın sesini aç" : "Yayın sesini kapat", icon: media.screenMuted ? "speaker.slash" : "speaker.wave.2") { media.setScreenAudio(muted: !media.screenMuted); showingVolume = !media.screenMuted } }
            RoomBottomControls(media: media, settings: { showingAudioSettings = true }) { model.leave(); close() }
        }
    }

    private func button(_ label: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: min(iconSize, 28), weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RoomControlStyle(destructive: destructive))
        .accessibilityLabel(label)
    }

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    private func updateSafeInsets() {
        if let window = scene?.windows.first(where: { $0.isKeyWindow }) { safeInsets = window.safeAreaInsets }
    }
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let scene else { return }
        var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in
            // Even when iOS declines the rotation request, the cover remains genuinely full screen.
        }
    }
}

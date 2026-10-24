import AVFoundation
import AVKit
import SwiftUI
import RoomsCore
import UIKit

/// The hall player on screen: `.stage` is the 16:9 player with the hall's controls (and a landscape full
/// screen), `.mini` is the bare picture the hall UI wraps into its corner player. Both show the same
/// `HallPlayerController`.
struct HallPlayerSurface: View {
    @ObservedObject var player: HallPlayerController
    var style: HallPlayerController.Style = .stage
    @State private var fullscreen = false

    var body: some View {
        switch style {
        case .stage:
            HallStage(player: player, activity: player.activity, fullscreen: false) { fullscreen = true }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .fullScreenCover(isPresented: $fullscreen) { HallFullScreen(player: player) { fullscreen = false } }
        case .mini:
            HallMini(player: player)
        }
    }
}

/// The picture: the relay through a player layer of its own, or the official YouTube player.
private struct HallScreen: View {
    @ObservedObject var player: HallPlayerController
    let style: HallPlayerController.Style
    var body: some View {
        ZStack {
            Color.black
            if let youtube = player.youtube { HallYouTubeHost(player: player, controller: youtube).allowsHitTesting(false) }
            else if player.isRelay { HallVideoHost(player: player, style: style) }
        }
    }
}

private struct HallVideoHost: UIViewRepresentable {
    let player: HallPlayerController
    let style: HallPlayerController.Style
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        weak var controller: HallPlayerController?
        var style: HallPlayerController.Style = .stage
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { controller?.register(playerLayer, style: style) } else { controller?.unregister(playerLayer) }
        }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.controller = player; view.style = style
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {}
    static func dismantleUIView(_ view: LayerView, coordinator: ()) { view.controller?.unregister(view.playerLayer) }
}

/// The YouTube page is one web view; the newest visible host (stage, full screen or mini) shows it.
private struct HallYouTubeHost: UIViewRepresentable {
    let player: HallPlayerController
    let controller: YouTubePlayerController
    final class HostView: UIView {
        weak var owner: HallPlayerController?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { owner?.attachYouTube(self) } else { owner?.detachYouTube(self) }
        }
    }
    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.owner = player
        return view
    }
    func updateUIView(_ view: HostView, context: Context) { player.placeYouTube() }
    static func dismantleUIView(_ view: HostView, coordinator: ()) { view.owner?.detachYouTube(view) }
}

/// The player with the hall's controls (desktop `HallStage`): tap shows or hides them, and they hide by
/// themselves while something plays.
private struct HallStage: View {
    @ObservedObject var player: HallPlayerController
    @ObservedObject var activity: WatchTogetherModel
    let fullscreen: Bool
    let toggleFullscreen: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var overlay = true
    @State private var seekDraft: Double?
    @State private var switching = false
    @State private var reason: String?
    @State private var hideTask: Task<Void, Never>?
    @State private var reasonTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            HallScreen(player: player, style: .stage).ignoresSafeArea(edges: fullscreen ? .all : [])
            if player.current == nil { idle }
            else {
                Color.clear.contentShape(Rectangle()).onTapGesture { overlay.toggle(); scheduleHide() }
                    .accessibilityHidden(true)
                status
                if overlay || pinned { chrome.transition(.opacity) }
            }
            if let text = reason ?? player.notice {
                Text(text).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.8), in: Capsule())
                    .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top).padding(.top, 52)
                    .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.18), value: overlay)
        .onAppear { scheduleHide(); if player.phase == .loading { scheduleSwitching() } }
        .onChange(of: player.phase) { _, phase in
            if phase == .loading { switching = false; scheduleSwitching() } else { switching = false }
            scheduleHide()
        }
        .onChange(of: player.current?.id) { _, _ in overlay = true; scheduleHide() }
    }

    private var pinned: Bool {
        voiceOver || seekDraft != nil || player.phase == .failed || player.phase == .paused || player.phase == .idle
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "popcorn").font(.title2)
            Text("Salonda şu an bir şey oynamıyor").font(.subheadline.weight(.semibold))
            Text("Canlı TV, Filmler, Diziler ya da YouTube'dan bir şey aç.").font(.caption).foregroundStyle(.white.opacity(0.7))
        }.foregroundStyle(.white).multilineTextAlignment(.center).padding()
    }

    @ViewBuilder private var status: some View {
        if player.phase == .failed {
            VStack(spacing: 10) {
                Text("Bu yayın şu an açılamadı").font(.subheadline.weight(.semibold))
                if let failure = player.failure { Text(failure).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                HStack(spacing: 8) {
                    Button { player.retry() } label: { Label("Yeniden dene", systemImage: "arrow.counterclockwise").font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                    if player.isLive && player.canDirect {
                        Button { player.zap(1) } label: { Text("Sonraki kanal").font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36) }.buttonStyle(.bordered).tint(.white)
                    }
                }
            }
            .foregroundStyle(.white).multilineTextAlignment(.center).padding(14)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14)).padding(16)
        } else if switching {
            HStack(spacing: 8) { ProgressView().tint(.white); Text(player.isLive ? "Kanal değişiyor…" : "Açılıyor…").font(.footnote) }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).background(.black.opacity(0.7), in: Capsule())
                .accessibilityElement(children: .combine)
        } else if player.behindLive && player.isLive && player.phase != .paused {
            Button { player.goLive() } label: {
                Text("Canlıya dön").font(.footnote.weight(.bold)).padding(.horizontal, 14).frame(minHeight: 36)
            }.buttonStyle(.borderedProminent).tint(.red).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, overlay ? 78 : 14)
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                if player.isLive { HallPill(text: "CANLI", live: true) }
                ForEach(player.badges.prefix(3), id: \.self) { HallPill(text: $0) }
                Spacer(minLength: 8)
                if player.viewers > 0 {
                    Label("\(player.viewers)", systemImage: "eye").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule())
                        .accessibilityLabel(player.viewers == 1 ? "1 kişi izliyor" : "\(player.viewers) kişi izliyor")
                }
            }
            .padding(10)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if !player.isLive, let duration = player.durationSec, duration > 0 { seekBar(duration) }
                controls
            }
            .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 18)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        }
    }

    private func seekBar(_ duration: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let position = min(duration, seekDraft ?? player.displayPosition)
            HStack(spacing: 8) {
                Text(HallSync.clock(position)).font(.caption2.monospacedDigit()).foregroundStyle(.white)
                Slider(value: Binding(get: { position }, set: { seekDraft = $0 }), in: 0...duration) { editing in
                    if !editing, let draft = seekDraft { player.seekShared(to: draft); seekDraft = nil }
                }
                .tint(Palette.accent).disabled(!player.canDirect)
                .overlay { if !player.canDirect { Color.clear.contentShape(Rectangle()).onTapGesture { explain(player.directReason) } } }
                .accessibilityLabel("Konum").accessibilityValue("\(HallSync.clock(position)) / \(HallSync.clock(duration))")
                .accessibilityHint(player.canDirect ? "" : player.directReason)
                Text(HallSync.clock(duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if player.isLive {
                HallControl(label: player.localPaused ? "Yayına devam et" : "Bende duraklat", icon: player.localPaused ? "play.fill" : "pause.fill") { player.toggleLocalPause() }
                remote("Önceki kanal", icon: "chevron.up") { player.zap(-1) }
                remote("Sonraki kanal", icon: "chevron.down") { player.zap(1) }
            } else {
                let playing = activity.room?.timeline.playing == true
                remote(playing ? "Herkes için duraklat" : "Herkes için oynat", icon: playing ? "pause.fill" : "play.fill", primary: true) { player.togglePlayback() }
                remote("Sıradakine geç", icon: "forward.end.fill", available: player.hasNext, unavailable: "Sırada başka bir şey yok.") { player.skip() }
            }
            HallControl(label: player.muted ? "Sesi aç" : "Sesi kapat", icon: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { player.toggleMute() }
            Spacer(minLength: 0)
            if player.audioTracks.count > 1 { audioMenu }
            if player.isRelay, player.pictureInPicturePossible || player.pictureInPictureActive {
                HallControl(label: player.pictureInPictureActive ? "Resim içinde resmi kapat" : "Resim içinde resim", icon: player.pictureInPictureActive ? "pip.exit" : "pip.enter") { player.togglePictureInPicture() }
            }
            HallControl(label: fullscreen ? "Tam ekrandan çık" : "Tam ekran", icon: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: toggleFullscreen)
        }
    }

    /// A remote-holder control: without the remote it stays visible, looks dimmed and says why on tap.
    private func remote(_ label: String, icon: String, primary: Bool = false, available: Bool = true, unavailable: String = "", action: @escaping () -> Void) -> some View {
        let allowed = player.canDirect && available
        return HallControl(label: label, icon: icon, primary: primary, dimmed: !allowed) {
            if allowed { action(); scheduleHide() } else { explain(player.canDirect ? unavailable : player.directReason) }
        }
        .accessibilityHint(allowed ? "" : player.canDirect ? unavailable : player.directReason)
    }

    /// The hall's audio language; changing it restarts the relay for everyone (desktop `AudioMenu`).
    private var audioMenu: some View {
        let selected = player.audioTracks.first { $0.index == player.audioTrack }
        let name = selected.map { String($0.label.components(separatedBy: " · ").first ?? $0.label) } ?? "Ses"
        return Menu {
            Section(player.canDirect ? "Ses dili · herkes için değişir" : player.directReason) {
                ForEach(player.audioTracks) { track in
                    Button { player.setAudioTrack(track.index) } label: {
                        if track.index == player.audioTrack { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                    }.disabled(!player.canDirect)
                }
            }
        } label: {
            HStack(spacing: 4) { Image(systemName: "character.bubble"); Text(name).lineLimit(1) }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 36).background(.black.opacity(0.55), in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Ses dili: \(selected?.label ?? "seçilmedi")")
    }

    private func explain(_ text: String) {
        reason = text
        reasonTask?.cancel()
        reasonTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { reason = nil } }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard overlay else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled, !pinned { overlay = false }
        }
    }
    /// "Kanal değişiyor…" only when a switch takes long enough to be noticed.
    private func scheduleSwitching() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if player.phase == .loading { switching = true }
        }
    }
}

/// The bare picture for the hall UI's corner player: a live dot and the play state, no controls.
private struct HallMini: View {
    @ObservedObject var player: HallPlayerController
    var body: some View {
        ZStack {
            HallScreen(player: player, style: .mini).allowsHitTesting(false)
            switch player.phase {
            case .loading, .buffering: ProgressView().tint(.white).controlSize(.small)
            case .paused: Image(systemName: "pause.fill").font(.caption).foregroundStyle(.white).padding(7).background(.black.opacity(0.55), in: Circle())
            case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.white).padding(7).background(.black.opacity(0.55), in: Circle())
            default: EmptyView()
            }
            if player.isLive { Circle().fill(Color.red).frame(width: 8, height: 8).padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        // The hall UI wraps the mini player in its own button, so the whole picture stays tappable.
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.title.map { "\(player.isLive ? "Canlı: " : "")\($0)" } ?? "Sinema salonu")
    }
}

/// Landscape full screen; the video uses the whole display, the controls avoid the island and home indicator.
private struct HallFullScreen: View {
    @ObservedObject var player: HallPlayerController
    let close: () -> Void
    var body: some View {
        HallStage(player: player, activity: player.activity, fullscreen: true, toggleFullscreen: close)
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { requestOrientation(.landscape) }
            .onDisappear { requestOrientation(.portrait) }
            .accessibilityAction(.escape, close)
    }
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // Even when iOS declines the rotation, the cover stays genuinely full screen.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
}

private struct HallPill: View {
    let text: String
    var live = false
    var body: some View {
        HStack(spacing: 5) {
            if live { Circle().fill(.white).frame(width: 6, height: 6) }
            Text(text).font(.caption2.weight(.bold)).lineLimit(1)
        }
        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
        .background(live ? Color.red : Color.black.opacity(0.55), in: Capsule())
        .accessibilityLabel(live ? "Canlı yayın" : text)
    }
}

private struct HallControl: View {
    let label: String
    let icon: String
    var primary = false
    var dimmed = false
    let action: () -> Void
    // Scales with Dynamic Type but stays inside the fixed 38 pt circle.
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 16
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: min(iconSize, 20), weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(primary ? Palette.accent.opacity(0.9) : Color.black.opacity(0.55), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(dimmed ? 0.45 : 1)
        .accessibilityLabel(label)
    }
}

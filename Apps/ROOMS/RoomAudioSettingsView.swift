import SwiftUI
import AVFoundation
import RoomsCore
import LiveKit

struct MicrophoneProcessingSection: View {
    @ObservedObject var media: RoomMedia
    var body: some View {
        Section {
            Toggle("Gürültü azaltma", isOn: Binding(
                get: { media.audioPreferences.noiseSuppression },
                set: { media.setNoiseSuppression($0) }
            ))
            .disabled(media.microphoneBusy)
            .accessibilityIdentifier("audio.noiseSuppression")
            VoiceIsolationRow(media: media)
        } header: { Text("Mikrofon") } footer: {
            Text("Mikrofonundan gönderilen sesi etkiler. Yankı giderme açık kalır. Tercihin bu hesap için kaydedilir. Ses Yalıtımı, iPhone'un yapay zekâ ile yalnızca senin sesini bırakan modudur; Apple yalnızca sistem menüsünden açılmasına izin verir.")
        }
        if let error = media.error { Section { Text(error).foregroundStyle(.secondary) } }
    }
}

struct ParticipantAudioView: View {
    @ObservedObject var media: RoomMedia
    let person: RoomPerson
    var onMessage: (() -> Void)? = nil
    var chat: ChatController? = nil
    /// Move, disconnect, remove and ban when this account may (joined voice room only).
    var moderation: VoiceModerationContext? = nil
    @State private var showingProfile = false
    @Environment(\.dismiss) private var dismiss
    private var present: Bool { media.people.contains { $0.id == person.id } }
    private var preference: RoomsCore.ParticipantAudioPreference { media.participantAudio(person.id) }
    private var hasEntranceSound: Bool { !(media.people.first { $0.id == person.id }?.sounds ?? person.sounds).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(media.people.first { $0.id == person.id }?.name ?? person.name).font(.headline)
                    if !present { Text("Katılımcı odadan ayrıldı.").foregroundStyle(.secondary) }
                    else if person.local { Text("Senin mikrofonun").foregroundStyle(.secondary) }
                    else { Text("Bu ayarlar yalnızca senin duyduğun sesi değiştirir.").foregroundStyle(.secondary) }
                }
                if let chat { Section { Button("Profili görüntüle", systemImage: "person.crop.circle") { showingProfile = true } }.sheet(isPresented: $showingProfile) { ProfileView(chat: chat, userID: person.id, currentUserID: person.local ? person.id : "") { showingProfile = false; dismiss(); onMessage?() } } }
                if person.local { MicrophoneProcessingSection(media: media) }
                else {
                    Section("Kişisel ses") {
                        HStack { Text("Ses seviyesi"); Spacer(); Text("%\(Int((preference.volume * 100).rounded()))").monospacedDigit() }
                        Slider(value: Binding(get: { preference.volume }, set: { media.setParticipantAudio(person.id, volume: $0) }), in: PlaybackGain.participantRange, step: 0.05)
                            .accessibilityLabel("\(person.name) kişisel sesi")
                            .accessibilityValue("Yüzde \(Int((preference.volume * 100).rounded()))")
                            .accessibilityIdentifier("audio.participant.volume")
                        Toggle("Benim için sustur", isOn: Binding(get: { preference.muted }, set: { media.setParticipantAudio(person.id, muted: $0) }))
                            .accessibilityIdentifier("audio.participant.mute")
                        if hasEntranceSound || media.entranceMuted(person.id) {
                            Toggle("Giriş sesini sustur", isOn: Binding(get: { media.entranceMuted(person.id) }, set: { media.setEntranceMuted(person.id, $0) }))
                                .accessibilityIdentifier("audio.participant.entranceMute")
                        }
                        Button("Sesi sıfırla") { media.resetParticipantAudio(person.id) }
                        if media.hearingMuted { Text("Oda sesi kapalı. Açtığında kişisel ses ayarın uygulanır.").foregroundStyle(.secondary) }
                    }.disabled(!present)
                    if let onMessage { Section { Button("Mesaj gönder", systemImage: "text.bubble") { dismiss(); onMessage() }.frame(minHeight: 44).disabled(!present) } }
                    if let moderation, present { VoiceModerationSection(context: moderation, person: person) }
                    Section { Text("Yayın sesi ayrı kontrol edilir. Kişisel ses tercihin yeniden katıldığında da korunur. Giriş sesini susturursan bu kişi için klasik ses çalar.").font(.footnote).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Katılımcı").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }.tint(Palette.accent)
    }
}

struct RoomAudioSettingsView: View {
    @ObservedObject var media: RoomMedia
    var onMessagePeer: ((String) -> Void)? = nil
    var chat: ChatController? = nil
    /// Pushed inside Settings instead of shown as its own sheet.
    var embedded = false
    @State private var messagePeer: String?
    @Environment(\.dismiss) private var dismiss
    @State private var person: RoomPerson?
    var body: some View {
        if embedded { content } else { NavigationStack { content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } } }.tint(Palette.accent) }
    }
    private var content: some View {
            Form {
                AudioRouteSection(media: media)
                MicrophoneProcessingSection(media: media)
                Section {
                    Toggle("Giriş ve çıkış sesleri", isOn: Binding(
                        get: { media.audioPreferences.roomEventSounds },
                        set: { media.setRoomEventSounds($0) }
                    ))
                    .accessibilityIdentifier("audio.roomEventSounds")
                } header: { Text("Oda") } footer: {
                    Text("Sen ya da başkası odaya girince veya çıkınca kısa bir ses çalar. Yalnızca sende duyulur.")
                }
                Section {
                    Toggle("Oyun sesleri", isOn: Binding(
                        get: { media.audioPreferences.gameSounds },
                        set: { media.setGameSounds($0) }
                    ))
                    .accessibilityIdentifier("audio.gameSounds")
                } footer: {
                    Text("Oyun masalarında kart, taş, zar, sıra ve el sonu için kısa sesler. Yalnızca sende duyulur; düzeyi efekt ses düzeyini izler.")
                }
                Section {
                    Toggle("Kişisel giriş sesleri", isOn: Binding(
                        get: { media.audioPreferences.personalSounds },
                        set: { media.setPersonalSounds($0) }
                    ))
                    .accessibilityIdentifier("audio.personalSounds")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Efekt ses düzeyi"); Spacer(); Text("%\(Int((media.audioPreferences.soundEffectsLevel * 100).rounded()))").monospacedDigit() }
                        Slider(value: Binding(get: { media.audioPreferences.soundEffectsLevel }, set: { media.setSoundEffectsLevel($0) }), in: 0...1, step: 0.05)
                            .accessibilityLabel("Giriş ve çıkış seslerinin düzeyi")
                            .accessibilityValue("Yüzde \(Int((media.audioPreferences.soundEffectsLevel * 100).rounded()))")
                            .accessibilityIdentifier("audio.soundEffectsLevel")
                    }
                } footer: {
                    Text("Kapalıyken herkes için klasik ses çalar.")
                }
                .disabled(!media.audioPreferences.roomEventSounds)
                Section {
                    NavigationLink { PersonalSoundSettingsView(media: media) } label: { Label("Giriş ve çıkış sesin", systemImage: "music.note") }
                        .accessibilityIdentifier("audio.ownPersonalSounds")
                }
                Section("Kişisel sesler") {
                    ForEach(media.people.filter { !$0.local }) { participant in
                        Button { person = participant } label: {
                            HStack {
                                Text(participant.name).foregroundStyle(.primary)
                                Spacer()
                                let preference = media.participantAudio(participant.id)
                                Text(preference.muted ? "Susturuldu" : "%\(Int((preference.volume * 100).rounded()))").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 44)
                    }
                    if !media.people.contains(where: { !$0.local }) { Text("Odada başka katılımcı yok.").foregroundStyle(.secondary) }
                }
            }.navigationTitle("Ses ve görüntü").navigationBarTitleDisplayMode(.inline)
                .sheet(item: $person, onDismiss: {
                    if let peer = messagePeer { messagePeer = nil; dismiss(); onMessagePeer?(peer) }
                }) { participant in
                    ParticipantAudioView(media: media, person: participant, onMessage: onMessagePeer == nil ? nil : { messagePeer = participant.id; person = nil }, chat: chat)
                }
    }
}

struct AudioRouteSection: View {
    @ObservedObject var media: RoomMedia
    var body: some View {
        Section {
            LabeledContent("Şu an", value: media.outputName)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Oda sesi"); Spacer(); Text("%\(Int((media.audioPreferences.roomLevel * 100).rounded()))").monospacedDigit() }
                Slider(value: Binding(get: { media.audioPreferences.roomLevel }, set: { media.setRoomLevel($0) }), in: RoomLoudness.range, step: 0.01)
                    .accessibilityLabel("Odadaki seslerin düzeyi")
                    .accessibilityValue("Yüzde \(Int((media.audioPreferences.roomLevel * 100).rounded()))")
                Text("Odada duyduğun her şeyin sesini yalnızca senin için ayarlar. En yüksekte de ses, hoparlörü zorlamayacak şekilde sınırlanır.").font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("Kulaklık / sistem çıkışı")
                Spacer()
                SwiftUIAudioRoutePickerButton().frame(width: 44, height: 44)
                    .accessibilityLabel("Ses çıkışını seç")
            }
            if media.canChooseReceiver {
                Button(media.speakerPreferred ? "Ahizeyi kullan" : "Hoparlörü kullan") { media.setSpeakerPreferred(!media.speakerPreferred) }
                    .frame(minHeight: 44).disabled(!media.connected || media.audioInterrupted)
            }
            ForEach(media.audioInputs) { input in
                Button { media.selectAudioInput(input.id) } label: {
                    HStack { Text(input.name); Spacer(); if input.id == media.currentInputID { Image(systemName: "checkmark") } }
                }.frame(minHeight: 44).disabled(!media.connected || media.audioInterrupted)
            }
            if media.audioNeedsResume && !media.audioInterrupted {
                Button("Sesi sürdür") { media.resumeAudio() }.frame(minHeight: 44)
            }
            if let notice = media.audioNotice { Text(notice).foregroundStyle(.secondary) }
        } header: { Text("Ses çıkışı") } footer: {
            Text("Kulaklık ayrılırsa mikrofon ve sesler kapatılır. Ahize seçimi iOS konuşma ses oturumu açıkken görünür. Çıkışı kontrol edip sesleri yeniden açabilirsin.")
        }
        Section {
            LabeledContent("Ağ", value: networkName)
            ShareLink(item: media.diagnosticsReport) { Label("Bağlantı raporunu paylaş", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
        } header: { Text("Bağlantı") } footer: {
            Text("Rapor yalnızca bağlantı, ağ ve ses durumlarını içerir; hesap, mesaj, parola veya sunucu adresi içermez. Kendiliğinden gönderilmez.")
        }
    }
    private var networkName: String {
        switch media.network {
        case .unknown: "Kontrol ediliyor"
        case .offline: "Bağlantı yok"
        case .wifi: "Wi-Fi"
        case .cellular: "Hücresel"
        case .wired: "Kablolu"
        case .other: "Diğer"
        }
    }
}

/// Apple's on-device Voice Isolation is the Krisp-like option on iPhone. Apps may only show the
/// system picker; the chosen mode applies while ROOMS uses the microphone in a room.
struct VoiceIsolationRow: View {
    @ObservedObject var media: RoomMedia
    @Environment(\.scenePhase) private var phase
    @State private var mode = AVCaptureDevice.activeMicrophoneMode
    var body: some View {
        Button {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ses Yalıtımı").foregroundStyle(.primary)
                    Text(media.connected ? "Şu an: \(Self.name(mode))" : "Odaya girince seçilebilir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: mode == .voiceIsolation ? "checkmark.circle.fill" : "waveform.badge.mic")
                    .foregroundStyle(mode == .voiceIsolation ? Color.green : Color.secondary)
            }
        }
        .frame(minHeight: 44)
        .disabled(!media.connected)
        .accessibilityIdentifier("audio.voiceIsolation")
        .onAppear { mode = AVCaptureDevice.activeMicrophoneMode }
        .onChange(of: phase) { _, _ in mode = AVCaptureDevice.activeMicrophoneMode }
    }
    static func name(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .voiceIsolation: "Ses Yalıtımı açık"
        case .wideSpectrum: "Geniş Spektrum"
        default: "Standart"
        }
    }
}

/// Whether this device can really decode the clip: a file can claim HEVC with alpha yet fail to play.
func animationDecodes(_ url: URL) async -> Bool {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .positiveInfinity; generator.requestedTimeToleranceAfter = .positiveInfinity
    return (try? await generator.image(at: .zero)) != nil
}
/// A muted, looping clip on a transparent background (HEVC with alpha keeps the DJ cut out).
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
    }
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView(); view.backgroundColor = .clear; view.isOpaque = false
        let player = AVQueuePlayer(); player.isMuted = true; player.preventsDisplaySleepDuringVideoPlayback = false
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player; view.playerLayer.videoGravity = .resizeAspect; view.playerLayer.backgroundColor = UIColor.clear.cgColor
        player.play()
        return view
    }
    func updateUIView(_ view: PlayerView, context: Context) {}
    static func dismantleUIView(_ view: PlayerView, coordinator: ()) { view.playerLayer.player?.pause(); view.looper?.disableLooping(); view.playerLayer.player = nil }
}

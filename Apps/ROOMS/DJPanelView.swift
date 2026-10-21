import SwiftUI
import RoomsCore

/// Shared room DJ for the current voice room, laid out for a phone screen.
struct DJPanelView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var media: RoomMedia
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MusicSnapshot?
    @State private var receivedAt = Date()
    @State private var input = ""
    @State private var results: [MusicSearchResult]?
    @State private var busy = false
    @State private var error: String?
    @State private var name = "DJ"
    @State private var poster: UIImage?
    @State private var seekDraft: Double?
    @State private var listsOpen = false
    @State private var historyOpen = false
    @State private var playlists: [SharedPlaylist]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var client: (api: APIClient, channel: String)? { model.musicClient() }
    private var current: MusicTrack? { snapshot?.current }
    private var botID: String? { snapshot?.identity }
    private var botVolume: Double { botID.map { media.participantAudio($0).volume } ?? 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let animation = model.djAnimation, !reduceMotion {
                        LoopingVideo(url: animation).frame(height: 170).accessibilityHidden(true)
                    } else if let poster = poster ?? model.djPoster {
                        Image(uiImage: poster).resizable().scaledToFit().frame(maxHeight: 170).accessibilityHidden(true)
                    }
                    addBox
                    if let results { searchResults(results) }
                    nowPlaying
                    transport
                    volume
                    if let current { DJLyricsSection(track: current, positionSec: snapshot?.positionSec ?? 0, playing: snapshot?.status == .playing, receivedAt: receivedAt).id(current.id) }
                    queue
                    if let client, historyOpen {
                        DJHistorySection(api: client.api, channel: client.channel, canPlay: !busy, play: { run($0) }) { lists in playlists = lists; listsOpen = true }
                    }
                    if let client, listsOpen { DJPlaylistsSection(api: client.api, channel: client.channel, canPlay: !busy, play: { run($0) }, lists: $playlists) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
            .task { await loadBranding() }
            .task(id: client?.channel) { await poll() }
        }
    }

    private var addBox: some View {
        let parsed = MusicInput(input)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Şarkı adı veya şarkı/liste bağlantısı", text: $input)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { submit(playNow: false) }
                    .onChange(of: input) { _, _ in results = nil }
                Button { submit(playNow: false) } label: {
                    Image(systemName: { if case .search = parsed { return "magnifyingglass" }; return "plus" }()).frame(width: 44, height: 44)
                }.disabled(busy || parsed == .invalid)
                    .accessibilityLabel({ if case .search = parsed { return "Şarkı ara" }; return "Kuyruğa ekle" }())
            }.padding(.leading, 10).background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
            if case .link = parsed {
                Button { submit(playNow: true) } label: { Label("Şimdi çal", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 40) }
                    .buttonStyle(.bordered).disabled(busy)
            }
        }
    }

    private func searchResults(_ items: [MusicSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty { Text("Parça bulunamadı.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.title).font(.subheadline).lineLimit(2)
                        Text(item.durationSec > 0 ? MusicClock.format(item.durationSec) : "YouTube").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { run(.add(url: item.url, playNow: false)) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .accessibilityLabel("Kuyruğa ekle: \(item.title)")
                    Button { run(.add(url: item.url, playNow: true)) } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("\(item.title) — Şimdi çal")
                }.disabled(busy)
            }
        }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var nowPlaying: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = current?.durationSec ?? 0
            let live = min(duration, (snapshot?.positionSec ?? 0) + (snapshot?.status == .playing ? context.date.timeIntervalSince(receivedAt) : 0))
            VStack(spacing: 6) {
                Text(current?.title ?? (snapshot == nil ? "Yükleniyor…" : "Kuyruk boş")).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if let current {
                    Slider(value: Binding(get: { seekDraft ?? live }, set: { seekDraft = $0 }), in: 0...max(1, duration)) { editing in
                        if !editing, let value = seekDraft { seekDraft = nil; run(.seek(id: current.id, positionSec: value)) }
                    }.disabled(busy || duration <= 0).accessibilityLabel("Parçada konum").accessibilityValue(MusicClock.format(seekDraft ?? live))
                    HStack { Text(MusicClock.format(seekDraft ?? live)); Spacer(); Text(MusicClock.format(duration)) }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transport: some View {
        let index = snapshot?.currentIndex
        let playing = snapshot?.status == .playing
        return HStack(spacing: 22) {
            control("Önceki parça", "backward.fill") { run(.previous) }.disabled(busy || index == nil)
            Button { run(playing ? .pause : .play) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 56, height: 56)
                    .background(Palette.accent, in: Circle()).foregroundStyle(Palette.canvas)
            }.disabled(busy || current == nil).accessibilityLabel(playing ? "Duraklat" : "Oynat")
            control("Sonraki parça", "forward.fill") { run(.next) }.disabled(busy || index == nil || index == (snapshot?.queue.count ?? 0) - 1)
            control("Botu odadan çıkar", "stop.fill") { run(.stop) }.disabled(busy || snapshot == nil || snapshot?.status == .disconnected)
        }
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: botVolume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: Binding(get: { botVolume }, set: { value in if let botID { media.setParticipantAudio(botID, volume: value) } }), in: PlaybackGain.participantRange)
                .disabled(botID == nil || !media.people.contains { $0.id == botID })
                .accessibilityLabel("DJ ses seviyesi (yalnızca senin için)")
            Text("%\(Int((botVolume * 100).rounded()))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Kuyruk").font(.subheadline.weight(.semibold)); Spacer()
                Button { listsOpen.toggle() } label: { Label("Listeler", systemImage: "music.note.list").font(.footnote) }.buttonStyle(RoomControlStyle(selected: listsOpen)).disabled(client == nil)
                Button { historyOpen.toggle() } label: { Label("Geçmiş", systemImage: "clock.arrow.circlepath").font(.footnote) }.buttonStyle(RoomControlStyle(selected: historyOpen)).disabled(client == nil)
            }.labelStyle(.titleAndIcon).padding(.bottom, 4)
            if snapshot?.queue.isEmpty != false { Text("Kuyruk boş. Şarkı adı ara veya bağlantı ekle.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array((snapshot?.queue ?? []).enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                    Button { run(.select(id: track.id)) } label: {
                        Text(track.title).font(.subheadline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(track.id == current?.id ? Palette.accent : Color.primary)
                    }.disabled(busy).accessibilityLabel("\(track.title) parçasını çal")
                    Text(MusicClock.format(track.durationSec)).font(.caption).foregroundStyle(.secondary)
                    Button { run(.remove(id: track.id)) } label: { Image(systemName: "trash").frame(width: 40, height: 40) }
                        .disabled(busy || track.id == current?.id).accessibilityLabel("\(track.title) sıradan kaldır")
                }.frame(minHeight: 44)
                    .background(track.id == current?.id ? Palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contextMenu {
                        Button("Yukarı taşı", systemImage: "arrow.up") { move(index, by: -1) }.disabled(busy || index == 0)
                        Button("Aşağı taşı", systemImage: "arrow.down") { move(index, by: 1) }.disabled(busy || index == (snapshot?.queue.count ?? 0) - 1)
                    }
                    .accessibilityAction(named: "Yukarı taşı") { move(index, by: -1) }
                    .accessibilityAction(named: "Aşağı taşı") { move(index, by: 1) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Desktop's ↑/↓: the whole queue in its new order (`reorder`).
    private func move(_ index: Int, by offset: Int) {
        guard var ids = snapshot?.queue.map(\.id), ids.indices.contains(index), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); run(.reorder(ids: ids))
    }
    private func control(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3).frame(width: 44, height: 44) }.accessibilityLabel(label)
    }

    private func submit(playNow: Bool) {
        switch MusicInput(input) {
        case .link(let url): run(.add(url: url, playNow: playNow))
        case .search(let text): search(text)
        case .invalid: break
        }
    }
    private func search(_ text: String) {
        guard let client, !busy else { return }
        busy = true; error = nil; results = nil
        Task {
            defer { busy = false }
            do { results = try await client.api.musicSearch(channel: client.channel, query: text) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func run(_ command: MusicCommand) {
        guard let client, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let next = try await client.api.musicCommand(channel: client.channel, command)
                guard client.channel == self.client?.channel else { return }
                snapshot = next; receivedAt = Date()
                if case .add = command {
                    if let candidates = next.matchCandidates {
                        results = candidates.candidates
                        error = "Tam eşleşme bulunamadı. Doğru parça bunlardan biri mi? Seçmeden kuyruğa eklenmez."
                    } else { input = ""; results = nil }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func poll() async {
        guard let client else { snapshot = nil; return }
        while !Task.isCancelled {
            if !busy {
                do {
                    let next = try await client.api.musicSnapshot(channel: client.channel)
                    if !busy, client.channel == self.client?.channel { snapshot = next; receivedAt = Date() }
                } catch is CancellationError { return }
                catch { if snapshot == nil { self.error = error.localizedDescription } }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
    private func loadBranding() async {
        guard let client, let branding = try? await client.api.musicBranding() else { return }
        name = branding.name
        if let url = branding.poster { poster = UIImage(contentsOfFile: url.path) }
    }
}


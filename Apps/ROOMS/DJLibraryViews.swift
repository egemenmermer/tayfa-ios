import SwiftUI
import RoomsCore

private let turkish = Locale(identifier: "tr_TR")

/// Synced lyrics for the playing track (desktop `MusicLyrics`): fetched from LRCLIB only after opening.
struct DJLyricsSection: View {
    let track: MusicTrack
    let positionSec: Double
    let playing: Bool
    let receivedAt: Date
    @State private var open = false
    @State private var result: MusicLyrics?
    @State private var attempt = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                Label("Şarkı sözleri", systemImage: "quote.bubble").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).accessibilityValue(open ? "Açık" : "Kapalı")
            if !open { Text("Açınca şarkı adı ve süresi LRCLIB ile paylaşılır.").font(.caption2).foregroundStyle(.secondary) }
            else if let result {
                switch result {
                case .unavailable:
                    HStack { Text("Bu kayıt için zamanlı şarkı sözü bulunamadı.").font(.footnote).foregroundStyle(.secondary); Button("Yeniden dene") { attempt += 1 }.font(.footnote) }
                case .instrumental: Text("Bu kayıt enstrümantal olarak işaretlenmiş.").font(.footnote).foregroundStyle(.secondary)
                case .found(let lines): lyrics(lines)
                }
            } else { ProgressView("Şarkı sözleri yükleniyor…").font(.footnote) }
        }
        .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .task(id: "\(open)-\(track.id)-\(attempt)") {
            guard open else { return }
            result = nil
            let value = await MusicLyrics.load(title: track.title, durationSec: track.durationSec)
            if !Task.isCancelled { result = value }
        }
    }
    private func lyrics(_ lines: [MusicLyrics.Line]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LRCLIB · Şarkıyla birlikte ilerler").font(.caption2).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                // Between snapshots the position advances by the clock, at most 6 s (desktop).
                let time = positionSec + (playing ? min(6, max(0, context.date.timeIntervalSince(receivedAt))) : 0)
                let active = MusicLyrics.activeLine(lines, at: time)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line.text.isEmpty ? "♪" : line.text).font(index == active ? .subheadline.bold() : .subheadline)
                                    .foregroundStyle(index == active ? Palette.accent : Color.secondary).id(index)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                        .onChange(of: active) { _, value in if let value { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) } } }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Şarkı sözleri")
    }
}

/// The DJ's recent listening sessions (desktop "Geçmiş"): play one track or the whole session again, or keep it as a list.
struct DJHistorySection: View {
    let api: APIClient
    let channel: String
    let canPlay: Bool
    let play: (MusicCommand) -> Void
    let saved: ([SharedPlaylist]) -> Void
    @State private var sessions: [MusicHistorySession]?
    @State private var error: String?
    @State private var busy = false
    @State private var attempt = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Geçmiş").font(.subheadline.weight(.semibold))
            if let error { HStack { Text(error).font(.footnote).foregroundStyle(.secondary); Button("Yeniden dene") { attempt += 1 }.font(.footnote) } }
            if let sessions {
                if sessions.isEmpty { Text("Henüz kayıtlı liste yok.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(sessions) { session in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(session.tracks) { track in
                                Button { play(.restore(sessionID: session.id, trackID: track.id)) } label: {
                                    HStack { Text(track.title).font(.footnote).lineLimit(1).foregroundStyle(.primary); Spacer(); Text(track.played ? "Çalındı" : "Kuyrukta").font(.caption2).foregroundStyle(.secondary) }.frame(minHeight: 40)
                                }.buttonStyle(.plain).disabled(!canPlay || busy).accessibilityLabel("\(track.title) geçmişten çal")
                            }
                            HStack(spacing: 8) {
                                Button { play(.restore(sessionID: session.id, trackID: nil)) } label: { Label("Kuyruğa ekle ve çal", systemImage: "play.fill").font(.footnote) }
                                    .buttonStyle(.bordered).disabled(!canPlay || busy)
                                Button("Ortak listeye kaydet") { keep(session) }.font(.footnote).buttonStyle(.bordered).disabled(!canPlay || busy)
                            }.padding(.top, 4)
                        }
                    } label: {
                        HStack { Text(session.started?.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(turkish)) ?? "Oturum").font(.footnote); Spacer(); Text("\(session.tracks.count) parça").font(.caption2).foregroundStyle(.secondary) }
                    }.tint(Palette.accent)
                }
            } else if error == nil { ProgressView("Geçmiş yükleniyor…").font(.footnote) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .task(id: attempt) {
            error = nil
            do { sessions = try await api.musicHistory(channel: channel) } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func keep(_ session: MusicHistorySession) {
        let day = session.started?.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(turkish)) ?? ""
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { saved(try await api.changeMusicPlaylist(channel: channel, .saveQueue(name: "Dinleme \(day)".trimmingCharacters(in: .whitespaces), sessionID: session.id))) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// The community's shared playlists (desktop `SharedPlaylists`): edit, import, save the queue, play.
struct DJPlaylistsSection: View {
    let api: APIClient
    let channel: String
    let canPlay: Bool
    let play: (MusicCommand) -> Void
    @Binding var lists: [SharedPlaylist]?
    @State private var editing: SharedPlaylist?
    @State private var name = ""
    @State private var tracks: [PlaylistTrack] = []
    @State private var link = ""
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var refresh = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Listeler").font(.subheadline.weight(.semibold)); Spacer()
                Button("Yeni liste") { choose(nil) }.font(.footnote).disabled(busy)
                Button("Yenile") { refresh += 1 }.font(.footnote).disabled(busy)
            }
            if lists == nil && error == nil { ProgressView("Listeler yükleniyor…").font(.footnote) }
            if let lists, !lists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(lists) { item in
                            Button { choose(item) } label: { Text("\(item.name) · \(item.tracks.count) parça").font(.footnote).padding(.horizontal, 10).frame(minHeight: 36) }
                                .buttonStyle(RoomControlStyle(selected: editing?.id == item.id)).disabled(busy)
                        }
                    }
                }
            }
            TextField("Liste adı", text: $name).textFieldStyle(.roundedBorder).disabled(busy)
                .onChange(of: name) { _, value in if value.count > 80 { name = String(value.prefix(80)) } }
            HStack(spacing: 8) {
                Button("Listeyi kaydet") { save(.save(id: editing?.id, revision: editing?.revision, name: name, tracks: tracks)) }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Kuyruğu yeni listeye kaydet") { save(.saveQueue(name: name, sessionID: nil)) }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(.footnote).buttonStyle(.bordered)
            if let editing { Button("Listeyi sil", role: .destructive) { save(.remove(id: editing.id, revision: editing.revision)) }.font(.footnote).disabled(busy) }
            Text("Listeler topluluğa ortaktır. YouTube ve herkese açık Spotify listelerini ekleyebilirsin. Spotify parçaları YouTube’da eşleştirilerek çalınır. Spotify listesi 100 parçadan az olmalı.")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("YouTube veya Spotify liste bağlantısı", text: $link).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
            TextField("Parça adı", text: $title).textFieldStyle(.roundedBorder).disabled(busy)
            HStack(spacing: 8) {
                Button("Parçayı ekle", action: append).disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Listeyi yeni liste olarak aktar") { save(.importList(name: name, url: link)) }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !DJLink.isPlaylist(link))
            }.font(.footnote).buttonStyle(.bordered)
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 4) {
                    Text(track.title).font(.footnote).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button { tracks.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up").frame(width: 36, height: 36) }.disabled(busy || index == 0).accessibilityLabel("\(index + 1). parçayı yukarı taşı")
                    Button { tracks.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down").frame(width: 36, height: 36) }.disabled(busy || index == tracks.count - 1).accessibilityLabel("\(index + 1). parçayı aşağı taşı")
                    Button { tracks.remove(at: index) } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }.disabled(busy).accessibilityLabel("\(index + 1). parçayı listeden çıkar")
                }
            }
            HStack(spacing: 8) {
                Button("Listeyi kuyruğa ekle") { play(.addList(tracks: tracks, playNow: false)) }.disabled(!canPlay || busy || tracks.isEmpty)
                Button("Listeyi şimdi çal") { play(.addList(tracks: tracks, playNow: true)) }.disabled(!canPlay || busy || tracks.isEmpty)
            }.font(.footnote).buttonStyle(.bordered)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .task(id: refresh) {
            do { lists = try await api.musicPlaylists(channel: channel); error = nil } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func choose(_ item: SharedPlaylist?) { editing = item; name = item?.name ?? ""; tracks = item?.tracks ?? []; error = nil }
    private func save(_ change: PlaylistChange) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let value = try await api.changeMusicPlaylist(channel: channel, change)
                lists = value
                if case .remove = change { choose(nil) } else { choose(value.first) }
                if case .importList = change { link = "" }
            } catch { self.error = error.localizedDescription; refresh += 1 }
        }
    }
    private func append() {
        guard case .video(let id)? = DJLink.parse(link) else { error = "Tek bir YouTube parçası bağlantısı gir."; return }
        guard tracks.count < 100 else { error = "Bir listeye en fazla 100 parça eklenebilir."; return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks.append(.youtube(videoID: id, title: name.isEmpty ? "YouTube parçası" : String(name.prefix(160)), durationSec: 0))
        link = ""; title = ""; error = nil
    }
}

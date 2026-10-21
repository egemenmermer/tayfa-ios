import SwiftUI
import RoomsCore

/// The account's own entrance and leave sounds (desktop "Giriş ve çıkış sesin"). V1 on iPhone chooses,
/// previews and deletes; uploading stays on desktop.
@MainActor final class PersonalSoundLibrary: ObservableObject {
    enum Phase: Equatable { case loading, ready, unsupported(String), failed(String) }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var profile = PersonalSoundProfile()
    /// The last failed choice or deletion; the screen keeps working.
    @Published var actionError: String?
    @Published private(set) var busy = false
    /// The row whose preview is loading or playing: a sound id, or `classic.enter` / `classic.leave`.
    @Published private(set) var previewing: String?
    private let media: RoomMedia
    private var previewTask: Task<Void, Never>?
    init(media: RoomMedia) { self.media = media }

    func load() async {
        guard let api = media.personalSoundClient else { phase = .failed(RoomsError.expired.localizedDescription); return }
        phase = .loading; actionError = nil
        do { profile = try await api.personalSoundProfile(); phase = .ready }
        catch let error as PersonalSoundError where error.unsupported { phase = .unsupported(error.localizedDescription) }
        catch { phase = .failed(Self.message(error)) }
    }
    func name(_ event: RoomCue) -> String {
        guard let id = profile.assign[event] else { return "Klasik Tayfa sesi" }
        return profile.item(id)?.name ?? "Seçili ses"
    }
    /// Saves at once; on failure the previous choice comes back with the reason.
    func choose(_ id: String?, for event: RoomCue) async {
        guard !busy, profile.assign[event] != id, let api = media.personalSoundClient else { return }
        let previous = profile
        var next = profile.assign; next[event] = id
        profile.assign = next; busy = true; actionError = nil
        defer { busy = false }
        do { profile = try await api.assignPersonalSounds(next) }
        catch { profile = previous; actionError = "Seçim kaydedilemedi. \(Self.message(error))" }
    }
    func remove(_ id: String) async {
        guard !busy, let api = media.personalSoundClient else { return }
        busy = true; actionError = nil
        defer { busy = false }
        if previewing == id { stopPreview() }
        do { profile = try await api.removePersonalSound(id) }
        catch { actionError = "Ses silinemedi. \(Self.message(error))" }
    }
    /// Plays a row once; tapping the playing row stops it. `id` nil is the classic cue for `event`.
    func togglePreview(_ id: String?, event: RoomCue) {
        let key = id ?? "classic.\(event.rawValue)"
        if previewing == key { stopPreview(); return }
        stopPreview(); previewing = key; actionError = nil
        previewTask = Task { [weak self] in
            guard let self else { return }
            var clip: Data?
            if let id {
                guard let api = self.media.personalSoundClient else { self.previewing = nil; return }
                clip = await self.media.soundCache.clip(id, retry: true) { try await api.personalSoundPreview(id) }
                guard !Task.isCancelled, self.previewing == key else { return }
                guard clip != nil else { self.previewing = nil; self.actionError = "Ses çalınamadı. Yeniden dene."; return }
            }
            guard self.media.playPreview(clip, kind: event) else { self.previewing = nil; self.actionError = "Ses çalınamadı. Yeniden dene."; return }
            // Clips are at most a few seconds; the row returns to its play icon when it ends.
            while !Task.isCancelled, self.media.previewPlaying { try? await Task.sleep(for: .milliseconds(200)) }
            // Ended or interrupted: the preview gives its playback session back.
            if !Task.isCancelled, self.previewing == key { self.previewing = nil; self.media.stopPreview() }
        }
    }
    func stopPreview() { previewTask?.cancel(); previewTask = nil; media.stopPreview(); previewing = nil }
    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Giriş sesleri alınamadı. Yeniden dene."
    }
}

struct PersonalSoundSettingsView: View {
    /// Not observed: the room's frequent roster updates have nothing to redraw here.
    @StateObject private var library: PersonalSoundLibrary
    init(media: RoomMedia) { _library = StateObject(wrappedValue: PersonalSoundLibrary(media: media)) }
    var body: some View {
        Form {
            switch library.phase {
            case .loading:
                Section { ProgressView("Sesler yükleniyor…").frame(maxWidth: .infinity) }
            case .unsupported(let message):
                Section { Text(message).foregroundStyle(.secondary) }
            case .failed(let message):
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("Yeniden dene", systemImage: "arrow.clockwise") { Task { await library.load() } }.frame(minHeight: 44)
                }
            case .ready:
                Section {
                    ForEach([RoomCue.enter, .leave], id: \.self) { event in
                        NavigationLink { PersonalSoundPicker(library: library, event: event) } label: {
                            LabeledContent(event == .enter ? "Odaya girince" : "Odadan çıkınca", value: library.name(event))
                        }
                        .accessibilityIdentifier("personalSounds.\(event.rawValue)")
                    }
                    if let error = library.actionError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("Sen odaya girip çıkarken odadakiler bu sesi duyar. Kişisel sesleri kapatan veya seni susturan kişiler klasik sesi duyar.")
                }
            }
        }
        .navigationTitle("Giriş ve çıkış sesin").navigationBarTitleDisplayMode(.inline)
        .task { if library.phase == .loading { await library.load() } }
        .onDisappear { library.stopPreview() }
    }
}

private struct PersonalSoundPicker: View {
    @ObservedObject var library: PersonalSoundLibrary
    let event: RoomCue
    @State private var pendingDelete: PersonalSoundItem?
    var body: some View {
        List {
            Section("Varsayılan") { row(id: nil, name: "Klasik Tayfa sesi") }
            if !library.profile.presets.isEmpty {
                Section("Tayfa sesleri") { ForEach(library.profile.presets) { row(id: $0.id, name: $0.name) } }
            }
            Section {
                ForEach(library.profile.sounds) { sound in
                    row(id: sound.id, name: sound.name)
                        .swipeActions(allowsFullSwipe: false) {
                            Button { pendingDelete = sound } label: { Label("Sil", systemImage: "trash") }.tint(.red)
                        }
                }
                if library.profile.sounds.isEmpty { Text("Henüz yüklediğin bir ses yok.").foregroundStyle(.secondary) }
            } header: { Text("Senin seslerin") } footer: {
                Text(library.profile.uploads ? "Yeni ses yüklemek için masaüstü uygulamasını kullan." : "Bu sunucuda yeni ses yükleme kapalı.")
            }
            if let error = library.actionError { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .navigationTitle(event == .enter ? "Odaya girince" : "Odadan çıkınca").navigationBarTitleDisplayMode(.inline)
        .disabled(library.busy)
        .confirmationDialog("“\(pendingDelete?.name ?? "")” silinsin mi?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { sound in
            Button("Sil", role: .destructive) { Task { await library.remove(sound.id) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Ses kalıcı olarak silinir. Giriş veya çıkış sesin olarak seçiliyse yerine klasik Tayfa sesi çalar.")
        }
        .onDisappear { library.stopPreview() }
    }
    private func row(id: String?, name: String) -> some View {
        let key = id ?? "classic.\(event.rawValue)", selected = library.profile.assign[event] == id
        return HStack(spacing: 12) {
            Button { library.togglePreview(id, event: event) } label: {
                Image(systemName: library.previewing == key ? "stop.circle" : "play.circle").font(.title2).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(library.previewing == key ? "\(name) sesini durdur" : "\(name) sesini dinle")
            Button { Task { await library.choose(id, for: event) } } label: {
                HStack {
                    Text(name).foregroundStyle(.primary)
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

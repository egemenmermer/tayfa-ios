import SwiftUI
import RoomsCore

/// KLIPY search like desktop `GifPicker`: trending first, typing searches, picking sends the GIF.
struct GifPickerView: View {
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [GifItem] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var ticket = 0
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("KLIPY'de ara", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onChange(of: query) { _, value in if value.count > 80 { query = String(value.prefix(80)) } }
                        .accessibilityLabel("GIF ara")
                }.padding(10).background(Palette.raised, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14)
                ScrollView {
                    if let error { Text(error).font(.footnote).foregroundStyle(.secondary).padding(24) }
                    else if items.isEmpty && !loading {
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "GIF bulunamadı." : "“\(query.trimmingCharacters(in: .whitespaces))” için GIF bulunamadı.")
                            .font(.footnote).foregroundStyle(.secondary).padding(24)
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items) { item in
                            Button { pick(item) } label: { RemoteGifTile(media: item.preview) }
                                .buttonStyle(.plain).accessibilityLabel(item.title.isEmpty ? "GIF" : item.title)
                                .onAppear { if item.id == items.last?.id, more, !loading { Task { await load(query, page: page + 1) } } }
                        }
                    }.padding(.horizontal, 14)
                    if loading { ProgressView("GIF’ler yükleniyor…").font(.footnote).padding() }
                }
                Text("Powered by KLIPY").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("GIF gönder").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } } }
            // Typing waits a moment so each keystroke is not a request.
            .task(id: query) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await load(query, page: 1)
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func load(_ text: String, page number: Int) async {
        ticket += 1; let current = ticket
        loading = true; error = nil
        do {
            let result = try await chat.gifs(query: text, page: number)
            guard current == ticket else { return }
            let known = number == 1 ? [] : items
            items = known + result.items.filter { item in !known.contains { $0.id == item.id } }
            page = number; more = result.more && number < 20
        } catch { if current == ticket, !(error is CancellationError) { self.error = error.localizedDescription } }
        if current == ticket { loading = false }
    }
    private func pick(_ item: GifItem) {
        guard chat.access.send, let url = GifPolicy.mediaURL(item.gif.url) else { return }
        chat.sendGif(url); dismiss()
    }
}

private struct RemoteGifTile: View {
    let media: GifMedia
    @State private var data: Data?
    var body: some View {
        ZStack {
            Palette.raised
            if let data { AnimatedImage(data: data, fill: true) } else { ProgressView() }
        }.aspectRatio(CGFloat(max(1, media.width)) / CGFloat(max(1, media.height)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: media.url) {
                guard let url = GifPolicy.mediaURL(media.url) else { return }
                data = try? await RemoteGifs.data(url, limit: 3_000_000)
            }
    }
}

/// Every reaction, not only the quick five: common emoji (desktop `EmojiPicker` groups) and the community's own.
struct ReactionPickerView: View {
    @ObservedObject var chat: ChatController
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    private static let groups: [(name: String, emojis: [String])] = [
        ("Sık kullanılanlar", "😂 ❤️ 👍 😭 🔥 🙏 😍 🥲 😅 😎 🤔 👀 🎉 💀 😡 🤝 😊 🙌 💯 🥳"),
        ("Yüzler", "😀 😃 😄 😁 😆 🤣 🙂 🙃 😉 😇 🥰 😘 😋 😜 🤪 🤨 🧐 🤓 😏 😒 😞 😔 😟 😕 🙁 😣 😫 😩 🥺 😢 😤 😠 🤯 😳 🥵 🥶 😱 😨 😰 🤗 🤭 🤫 😶 😐 😑 😬 🙄 😯 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 🤑 🤠 😈 👻 🤡 💩"),
        ("Eller", "👋 🤚 ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👎 ✊ 👊 🤛 🤜 👏 👐 🤲 💪 🫶"),
        ("Kalpler", "🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝"),
        ("Etkinlik", "🎮 🎲 ♠️ ♥️ ♦️ ♣️ 🃏 🎬 🍿 🎵 🎶 🎧 🎤 ⚽ 🏀 🏆 🎂 🎁 🍕 🍺 ☕ 🚀 ✨ ⭐"),
    ].map { (name: $0.0, emojis: $0.1.split(separator: " ").map(String.init)) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var community: [CustomEmoji] { chat.selected.flatMap { chat.emojiDirectory[$0.serverID] } ?? [] }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !community.isEmpty { section("Topluluk emojileri", keys: community.map(\.id)) }
                    ForEach(Self.groups, id: \.name) { group in section(group.name, keys: group.emojis) }
                }.padding(14)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Tepki ekle").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
            .task { if let server = chat.selected?.serverID, !server.isEmpty { await chat.loadCommunityEmojis(serverID: server) } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func section(_ title: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased(with: Locale(identifier: "tr_TR"))).font(.caption2.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    let selected = chat.reactionSelected(message, emoji: key)
                    Button { react(key) } label: {
                        ReactionLabel(chat: chat, key: key, size: 28).font(.title2).frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(ReactionLabel.name(key, chat: chat)).accessibilityValue(selected ? "Seçili, kaldırmak için dokun" : "")
                }
            }
        }
    }
    private func react(_ key: String) {
        let remove = chat.reactionSelected(message, emoji: key), send = chat.reactionKey(message, for: key)
        dismiss()
        Task { _ = await chat.perform(.reaction(id: message.id, emoji: send, remove: remove)) }
    }
}

import SwiftUI
import WebKit
import RoomsCore

/// One room's shared activity, observed by long-polling and changed by commands (desktop `useActivityRoom`).
@MainActor final class WatchTogetherModel: ObservableObject {
    @Published private(set) var room: ActivityRoom?
    @Published var failure: String?
    @Published private(set) var busy = false
    /// The last read reached the service (the hall's "connected"); command errors do not change it.
    @Published private(set) var reachable = false
    private(set) var serverOffsetMs: Double = 0
    let roomID: String
    let me: String
    let api: APIClient
    private var loop: Task<Void, Never>?
    private var queue: Task<Void, Never>?

    init(api: APIClient, roomID: String, me: String) { self.api = api; self.roomID = roomID; self.me = me }

    var primary: ActivityPrimary? { room?.primary }
    var watching: Bool { primary?.activity == "youtube" }
    var joined: Bool { room?.participant(me) != nil }
    var canDirect: Bool { room?.directs(me) ?? false }
    var canEnd: Bool { room?.ends(me) ?? false }
    func name(_ userID: String) -> String { userID == me ? "Sen" : room?.participant(userID)?.displayName ?? "Katılımcı" }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.poll() }
    }
    func stop() { loop?.cancel(); loop = nil }

    private func poll() async {
        var revision: Int?
        while !Task.isCancelled {
            do {
                let response = try await api.activitySnapshot(room: roomID, after: revision)
                accept(response); revision = response.room.revision
                if failure != nil, !busy { failure = nil }
                if !reachable { reachable = true }
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                failure = error.localizedDescription; revision = nil; reachable = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    private func accept(_ response: ActivityResponse) {
        guard response.room.roomId == roomID else { return }
        if let room, response.room.revision < room.revision { return }
        serverOffsetMs = response.serverTimeMs - Date().timeIntervalSince1970 * 1000
        room = response.room
    }
    /// Commands run one at a time; any command first joins the activity, as on desktop.
    func send(_ command: ActivityCommand) async throws {
        let previous = queue
        let work = Task { @MainActor [weak self] () throws -> Void in
            await previous?.value
            guard let self else { return }
            var current: ActivityRoom
            if let room = self.room { current = room } else { let r = try await self.api.activitySnapshot(room: self.roomID); self.accept(r); current = r.room }
            if command != .join, command != .leave, current.participant(self.me) == nil {
                let joined = try await self.api.activityCommand(room: self.roomID, .join, expectedRevision: current.revision)
                self.accept(joined); current = joined.room
            }
            self.accept(try await self.api.activityCommand(room: self.roomID, command, expectedRevision: current.revision))
        }
        queue = Task { _ = try? await work.value }
        try await work.value
    }
    /// A user action: shows the service's reason when it is refused.
    func run(_ command: ActivityCommand) {
        Task {
            busy = true; defer { busy = false }
            do { try await send(command); failure = nil } catch { failure = error.localizedDescription }
        }
    }
    func quiet(_ command: ActivityCommand) { Task { try? await send(command) } }

    /// Desktop `addYouTube`: start the watch party if nothing runs, otherwise queue (or play now).
    func add(videoID: String, title: String, now: Bool) async throws {
        busy = true; defer { busy = false }
        var replaced = false
        if let primary, primary.activity != "youtube" {
            guard canEnd else { throw ActivityError(code: "SESSION_HOST_REQUIRED") }
            try await send(.end); replaced = true
        }
        let fresh = room?.primary == nil || replaced
        if fresh { try await send(.startYouTube(title: "Birlikte izle")) }
        let idle = room?.current == nil
        let direct = fresh || canDirect
        try await send(.add(itemID: UUID().uuidString.lowercased(), videoID: videoID, title: title, start: direct && (now || fresh || idle)))
        failure = nil
    }
    func search(_ text: String) async throws -> [MusicSearchResult] { try await api.musicSearch(channel: roomID, query: text) }
}

/// Bridges the service's official YouTube player page to native code through a same-origin wrapper.
@MainActor final class YouTubePlayerController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    @Published private(set) var state = -1
    @Published private(set) var failure: String?
    private(set) var duration: Double?
    let webView: WKWebView
    var onEvent: ((String, [String: Any]) -> Void)?
    private let origin: URL

    init(url: URL, nonce: String, origin: URL) {
        self.origin = origin
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.isOpaque = false; webView.backgroundColor = .black; webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        config.userContentController.add(WeakMessageHandler(self), name: "rooms")
        webView.loadHTMLString(Self.wrapper(player: url, nonce: nonce), baseURL: origin)
    }
    func command(_ action: String, _ extra: [String: Double] = [:]) {
        guard let actionJSON = try? String(data: JSONEncoder().encode(action), encoding: .utf8),
              let extraJSON = try? String(data: JSONEncoder().encode(extra), encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.roomsCommand && window.roomsCommand(\(actionJSON), \(extraJSON))", completionHandler: nil)
    }
    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let event = body["event"] as? String else { return }
        let data = body["data"] as? [String: Any] ?? [:]
        switch event {
        case "ready": ready = true; failure = nil
        case "error": ready = false; failure = Self.errorText((data["code"] as? NSNumber)?.intValue ?? 0)
        case "position", "state":
            if let value = (data["state"] as? NSNumber)?.intValue { state = value }
            if let length = (data["durationSec"] as? NSNumber)?.doubleValue, length > 0, length <= 86400 { duration = length }
        default: break
        }
        onEvent?(event, data)
    }
    /// Only the wrapper (served as the ROOMS origin) and the players inside it may load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        let url = action.request.url
        decisionHandler(url?.host == origin.host || url?.scheme == "about" ? .allow : .cancel)
    }
    static func errorText(_ code: Int) -> String {
        switch code {
        case 2: "Video bağlantısı geçersiz."
        case 5: "Bu video oynatıcıda açılamadı."
        case 100: "Video kaldırılmış veya gizli."
        case 101, 150: "Video sahibi başka uygulamalarda oynatılmasına izin vermiyor."
        default: "Video oynatılamadı."
        }
    }
    private static func wrapper(player: URL, nonce: String) -> String {
        let src = player.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body,iframe{margin:0;padding:0;width:100%;height:100%;border:0;background:#000;overflow:hidden}</style></head>
        <body><iframe id="p" src="\(src)" allow="autoplay; encrypted-media; picture-in-picture" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        <script>
        const nonce = \(String(data: (try? JSONEncoder().encode(nonce)) ?? Data(), encoding: .utf8) ?? "\"\""), frame = document.getElementById('p');
        addEventListener('message', e => {
          const d = e.data;
          if (e.source !== frame.contentWindow || !d || d.type !== 'rooms-youtube' || d.nonce !== nonce) return;
          window.webkit.messageHandlers.rooms.postMessage({ event: String(d.event), data: d.data || {} });
        });
        window.roomsCommand = (action, extra) => frame.contentWindow.postMessage(Object.assign({ type: 'rooms-youtube-command', nonce, action }, extra || {}), '*');
        </script></body></html>
        """
    }
}
/// WKUserContentController keeps its handlers strongly; this avoids a retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlayerController?
    init(_ target: YouTubePlayerController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
/// Room polls, shared with desktop "Anket aç": vote once (changeable), the creator or a moderator closes.
struct PollsView: View {
    @ObservedObject var watch: WatchTogetherModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var creating = false
    var body: some View {
        let polls = (watch.room?.polls ?? []).sorted { !$0.closed && $1.closed }
        NavigationStack {
            List {
                if let failure = watch.failure { Section { Text(failure).font(.footnote).foregroundStyle(.secondary) } }
                Section("Yeni anket") {
                    TextField("Soru", text: $question)
                    ForEach(options.indices, id: \.self) { index in
                        TextField("Seçenek \(index + 1)", text: $options[index])
                    }
                    if options.count < 12 { Button("Seçenek ekle", systemImage: "plus") { options.append("") } }
                    Button(creating ? "Açılıyor…" : "Anketi aç") { Task { await create() } }
                        .disabled(creating || question.trimmingCharacters(in: .whitespaces).isEmpty || options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count < 2)
                }
                if watch.room == nil { ProgressView("Anketler yükleniyor…").frame(maxWidth: .infinity) }
                else if polls.isEmpty { Text("Bu odada henüz anket yok.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(polls) { poll in pollSection(poll) }
            }
            .navigationTitle("Anketler").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .task { watch.start() }
    }
    private func pollSection(_ poll: ActivityPoll) -> some View {
        let total = max(poll.votes.count, 1), mine = poll.votes[watch.me]
        return Section {
            ForEach(poll.options) { option in
                let count = poll.count(option.id)
                Button { if !poll.closed { watch.run(.pollVote(pollID: poll.id, optionID: option.id)) } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: mine == option.id ? "checkmark.circle.fill" : "circle").foregroundStyle(mine == option.id ? Palette.accent : .secondary)
                            Text(option.label).foregroundStyle(.primary)
                            Spacer()
                            Text("\(count) oy").font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            Capsule().fill(Palette.accent.opacity(0.15)).overlay(alignment: .leading) {
                                Capsule().fill(Palette.accent).frame(width: geometry.size.width * Double(count) / Double(total))
                            }
                        }.frame(height: 6)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain).disabled(poll.closed || watch.busy)
            }
            if !poll.closed, watch.room?.closes(poll, watch.me) == true {
                Button("Anketi kapat", role: .destructive) { watch.run(.pollClose(pollID: poll.id)) }
            }
        } header: {
            HStack { Text(poll.question); Spacer(); if poll.closed { Text("KAPANDI").font(.caption2.bold()) } }
        } footer: { Text("\(poll.votes.count) kişi oy verdi · Açan: \(watch.name(poll.createdBy))") }
    }
    private func create() async {
        creating = true; defer { creating = false }
        do {
            try await watch.send(.pollCreate(pollID: UUID().uuidString.lowercased(), question: question, options: options))
            question = ""; options = ["", ""]; watch.failure = nil
        } catch { watch.failure = error.localizedDescription }
    }
}

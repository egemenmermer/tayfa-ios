import Foundation
import RoomsCore

@MainActor final class Gateway {
    var onPacket: ((JSONValue) -> Void)?
    var onStatus: ((String) -> Void)?
    var onExpired: (() -> Void)?
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var ready = false
    /// True once the server sent `Ready` on the current socket.
    var isReady: Bool { ready }
    private var credentials: (api: APIClient, token: String)?
    func typing(channelID: String, active: Bool) async -> Bool {
        guard ready, let socket, (try? EndpointPolicy.id(channelID)) != nil else { return false }
        do { try await send(.object(["type": .string(active ? "BeginTyping" : "EndTyping"), "channel": .string(channelID)]), to: socket); return true }
        catch { return false }
    }
    private var lastPong = Date()
    private var epoch = OperationEpoch()
    func start(api: APIClient, token: String) {
        stop(); let ticket = epoch.advance(); credentials = (api, token)
        task = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            // Never gives up while running (B6): the backoff is capped and only stop() ends the loop.
            while !Task.isCancelled && self.epoch.owns(ticket) {
                self.onStatus?(failures == 0 ? "Odalar yükleniyor…" : "Bağlantı kesildi. Yeniden deneniyor.")
                do {
                    let url = try await api.gatewayURL()
                    guard self.epoch.owns(ticket), !Task.isCancelled else { return }
                    let connection = URLSession.shared.webSocketTask(with: url)
                    self.socket = connection; connection.resume()
                    try await self.send(.object(["type": .string("Authenticate"), "token": .string(token)]), to: connection)
                    self.lastPong = Date()
                    self.deadline = Task { [weak self, weak connection] in
                        try? await Task.sleep(for: .seconds(25))
                        guard !Task.isCancelled, self?.epoch.owns(ticket) == true else { return }
                        connection?.cancel(with: .goingAway, reason: nil)
                    }
                    self.heartbeat = Task { [weak self, weak connection] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(20)) } catch { return }
                            guard let self, let connection, self.epoch.owns(ticket) else { return }
                            if Date().timeIntervalSince(self.lastPong) > 60 { connection.cancel(with: .goingAway, reason: nil); return }
                            try? await self.send(.object(["type": .string("Ping"), "data": .number(Date().timeIntervalSince1970 * 1000)]), to: connection)
                        }
                    }
                    while !Task.isCancelled && self.epoch.owns(ticket) {
                        let message = try await connection.receive()
                        guard self.epoch.owns(ticket), !Task.isCancelled else { return }
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw RoomsError.invalidResponse }
                        guard data.count <= 2_097_152 else { throw RoomsError.invalidResponse }
                        let packet = try JSONDecoder().decode(JSONValue.self, from: data)
                        for event in packet["type"].string == "Bulk" ? packet["v"].array : [packet] {
                            if event["type"].string == "Pong" { self.lastPong = Date() }
                            if event["type"].string == "Ready" { failures = 0; self.deadline?.cancel(); self.ready = true; self.onStatus?("") }
                            if event["type"].string == "Logout" || event["type"].string == "Error" && ["InvalidSession", "OnboardingNotFinished"].contains(event["error"].string ?? event["data"]["type"].string ?? "") {
                                self.onExpired?(); self.stop(); return
                            }
                            self.onPacket?(event)
                        }
                    }
                } catch {
                    if error as? RoomsError == .expired { self.onExpired?(); self.stop(); return }
                }
                self.ready = false; self.heartbeat?.cancel(); self.deadline?.cancel(); self.socket?.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled, self.epoch.owns(ticket) else { return }
                failures += 1
                let delay = ReconnectBackoff.delay(failures: failures, jitter: Double.random(in: 0...1))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    private func send(_ value: JSONValue, to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw RoomsError.invalidResponse }
        try await socket.send(.string(string))
    }
    /// A network change: skip the remaining backoff and reconnect now. A live socket is left alone
    /// unless `force` (the primary interface changed under it); a stopped gateway stays stopped.
    func reconnectNow(force: Bool = false) {
        guard task != nil, force || !ready, let credentials else { return }
        start(api: credentials.api, token: credentials.token)
    }
    func stop() { credentials = nil; ready = false; epoch.advance(); task?.cancel(); task = nil; heartbeat?.cancel(); deadline?.cancel(); socket?.cancel(with: .normalClosure, reason: nil); socket = nil }
}

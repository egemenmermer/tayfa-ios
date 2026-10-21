import Foundation

// MARK: DM calls (`/rooms-access/v1/calls/*`, desktop `electron/dm-call-http.ts`)
extension APIClient {
    /// This account's latest call (also keeps an accepted call alive; the service ends it after 35 s unseen).
    public func dmCallPoll() async throws -> DMCallSession? {
        struct Poll: Decodable { let call: DMCallSession? }
        return try decodeCall(Poll.self, await callRequest("poll", body: .object([:]))).call?.validated()
    }
    public func dmCallStart(dmID: String, mode: DMCallMode) async throws -> DMCallSession {
        try decodeCall(DMCallSession.self, await callRequest("start", body: .object(["dmId": .string(try EndpointPolicy.id(dmID)), "mode": .string(mode.rawValue)]))).validated()
    }
    public func dmCallRespond(callID: String, action: DMCallAction) async throws -> DMCallSession {
        guard UUID(uuidString: callID) != nil else { throw DMCallError(code: "DM_CALL_NOT_FOUND") }
        return try decodeCall(DMCallSession.self, await callRequest("respond", body: .object(["callId": .string(callID), "action": .string(action.rawValue)]))).validated()
    }
    /// A short-lived LiveKit grant for an accepted call; only `rooms-dm-call-<id>` on a TLS media server.
    public func dmCallGrant(callID: String) async throws -> MediaGrant {
        guard UUID(uuidString: callID) != nil else { throw DMCallError(code: "DM_CALL_NOT_FOUND") }
        let grant = try decodeCall(MediaGrant.self, await callRequest("grant", body: .object(["callId": .string(callID)])))
        guard (try? EndpointPolicy.media(grant.serverUrl)) != nil, grant.roomName == "rooms-dm-call-\(callID)",
              !grant.token.isEmpty, grant.token.count <= 8192 else { throw DMCallError(code: "DM_CALL_GRANT_INVALID") }
        return grant
    }
    private func decodeCall<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw DMCallError(code: "DM_CALL_INVALID") }
    }
    private func callRequest(_ path: String, body: JSONValue) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: "/rooms-access/v1/calls/\(path)", relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw DMCallError(code: "DM_CALL_UNAVAILABLE") }
        guard let http = response as? HTTPURLResponse else { throw DMCallError(code: "DM_CALL_INVALID") }
        if [404, 501].contains(http.statusCode) { throw DMCallError(code: "DM_CALL_UNSUPPORTED") }
        guard data.count <= 32768 else { throw DMCallError(code: "DM_CALL_INVALID") }
        if (200..<300).contains(http.statusCode) { return data }
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw DMCallError(code: "DM_CALL_UNAVAILABLE") }
        guard let code = raw["error"].string, code.range(of: "^[A-Z_]{1,64}$", options: .regularExpression) != nil else { throw DMCallError(code: "DM_CALL_REJECTED") }
        throw DMCallError(code: code)
    }
}

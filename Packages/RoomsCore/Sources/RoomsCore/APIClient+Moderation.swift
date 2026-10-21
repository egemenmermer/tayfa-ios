import Foundation

// MARK: Voice moderation (desktop `VoiceModeration.tsx`): move/disconnect through Access,
// remove/ban through Stoat. Rights only decide what is offered; the services recheck each action.
extension APIClient {
    /// Rights in one community: server-wide kick/ban and MoveMembers per voice room (at most 50 rooms).
    public func voiceModerationRights(serverID: String, userID: String, channelIDs: [String]) async throws -> VoiceModerationRights {
        let server = try EndpointPolicy.id(serverID), me = try EndpointPolicy.id(userID)
        let user = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me"))
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(server)"))
        guard raw["_id"].string == serverID, let owner = raw["owner"].string else { throw RoomsError.invalidResponse }
        let privileged = user["privileged"] == .bool(true)
        var member: JSONValue?
        if owner != userID && !privileged {
            let value = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(server)/members/\(me)"))
            guard value["_id"]["server"].string == serverID, value["_id"]["user"].string == userID else { throw RoomsError.invalidResponse }
            member = value
        }
        let ids = try Array(Set(channelIDs)).prefix(50).map(EndpointPolicy.id)
        var channels: [JSONValue] = []
        try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            var next = 0
            func enqueue(_ id: String) {
                group.addTask {
                    // A room this account cannot see simply grants nothing.
                    do { return try JSONDecoder().decode(JSONValue.self, from: await self.request(path: "/api/channels/\(id)")) }
                    catch RoomsError.denied { return nil }
                }
            }
            while next < min(6, ids.count) { enqueue(ids[next]); next += 1 }
            while let channel = try await group.next() {
                if let channel, let id = channel["_id"].string, ids.contains(id) { channels.append(channel) }
                if next < ids.count { enqueue(ids[next]); next += 1 }
            }
        }
        return try VoiceModerationPolicy.rights(userID: userID, privileged: privileged, server: raw, member: member, channels: channels)
    }
    /// Moves someone to another voice room of the community (their client joins it) or disconnects them.
    public func moderateVoice(channelID: String, userID: String, action: VoiceModerationAction) async throws {
        var body: [String: JSONValue] = ["channelId": .string(try EndpointPolicy.id(channelID)), "userId": .string(try EndpointPolicy.id(userID))]
        switch action {
        case .move(let target):
            guard target != channelID else { throw VoiceModerationError(code: "INVALID_INPUT") }
            body["action"] = .string("move"); body["targetChannelId"] = .string(try EndpointPolicy.id(target))
        case .disconnect: body["action"] = .string("disconnect")
        case .kick, .ban: throw VoiceModerationError(code: "INVALID_INPUT")
        }
        _ = try await moderationRequest(path: "/rooms-access/v1/media/moderate", method: "POST", body: .object(body), broker: true)
    }
    /// Removes someone from the community; a new invitation lets them back.
    public func removeMember(serverID: String, userID: String) async throws {
        _ = try await moderationRequest(path: "/api/servers/\(EndpointPolicy.id(serverID))/members/\(EndpointPolicy.id(userID))", method: "DELETE", body: nil, broker: false)
    }
    /// Bans someone from the community until the ban is lifted.
    public func banMember(serverID: String, userID: String) async throws {
        _ = try await moderationRequest(path: "/api/servers/\(EndpointPolicy.id(serverID))/bans/\(EndpointPolicy.id(userID))", method: "PUT", body: .object([:]), broker: false)
    }
    private func moderationRequest(path: String, method: String, body: JSONValue?, broker: Bool) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = method
        if let token { request.setValue(broker ? "Bearer \(token)" : token, forHTTPHeaderField: broker ? "Authorization" : "x-session-token") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw RoomsError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 65536 else { throw RoomsError.invalidResponse }
        if (200..<300).contains(http.statusCode) { return data }
        if http.statusCode == 401 { throw RoomsError.expired }
        if http.statusCode == 429 { throw VoiceModerationError(code: "RATE_LIMITED") }
        let raw = try? JSONDecoder().decode(JSONValue.self, from: data)
        let code = raw?["error"].string ?? raw?["type"].string ?? ""
        throw VoiceModerationError(code: code.range(of: "^[A-Za-z_]{1,64}$", options: .regularExpression) != nil ? code : "MODERATION_FAILED")
    }
}

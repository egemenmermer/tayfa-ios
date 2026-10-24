import Foundation

// MARK: Safety (App Store guideline 1.2): block, report and moderator rights. Everything uses the
// existing Stoat endpoints; desktop uses `PUT/DELETE /users/:id/block` the same way
// (`blockUser` / `unblockUser` in `packages/stoat-adapter`). Reports go to Stoat's own
// `POST /safety/report`, which stores them for the server owner to review.

/// Reasons Stoat accepts for a reported message (`ContentReportReason`) and for a reported user
/// (`UserReportReason`). The raw value is what the server expects.
public enum SafetyReportReason: String, CaseIterable, Sendable {
    case spam = "UnsolicitedSpam"
    case harassment = "Harassment"
    case scam = "ScamsFraud"
    case violence = "ExtremeViolence"
    case illegal = "Illegal"
    case malware = "Malware"
    case other = "NoneSpecified"
    /// The matching `UserReportReason` for a reported person.
    var userValue: String {
        switch self {
        case .spam: "UnsolicitedSpam"
        case .harassment, .violence, .illegal, .other: "NoneSpecified"
        case .scam, .malware: "SpamAbuse"
        }
    }
    /// Turkish label for the report sheet.
    public var title: String {
        switch self {
        case .spam: "İstenmeyen ileti (spam)"
        case .harassment: "Taciz veya zorbalık"
        case .scam: "Dolandırıcılık"
        case .violence: "Aşırı şiddet"
        case .illegal: "Yasa dışı içerik"
        case .malware: "Zararlı yazılım"
        case .other: "Diğer"
        }
    }
}

public enum SafetyPolicy {
    /// Stoat `ManageMessages` (bit 23): delete other people's messages and clear reactions.
    public static let manageMessages: UInt64 = 1 << 23
    /// Stoat caps the free-text note of a report at 1000 characters.
    public static let contextLimit = 1000
    /// Accounts this one blocked (`Blocked`, not `BlockedOther`), from `/users/@me`.
    public static func blockedIDs(_ me: JSONValue) -> Set<String> {
        Set(Friend.relations(me).filter { $0.relationship == .blocked }.map(\.id))
    }
}

extension APIClient {
    /// Blocks someone; Stoat then hides their DMs from this account and the app hides their messages.
    public func block(id: String) async throws {
        _ = try await request(path: "/api/users/\(try EndpointPolicy.id(id))/block", method: "PUT")
    }
    /// Ids of the accounts this one has blocked.
    public func blockedUserIDs() async throws -> Set<String> { try await blockState().blocked }
    /// This account's id together with the accounts it has blocked, from one `/users/@me` read.
    public func blockState() async throws -> (userID: String, blocked: Set<String>) {
        let me = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me"))
        guard let id = me["_id"].string, (try? EndpointPolicy.id(id)) != nil else { throw RoomsError.invalidResponse }
        return (id, SafetyPolicy.blockedIDs(me))
    }
    /// Reports one message to the server's moderators.
    public func reportMessage(id: String, reason: SafetyReportReason, context: String = "") async throws {
        try await report(content: ["type": .string("Message"), "id": .string(try EndpointPolicy.id(id)), "report_reason": .string(reason.rawValue)], context: context)
    }
    /// Reports a person (profile or behavior) to the server's moderators.
    public func reportUser(id: String, reason: SafetyReportReason, context: String = "") async throws {
        // Stoat has fewer user reasons than message reasons; keep the chosen one in the note.
        let note = reason.userValue == reason.rawValue ? context : "[\(reason.rawValue)] " + context
        try await report(content: ["type": .string("User"), "id": .string(try EndpointPolicy.id(id)), "report_reason": .string(reason.userValue)], context: note)
    }
    private func report(content: [String: JSONValue], context: String) async throws {
        var body: [String: JSONValue] = ["content": .object(content)]
        let note = String(context.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SafetyPolicy.contextLimit))
        if !note.isEmpty { body["additional_context"] = .string(note) }
        _ = try await request(path: "/api/safety/report", method: "POST", body: .object(body))
    }
    /// True when this account may delete other people's messages in the channel: server owner, a
    /// privileged account, or `ManageMessages` after channel overrides (desktop `moderates`). Direct
    /// messages never grant it.
    public func canManageMessages(channelID: String, userID: String) async throws -> Bool {
        let channelID = try EndpointPolicy.id(channelID), userID = try EndpointPolicy.id(userID)
        let channel = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/channels/\(channelID)"))
        guard channel["_id"].string == channelID else { throw RoomsError.invalidResponse }
        guard channel["channel_type"].string == "TextChannel", let serverID = channel["server"].string else { return false }
        let user = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/users/@me"))
        guard user["_id"].string == userID else { throw RoomsError.invalidResponse }
        let server = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(try EndpointPolicy.id(serverID))"))
        guard server["_id"].string == serverID, server["owner"].string != nil else { throw RoomsError.invalidResponse }
        var member: JSONValue?
        if server["owner"].string != userID && user["privileged"] != .bool(true) {
            let value = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(serverID)/members/\(userID)"))
            guard value["_id"]["server"].string == serverID, value["_id"]["user"].string == userID else { throw RoomsError.invalidResponse }
            member = value
        }
        let bits = try TextPermissionPolicy.channelBits(userID: userID, privileged: user["privileged"] == .bool(true), server: server, channel: channel, member: member)
        return bits & SafetyPolicy.manageMessages != 0
    }
}

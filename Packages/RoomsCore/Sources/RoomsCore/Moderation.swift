import Foundation

/// What this account may do to people in one community's voice rooms (desktop `useModerationRights`).
/// Moving and disconnecting need MoveMembers in the room (Access checks the channel, overrides
/// included); removing and banning need the server-wide Kick/Ban bits. The server rechecks everything.
public struct VoiceModerationRights: Equatable, Sendable {
    /// Voice rooms where this account holds MoveMembers.
    public let moveRooms: Set<String>
    public let kick: Bool
    public let ban: Bool
    public let ownerID: String
    public init(moveRooms: Set<String>, kick: Bool, ban: Bool, ownerID: String) { self.moveRooms = moveRooms; self.kick = kick; self.ban = ban; self.ownerID = ownerID }
    public func canMove(from room: String) -> Bool { moveRooms.contains(room) }
    /// Other voice rooms of the community a person in `room` can be moved to.
    public func moveTargets(from room: String, among rooms: [VoiceRoom]) -> [VoiceRoom] {
        canMove(from: room) ? rooms.filter { $0.id != room && moveRooms.contains($0.id) } : []
    }
    /// Never yourself or the owner, as Access and Stoat refuse both.
    public func applies(to target: String, me: String) -> Bool { target != me && target != ownerID }
    public var any: Bool { !moveRooms.isEmpty || kick || ban }
}

public enum VoiceModerationAction: Equatable, Sendable {
    case move(to: String), disconnect, kick, ban
}

public enum VoiceModerationPolicy {
    /// `channels` are the community's raw voice channels; channels of other servers are ignored.
    public static func rights(userID: String, privileged: Bool, server: JSONValue, member: JSONValue?, channels: [JSONValue], now: Date = Date()) throws -> VoiceModerationRights {
        guard let serverID = server["_id"].string, let owner = server["owner"].string else { throw RoomsError.invalidResponse }
        let management = try TextPermissionPolicy.serverBits(userID: userID, privileged: privileged, server: server, member: member, now: now)
        var move: Set<String> = []
        for channel in channels where channel["server"].string == serverID {
            guard let id = channel["_id"].string else { continue }
            let bits = try TextPermissionPolicy.channelBits(userID: userID, privileged: privileged, server: server, channel: channel, member: member, now: now)
            if bits & StoatPermission.moveMembers != 0 { move.insert(id) }
        }
        return VoiceModerationRights(moveRooms: move, kick: management & StoatPermission.kickMembers != 0, ban: management & StoatPermission.banMembers != 0, ownerID: owner)
    }
}

/// A refused moderation action with Turkish text; Access sends `error`, Stoat sends `type`.
public struct VoiceModerationError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "MOVE_MEMBERS_REQUIRED": "Bu odadaki kişileri taşıma veya sesten çıkarma yetkin yok."
        case "MEMBER_NOT_IN_ROOM": "Bu kişi artık bu odada değil."
        case "MODERATE_SELF": "Bu işlemi kendine uygulayamazsın."
        case "NotElevated": "Bu kişinin rolü seninkinden yüksek ya da aynı seviyede."
        case "MissingPermission", "REMOVE_MEMBER_DENIED", "BAN_MEMBER_DENIED": "Bu işlem için yetkin yok."
        case "NotFound", "UnknownUser": "Bu kişi artık toplulukta değil."
        case "RATE_LIMITED": "Çok fazla işlem yapıldı. Biraz bekleyip yeniden dene."
        default: "İşlem tamamlanamadı. Tekrar dene."
        }
    }
}

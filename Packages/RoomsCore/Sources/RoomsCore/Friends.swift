import Foundation

/// A relationship from the account's Stoat relations, matching desktop's friends page.
public struct Friend: Identifiable, Equatable, Sendable {
    public enum Relationship: String, Sendable { case friend, incoming, outgoing, blocked }
    public let id: String
    public let name: String
    public let username: String
    public let discriminator: String?
    public let relationship: Relationship
    public let online: Bool
    public let presence: Presence?
    /// `name#1234`, the form Stoat needs to send or accept a request.
    public var handle: String { discriminator.map { "\(username)#\($0)" } ?? username }

    public static func relations(_ me: JSONValue) -> [(id: String, relationship: Relationship)] {
        me["relations"].array.prefix(1000).compactMap { relation in
            guard let id = relation["_id"].string, (try? EndpointPolicy.id(id)) != nil,
                  let status = relation["status"].string?.lowercased(), let kind = Relationship(rawValue: status) else { return nil }
            return (id, kind)
        }
    }
    public init(user: JSONValue, relationship: Relationship) throws {
        guard let id = user["_id"].string else { throw RoomsError.invalidResponse }
        self.id = try EndpointPolicy.id(id)
        username = user["username"].string ?? "Kullanıcı"
        name = String((user["display_name"].string ?? username).prefix(64))
        discriminator = user["discriminator"].string
        self.relationship = relationship
        let presence = user["status"]["presence"].string.flatMap(Presence.init(rawValue:))
        online = user["online"] == .bool(true) && presence != .invisible
        self.presence = presence
    }
    /// Desktop accepts only a full `name#1234` handle (2–32 characters before the tag).
    public static func validHandle(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: "^.{2,32}#[0-9]{4}$", options: .regularExpression) != nil ? text : nil
    }
}

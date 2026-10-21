import Foundation

// MARK: Community emoji (Stoat custom emoji, served by the file server's `emojis` tag)
public protocol EmojiTransport: Sendable {
    func communityEmojis(serverID: String) async throws -> [CustomEmoji]
    func customEmoji(id: String) async throws -> URL
}

extension APIClient: EmojiTransport {
    /// Stoat `GET /servers/{id}/emojis`; desktop has no emoji picker yet, so an older server simply has none.
    public func communityEmojis(serverID: String) async throws -> [CustomEmoji] {
        let raw = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/api/servers/\(EndpointPolicy.id(serverID))/emojis"))
        guard case .array(let values) = raw, values.count <= 1000 else { throw RoomsError.invalidResponse }
        return values.compactMap { CustomEmoji.parse($0, serverID: serverID) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    /// One emoji image, image-only and small.
    public func customEmoji(id: String) async throws -> URL {
        guard ReactionKey.isCustom(id) else { throw RoomsError.invalidResponse }
        return try await download(try FilePolicy.assetURL(base: await files(), category: "emojis", id: id), name: "emoji", limit: 1_048_576, imageOnly: true)
    }
}

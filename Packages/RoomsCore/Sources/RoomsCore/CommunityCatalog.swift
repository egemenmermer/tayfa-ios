import Foundation

public struct RoomCommunity: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let iconID: String?
    public let channelIDs: [String]
    public let categories: [Category]
    public struct Category: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let channelIDs: [String]
    }
    public static func fromReady(_ packet: JSONValue) -> [Self] {
        packet["servers"].array.compactMap { raw in
            guard let id = raw["_id"].string, (try? EndpointPolicy.id(id)) != nil else { return nil }
            let ordered = raw["channels"].array.compactMap(\.string)
            let icon = raw["icon"]["_id"].string.flatMap { try? EndpointPolicy.id($0) }
            let categories = raw["categories"].array.compactMap { category -> Category? in
                guard let id = category["id"].string else { return nil }
                return Category(id: id, name: category["title"].string ?? "Kanallar", channelIDs: category["channels"].array.compactMap(\.string))
            }
            return Self(id: id, name: raw["name"].string ?? "Topluluk", iconID: icon, channelIDs: ordered, categories: categories)
        }
    }
    public func ordered(_ available: Set<String>) -> [String] {
        let all = channelIDs + available.sorted(); var seen: Set<String> = []
        return all.filter { available.contains($0) && seen.insert($0).inserted }
    }
    public func sections(available: Set<String>) -> [(id: String, name: String, channels: [String])] {
        var used: Set<String> = []
        var result = categories.compactMap { category -> (String, String, [String])? in
            let ids = category.channelIDs.filter { available.contains($0) && used.insert($0).inserted }
            return ids.isEmpty ? nil : (category.id, category.name, ids)
        }
        let rest = ordered(available).filter { !used.contains($0) }
        if !rest.isEmpty { result.insert(("uncategorized", "Kanallar", rest), at: 0) }
        return result
    }
}

public struct CommunitySelection: Codable, Equatable, Sendable {
    public var communityID: String?
    public var channelID: String?
    public var messages = false
    public init() {}
    public mutating func reconcile(communities: [RoomCommunity], permittedChannels: Set<String>) {
        if !communities.contains(where: { $0.id == communityID }) { communityID = communities.first?.id; channelID = nil }
        if let channelID, !permittedChannels.contains(channelID) { self.channelID = nil }
    }
}
@MainActor public final class CommunitySelectionStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(origin: URL, owner: String) -> String { "rooms.navigation.v1." + Data((origin.absoluteString + "|" + owner).utf8).base64EncodedString() }
    public func load(origin: URL, owner: String) -> CommunitySelection {
        guard let data = defaults.data(forKey: key(origin: origin, owner: owner)), let selection = try? JSONDecoder().decode(CommunitySelection.self, from: data) else { return .init() }
        return selection
    }
    public func save(_ value: CommunitySelection, origin: URL, owner: String) { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key(origin: origin, owner: owner)) } }
}

public struct ConversationScrollMemory: Sendable {
    private var values: [String: String] = [:]
    private var order: [String] = []
    public init() {}
    public func anchor(for channelID: String) -> String? { values[channelID] }
    public mutating func remember(channelID: String, anchor: String) {
        values[channelID] = anchor; order.removeAll { $0 == channelID }; order.append(channelID)
        while order.count > 8 { values.removeValue(forKey: order.removeFirst()) }
    }
    public mutating func reconcile(permitted: Set<String>) { values = values.filter { permitted.contains($0.key) }; order.removeAll { !permitted.contains($0) } }
}
